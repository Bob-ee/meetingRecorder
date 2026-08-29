import Foundation

struct ProcessResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String
}

enum ProcessRunner {
    static func run(executable: String, arguments: [String], stdin: String?, environment: [String: String],
                    currentDirectory: URL?, timeout: TimeInterval) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }

        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = errPipe

        try process.run()

        let stdinData = stdin?.data(using: .utf8)
        DispatchQueue.global(qos: .utility).async {
            if let stdinData { inPipe.fileHandleForWriting.write(stdinData) }
            try? inPipe.fileHandleForWriting.close()
        }

        let reader = Task.detached(priority: .utility) { () -> (Data, Data) in
            async let out = Task.detached { outPipe.fileHandleForReading.readDataToEndOfFile() }.value
            async let err = Task.detached { errPipe.fileHandleForReading.readDataToEndOfFile() }.value
            return await (out, err)
        }

        let watchdog = Task.detached {
            try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            if process.isRunning { process.terminate() }
        }

        let (outData, errData) = await reader.value
        await Task.detached { process.waitUntilExit() }.value
        watchdog.cancel()

        return ProcessResult(
            exitCode: process.terminationStatus,
            stdout: String(data: outData, encoding: .utf8) ?? "",
            stderr: String(data: errData, encoding: .utf8) ?? ""
        )
    }
}
