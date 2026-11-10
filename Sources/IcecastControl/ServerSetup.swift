import Foundation
import Security

/// An Icecast installation found on this Mac.
struct ExistingIcecast: Identifiable, Hashable {
    var id: String { configPath }
    let configPath: String
    /// The program that runs it (from the running process, or a matching install).
    let programPath: String?
    let isRunning: Bool
    let summary: String      // e.g. "Port 8000 · /stream.mp3"
}

/// Creates and maintains the Icecast server that ships inside the app,
/// and finds Icecast setups that already exist on this Mac.
enum ServerSetup {
    // MARK: Locations

    static var supportFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Icecast Control")
    }
    static var managedConfigURL: URL { supportFolder.appendingPathComponent("icecast.xml") }
    static var logFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Icecast Control")
    }

    /// Icecast, ffmpeg and Icecast's web files bundled in the app (nil when running a dev build without them).
    static var bundledIcecast: String? { bundledExecutable("icecast") }
    static var bundledFFmpeg: String? { bundledExecutable("ffmpeg") }
    static var bundledShare: URL? {
        let url = Bundle.main.resourceURL?.appendingPathComponent("icecast")
        return url.flatMap { FileManager.default.fileExists(atPath: $0.appendingPathComponent("web").path) ? $0 : nil }
    }

    private static func bundledExecutable(_ name: String) -> String? {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/\(name)")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url.path : nil
    }

    static var isManaged: Bool { true }

    // MARK: Finding existing setups

    private static let knownConfigs = [
        "/opt/homebrew/etc/icecast.xml",
        "/usr/local/etc/icecast.xml",
        "/opt/local/etc/icecast.xml",
        "/etc/icecast2/icecast.xml",
        "/etc/icecast.xml",
    ]
    private static let knownPrograms = ["/opt/homebrew/bin/icecast", "/usr/local/bin/icecast", "/opt/local/bin/icecast"]

    /// Running Icecast servers first, then settings files in the usual places.
    static func findExisting() async -> [ExistingIcecast] {
        var found: [String: ExistingIcecast] = [:]
        let managed = managedConfigURL.path

        // Running servers: read the settings file from their command line.
        for process in await ProcessFinder.icecastProcesses() {
            guard let config = process.configPath, config != managed,
                  !process.program.contains("Icecast Control.app") else { continue }
            let program = process.program
            let resolvedProgram = program.hasPrefix("/") ? program : knownPrograms.first { FileManager.default.isExecutableFile(atPath: $0) }
            found[config] = ExistingIcecast(configPath: config, programPath: resolvedProgram, isRunning: true,
                                            summary: summary(of: config))
        }
        // Installed but not running.
        for config in knownConfigs where found[config] == nil && FileManager.default.isReadableFile(atPath: config) {
            let program = knownPrograms.first { FileManager.default.isExecutableFile(atPath: $0) }
            found[config] = ExistingIcecast(configPath: config, programPath: program, isRunning: false,
                                            summary: summary(of: config))
        }
        return found.values.sorted { ($0.isRunning ? 0 : 1, $0.configPath) < ($1.isRunning ? 0 : 1, $1.configPath) }
    }

    private static func summary(of path: String) -> String {
        guard let doc = try? XMLDocument(contentsOf: URL(fileURLWithPath: path), options: []),
              let root = doc.rootElement() else { return "Settings can't be read" }
        func value(_ names: String...) -> String? {
            var element = root
            for name in names {
                guard let next = element.elements(forName: name).first else { return nil }
                element = next
            }
            return element.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var parts: [String] = []
        if let port = value("listen-socket", "port") { parts.append("Port \(port)") }
        if let mount = value("mount", "mount-name") { parts.append(mount) }
        if let host = value("hostname"), host != "localhost" { parts.append(host) }
        return parts.isEmpty ? "Icecast settings" : parts.joined(separator: " · ")
    }

    // MARK: Creating the app's own server

    struct NewServer {
        var streamName = "My Stream"
        var hostname = ""
        var port = "8000"
        var mount = "/stream.mp3"
        var maxListeners = "100"
        var sourcePassword = ServerSetup.randomPassword()
        var adminPassword = ServerSetup.randomPassword()
        var relayPassword = ServerSetup.randomPassword()
    }

    /// Writes a fresh icecast.xml for the bundled server. Keeps a backup if one already exists.
    static func createManagedConfig(_ s: NewServer) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: supportFolder, withIntermediateDirectories: true)
        try fm.createDirectory(at: logFolder, withIntermediateDirectories: true)
        if fm.fileExists(atPath: managedConfigURL.path) {
            let backup = managedConfigURL.appendingPathExtension("bak")
            try? fm.removeItem(at: backup)
            try fm.copyItem(at: managedConfigURL, to: backup)
        }
        let host = s.hostname.trimmingCharacters(in: .whitespaces).isEmpty ? "localhost" : s.hostname
        let share = bundledShare?.path ?? "/opt/homebrew/opt/icecast/share/icecast"
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <icecast>
            <!-- Created by Icecast Control. Edit it from the app's Settings tab. -->
            <location>Earth</location>
            <admin>admin@localhost</admin>

            <limits>
                <clients>\(max(Int(s.maxListeners) ?? 100, 1) + 10)</clients>
                <sources>2</sources>
                <queue-size>524288</queue-size>
                <client-timeout>30</client-timeout>
                <header-timeout>15</header-timeout>
                <source-timeout>10</source-timeout>
                <burst-on-connect>1</burst-on-connect>
                <burst-size>65535</burst-size>
            </limits>

            <authentication>
                <source-password>\(escape(s.sourcePassword))</source-password>
                <relay-password>\(escape(s.relayPassword))</relay-password>
                <admin-user>admin</admin-user>
                <admin-password>\(escape(s.adminPassword))</admin-password>
            </authentication>

            <!-- The address listeners use: a domain name (e.g. from DuckDNS or No-IP) or your public IP. -->
            <hostname>\(escape(host))</hostname>

            <listen-socket>
                <port>\(escape(s.port))</port>
                <bind-address>0.0.0.0</bind-address>
            </listen-socket>

            <http-headers>
                <header name="Access-Control-Allow-Origin" value="*" />
            </http-headers>

            <mount type="normal">
                <mount-name>\(escape(s.mount))</mount-name>
                <stream-name>\(escape(s.streamName))</stream-name>
                <public>0</public>
                <max-listeners>\(escape(s.maxListeners))</max-listeners>
            </mount>

            <fileserve>1</fileserve>

            <!-- Icecast Control keeps these paths pointing at the copy inside the app. -->
            <paths>
                <basedir>\(escape(share))</basedir>
                <logdir>\(escape(logFolder.path))</logdir>
                <webroot>\(escape(share))/web</webroot>
                <adminroot>\(escape(share))/admin</adminroot>
                <alias source="/" destination="/status.xsl" />
            </paths>

            <logging>
                <accesslog>access.log</accesslog>
                <errorlog>error.log</errorlog>
                <loglevel>3</loglevel>
                <logsize>10000</logsize>
            </logging>

            <security>
                <chroot>0</chroot>
            </security>
        </icecast>

        """
        try xml.write(to: managedConfigURL, atomically: true, encoding: .utf8)
    }

    /// If the app was moved (or macOS runs it from a temporary location), point the
    /// managed config's web/admin folders at where the app is now.
    static func refreshBundledPaths(configPath: String) {
        guard configPath == managedConfigURL.path, let share = bundledShare?.path,
              var text = try? String(contentsOfFile: configPath, encoding: .utf8) else { return }
        let original = text
        let replacements = [
            ("basedir", share), ("webroot", share + "/web"), ("adminroot", share + "/admin"),
            ("logdir", logFolder.path),
        ]
        for (tag, value) in replacements {
            text = text.replacingOccurrences(of: "<\(tag)>[^<]*</\(tag)>", with: "<\(tag)>\(escape(value))</\(tag)>",
                                             options: .regularExpression)
        }
        try? FileManager.default.createDirectory(at: logFolder, withIntermediateDirectories: true)
        if text != original { try? text.write(toFile: configPath, atomically: true, encoding: .utf8) }
    }

    // MARK: Helpers

    static func randomPassword() -> String {
        let alphabet = Array("abcdefghjkmnpqrstuvwxyzABCDEFGHJKMNPQRSTUVWXYZ23456789")
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return String(bytes.map { alphabet[Int($0) % alphabet.count] })
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// This Mac's address on the local network (for router port-forwarding instructions).
    static func localIPAddress() -> String? {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return nil }
        defer { freeifaddrs(pointer) }
        var candidates: [(String, String)] = []
        for interface in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(interface.pointee.ifa_flags)
            guard let address = interface.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            candidates.append((String(cString: interface.pointee.ifa_name), String(cString: host)))
        }
        return (candidates.first { $0.0 == "en0" } ?? candidates.first { $0.0.hasPrefix("en") } ?? candidates.first)?.1
    }

    /// Looks up this network's public IP (only when the user asks).
    static func publicIPAddress() async -> String? {
        guard let url = URL(string: "https://api.ipify.org") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 6
        guard let (data, _) = try? await URLSession(configuration: .ephemeral).data(for: request) else { return nil }
        let ip = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return ip.isEmpty || ip.count > 45 ? nil : ip
    }
}
