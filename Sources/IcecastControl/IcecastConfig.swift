import Foundation

/// The values from icecast.xml that the app shows and edits.
/// Kept as strings so they bind directly to text fields; checked by `validate()`.
struct IcecastSettings: Equatable {
    var location = ""
    var adminContact = ""
    var hostname = ""
    var port = "8000"
    var maxClients = "100"
    var mountName = "/stream.mp3"
    var maxListeners = "100"
    var sourcePassword = ""
    var adminUser = "admin"
    var adminPassword = ""
    var relayPassword = ""
    // Read only (used to find the log file).
    var logDir = ""
    var errorLog = "error.log"

    /// Editable fields and where each lives in the XML (path below <icecast>).
    static let editableFields: [(WritableKeyPath<IcecastSettings, String>, [String])] = [
        (\.location, ["location"]),
        (\.adminContact, ["admin"]),
        (\.hostname, ["hostname"]),
        (\.port, ["listen-socket", "port"]),
        (\.maxClients, ["limits", "clients"]),
        (\.mountName, ["mount", "mount-name"]),
        (\.maxListeners, ["mount", "max-listeners"]),
        (\.sourcePassword, ["authentication", "source-password"]),
        (\.adminUser, ["authentication", "admin-user"]),
        (\.adminPassword, ["authentication", "admin-password"]),
        (\.relayPassword, ["authentication", "relay-password"]),
    ]

    static let readOnlyFields: [(WritableKeyPath<IcecastSettings, String>, [String])] = [
        (\.logDir, ["paths", "logdir"]),
        (\.errorLog, ["logging", "errorlog"]),
    ]

    var portNumber: Int { Int(port.trimmingCharacters(in: .whitespaces)) ?? 8000 }

    var streamURL: String { "http://\(hostname):\(port)\(mountName)" }

    /// False for "localhost" and local-network addresses, which can't be tested from the internet.
    var hasPublicAddress: Bool {
        let h = hostname.lowercased()
        if h.isEmpty || h == "localhost" || h.hasSuffix(".local") { return false }
        for prefix in ["127.", "10.", "192.168.", "169.254."] where h.hasPrefix(prefix) { return false }
        if h.hasPrefix("172."), let second = Int(h.split(separator: ".").dropFirst().first ?? ""), (16...31).contains(second) { return false }
        return true
    }

    var errorLogURL: URL? {
        logDir.isEmpty ? nil : URL(fileURLWithPath: logDir).appendingPathComponent(errorLog)
    }

    static func isPlaceholder(_ password: String) -> Bool {
        password.hasPrefix("REPLACE_WITH") || password == "hackme"
    }

    var hasPlaceholderPasswords: Bool {
        Self.isPlaceholder(adminPassword) || Self.isPlaceholder(relayPassword)
    }

    func trimmed() -> IcecastSettings {
        var copy = self
        for (keyPath, _) in Self.editableFields {
            copy[keyPath: keyPath] = copy[keyPath: keyPath].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return copy
    }

    /// Returns a list of problems in plain language; empty means OK to save.
    func validate() -> [String] {
        let s = trimmed()
        var problems: [String] = []
        if s.hostname.isEmpty || s.hostname.contains(" ") || s.hostname.contains("/") {
            problems.append("Address should look like radio.example.com or 203.0.113.5 (no http:// or spaces).")
        }
        if let p = Int(s.port), (1...65535).contains(p) {} else {
            problems.append("Port must be a number between 1 and 65535.")
        }
        if !s.mountName.hasPrefix("/") || s.mountName.count < 2 || s.mountName.contains(" ") {
            problems.append("Mount point must start with / and have no spaces, e.g. /stream.mp3.")
        }
        for (label, value) in [("Max listeners", s.maxListeners), ("Max connections", s.maxClients)] {
            if let n = Int(value), n > 0 {} else { problems.append("\(label) must be a whole number above 0.") }
        }
        if s.sourcePassword.isEmpty { problems.append("Source password can't be empty.") }
        if s.adminUser.isEmpty { problems.append("Admin user can't be empty.") }
        if s.adminPassword.isEmpty { problems.append("Admin password can't be empty.") }
        if s.relayPassword.isEmpty { problems.append("Relay password can't be empty.") }
        let xmlUnsafe = CharacterSet(charactersIn: "<>&")
        for (keyPath, _) in Self.editableFields where s[keyPath: keyPath].rangeOfCharacter(from: xmlUnsafe) != nil {
            problems.append("Please avoid the characters < > & in settings.")
            break
        }
        return problems
    }
}

enum ConfigError: LocalizedError {
    case notIcecast
    case notLoaded
    case invalid([String])

