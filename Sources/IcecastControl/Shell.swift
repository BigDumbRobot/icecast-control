import Foundation

/// Small helpers for running command-line programs.
enum Shell {
    struct Output {
        let status: Int32
        let text: String
    }

    /// Runs a short-lived program and returns its combined output.
    static func run(_ executable: String, _ arguments: [String]) async -> Output {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                process.standardInput = FileHandle.nullDevice
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: Output(status: -1, text: error.localizedDescription))
                    return
                }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(returning: Output(status: process.terminationStatus,
                                                      text: String(decoding: data, as: UTF8.self)))
            }
        }
    }

    /// Starts a program with its output going to `logFile`, without waiting for it.
    /// Writing to a file (not a pipe) matters: Icecast's background mode keeps
    /// the output handles open, so a pipe would never close.
    @discardableResult
    static func launch(_ executable: String, _ arguments: [String],
                       workingDirectory: URL, logFile: URL) throws -> Process {
        try FileManager.default.createDirectory(at: logFile.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: logFile.path, contents: nil)
        let handle = try FileHandle(forWritingTo: logFile)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        process.standardOutput = handle
        process.standardError = handle
        process.standardInput = FileHandle.nullDevice
        try process.run()
        return process
    }
}

/// Finds running Icecast processes that were started with a given settings file.
enum ProcessFinder {
    struct IcecastProcess {
        let pid: Int32
        /// Full path of the program (may contain spaces, e.g. inside "Icecast Control.app").
        let program: String
        /// The settings file after "-c", if any.
        let configPath: String?
    }

    /// All running Icecast servers. Matches on the process name, so paths with spaces work.
    static func icecastProcesses() async -> [IcecastProcess] {
        let pids = await Shell.run("/usr/bin/pgrep", ["-x", "icecast"]).text
            .split(separator: "\n").compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
        guard !pids.isEmpty else { return [] }
        let list = pids.map(String.init).joined(separator: ",")
        let output = await Shell.run("/bin/ps", ["-ww", "-o", "pid=,args=", "-p", list])
        var result: [IcecastProcess] = []
        for line in output.text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let space = trimmed.firstIndex(of: " "), let pid = Int32(trimmed[..<space]) else { continue }
            let args = trimmed[space...].trimmingCharacters(in: .whitespaces)
            // Program = everything before the first " -" option; config = text after " -c ".
            let program = args.range(of: " -").map { String(args[..<$0.lowerBound]) } ?? args
            let config = args.range(of: " -c ").map { String(args[$0.upperBound...]).trimmingCharacters(in: .whitespaces) }
            result.append(IcecastProcess(pid: pid, program: program, configPath: config))
        }
        return result
    }

    static func icecastPIDs(configPath: String) async -> [Int32] {
        let resolved = (configPath as NSString).resolvingSymlinksInPath
        return await icecastProcesses().filter { process in
            guard let config = process.configPath else { return false }
            return config == configPath || (config as NSString).resolvingSymlinksInPath == resolved
        }.map(\.pid)
    }

    static func isAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }
}
