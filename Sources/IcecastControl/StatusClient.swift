import Foundation

struct SourceInfo: Equatable {
    var listeners: Int = 0
    var peakListeners: Int?
    var bitrate: Int?
    var title: String?
    var name: String?
    var startedAt: Date?
}

struct StatusSnapshot: Equatable {
    var serverStart: Date?
    var serverID: String?
    /// The source connected to our mount point (i.e. LadioCast), if any.
    var source: SourceInfo?
}

/// Reads Icecast's built-in status feed (status-json.xsl).
enum StatusClient {
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 2.5
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    static func fetch(port: Int, mount: String) async -> StatusSnapshot? {
        guard let url = URL(string: "http://127.0.0.1:\(port)/status-json.xsl") else { return nil }
        do {
            let (data, response) = try await session.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return parse(data, mount: mount)
        } catch {
            return nil
        }
    }

    /// Checks whether the server answers on its public address.
    static func checkPublic(host: String, port: Int) async -> Result<Void, Error> {
        guard let url = URL(string: "http://\(host):\(port)/status-json.xsl") else {
            return .failure(URLError(.badURL))
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 6
        request.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (_, response) = try await URLSession(configuration: .ephemeral).data(for: request)
            if (response as? HTTPURLResponse)?.statusCode == 200 { return .success(()) }
            return .failure(URLError(.badServerResponse))
        } catch {
            return .failure(error)
        }
    }

    static func parse(_ data: Data, mount: String) -> StatusSnapshot {
        var snapshot = StatusSnapshot()
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let stats = root["icestats"] as? [String: Any] else {
            // Icecast 2.4 can emit invalid JSON when track titles contain odd
            // characters. Fall back to a plain text search for our mount.
            let text = String(decoding: data, as: UTF8.self)
            if text.contains("\(mount)\"") {
                var source = SourceInfo()
                if let match = text.range(of: #""listeners":(\d+)"#, options: .regularExpression) {
                    source.listeners = Int(text[match].filter(\.isNumber)) ?? 0
                }
                snapshot.source = source
            }
            return snapshot
        }

        snapshot.serverStart = parseDate(stats["server_start_iso8601"])
        snapshot.serverID = stats["server_id"] as? String

        var sources: [[String: Any]] = []
        if let one = stats["source"] as? [String: Any] {
            sources = [one]
        } else if let many = stats["source"] as? [[String: Any]] {
            sources = many
        }
        for raw in sources {
            let listenURL = raw["listenurl"] as? String ?? ""
            guard listenURL.hasSuffix(mount) else { continue }
            var source = SourceInfo()
            source.listeners = int(raw["listeners"]) ?? 0
            source.peakListeners = int(raw["listener_peak"])
            source.bitrate = int(raw["bitrate"]) ?? int(raw["ice-bitrate"]) ?? int(raw["audio_bitrate"]).map { $0 / 1000 }
            source.title = text(raw["title"])
            source.name = text(raw["server_name"])
            source.startedAt = parseDate(raw["stream_start_iso8601"])
            snapshot.source = source
        }
        return snapshot
    }

    private static func int(_ value: Any?) -> Int? {
        if let n = value as? Int { return n }
        if let s = value as? String { return Int(s) }
        return nil
    }

    private static func text(_ value: Any?) -> String? {
        guard let value, !(value is NSNull) else { return nil }
        let string = "\(value)".trimmingCharacters(in: .whitespacesAndNewlines)
        return string.isEmpty ? nil : string
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        return formatter
    }()

    private static func parseDate(_ value: Any?) -> Date? {
        guard let string = value as? String else { return nil }
        return dateFormatter.date(from: string)
    }
}