    var errorDescription: String? {
        switch self {
        case .notIcecast: return "This file doesn't look like an Icecast settings file."
        case .notLoaded: return "The settings file couldn't be read, so it can't be saved."
        case .invalid(let problems): return problems.joined(separator: "\n")
        }
    }
}

/// Loads and saves icecast.xml, changing only the values that were edited
/// and leaving comments and everything else in the file as they were.
@MainActor
final class ConfigStore: ObservableObject {
    @Published private(set) var saved = IcecastSettings()
    @Published var draft = IcecastSettings()
    @Published private(set) var loadError: String?

    private(set) var path = ""
    private var document: XMLDocument?
    private var loadedModificationDate: Date?

    var isDirty: Bool { draft != saved }

    func load(path: String) {
        self.path = path
        do {
            let doc = try XMLDocument(contentsOf: URL(fileURLWithPath: path), options: [.nodePreserveAll])
            guard let root = doc.rootElement(), root.name == "icecast" else { throw ConfigError.notIcecast }
            var settings = IcecastSettings()
            for (keyPath, xmlPath) in IcecastSettings.editableFields + IcecastSettings.readOnlyFields {
                if let value = Self.value(in: root, at: xmlPath) { settings[keyPath: keyPath] = value }
            }
            document = doc
            saved = settings
            draft = settings
            loadError = nil
            loadedModificationDate = modificationDate()
        } catch {
            document = nil
            loadError = "Couldn't read \(path): \(error.localizedDescription)"
        }
    }

    /// Picks up edits made to the file outside the app (only if nothing is being edited here).
    func reloadIfChangedOnDisk() {
        guard !isDirty, !path.isEmpty else { return }
        let date = modificationDate()
        if date != loadedModificationDate { load(path: path) }
    }

    func revert() { draft = saved }

    func save() throws {
        let problems = draft.validate()
        guard problems.isEmpty else { throw ConfigError.invalid(problems) }
        guard let doc = document, let root = doc.rootElement() else { throw ConfigError.notLoaded }

        let new = draft.trimmed()
        for (keyPath, xmlPath) in IcecastSettings.editableFields where new[keyPath: keyPath] != saved[keyPath: keyPath] {
            Self.setValue(new[keyPath: keyPath], in: root, at: xmlPath)
        }

        let url = URL(fileURLWithPath: path)
        let backup = URL(fileURLWithPath: path + ".bak")
        let fm = FileManager.default
        if fm.fileExists(atPath: path) {
            try? fm.removeItem(at: backup)
            try fm.copyItem(at: url, to: backup)
        }
        try Self.tidy(doc.xmlString(options: [.nodePreserveAll]))
            .write(to: url, atomically: true, encoding: .utf8)

        saved = new
        draft = new
        loadedModificationDate = modificationDate()
    }

    /// Keeps the file looking hand-written: XML declaration on its own line, trailing newline.
    private static func tidy(_ xml: String) -> String {
        var text = xml.replacingOccurrences(of: #" standalone="yes""#, with: "")
        if let end = text.range(of: "?>"), text[end.upperBound...].first == "<" {
            text.insert("\n", at: end.upperBound)
        }
        if !text.hasSuffix("\n") { text += "\n" }
        return text
    }

    private func modificationDate() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    private static func value(in root: XMLElement, at path: [String]) -> String? {
        var element = root
        for name in path {
            guard let next = element.elements(forName: name).first else { return nil }
            element = next
        }
        return element.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func setValue(_ value: String, in root: XMLElement, at path: [String]) {
        var element = root
        for name in path {
            if let next = element.elements(forName: name).first {
                element = next
            } else {
                let created = XMLElement(name: name)
                element.addChild(created)
                element = created
            }
        }
        element.stringValue = value
    }
}
