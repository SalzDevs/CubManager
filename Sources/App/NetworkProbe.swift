#if os(macOS) && !CUB_SELF_TEST
import Foundation

// MARK: - On-demand network measurement; no persistent helper

struct NetworkReading: Sendable { let incoming: Double; let outgoing: Double; let date: Date }
enum NetworkProbeError: LocalizedError {
    case unavailable
    var errorDescription: String? { "Network counters were unavailable. The app may have no active sockets, or macOS may restrict access." }
}

enum NetworkProbe {
    // nettop is invoked directly, not through script/a shell. -L 1 exits after
    // one snapshot, so pipe buffering does not require a long-lived PTY process.
    static func measure(pids: Set<Int32>) async throws -> NetworkReading {
        try await Task.detached(priority: .utility) {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
            process.arguments = ["-L", "1", "-x", "-P", "-n", "-J", "bytes_in,bytes_out"]
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            try process.run()
            let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5, execute: timeout)
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            timeout.cancel()
            guard process.terminationStatus == 0 else { throw NetworkProbeError.unavailable }
            let text = String(decoding: data, as: UTF8.self)
            var inIndex: Int?
            var outIndex: Int?
            var matched = Set<Int32>()
            var incoming = 0.0
            var outgoing = 0.0
            for line in text.split(whereSeparator: \.isNewline) {
                let columns = line.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                if let i = columns.firstIndex(of: "bytes_in"), let o = columns.firstIndex(of: "bytes_out") {
                    inIndex = i; outIndex = o; continue
                }
                guard let i = inIndex, let o = outIndex, columns.count > max(i, o),
                      let processColumn = columns.prefix(min(i, o)).first(where: { value in
                          guard let suffix = value.split(separator: ".").last, let pid = Int32(suffix) else { return false }
                          return pids.contains(pid)
                      }), let suffix = processColumn.split(separator: ".").last, let pid = Int32(suffix),
                      !matched.contains(pid), let bytesIn = Double(columns[i]), let bytesOut = Double(columns[o]) else { continue }
                matched.insert(pid); incoming += bytesIn; outgoing += bytesOut
            }
            guard !matched.isEmpty else { throw NetworkProbeError.unavailable }
            return NetworkReading(incoming: incoming, outgoing: outgoing, date: Date())
        }.value
    }
}

// MARK: - Main-actor presentation and safe actions
#endif
