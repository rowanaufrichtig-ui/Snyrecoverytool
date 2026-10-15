import Darwin
import Foundation
import XperiaRescueCore

enum CommandEvent: Sendable {
    case output(String)
    case exit(Int32)
}

enum CommandError: LocalizedError {
    case pseudoTerminalUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .pseudoTerminalUnavailable(let reason): return "Could not open a pseudo-terminal: \(reason)"
        }
    }
}

/// Runs a command-line tool and streams its combined stdout/stderr as events.
///
/// With `usePseudoTerminal` the tool sees a terminal, so C stdio stays line
/// buffered. newflasher needs this: it prints a question and then blocks in
/// `scanf`, and through a plain pipe that question would sit in its output
/// buffer forever.
final class RunningCommand: @unchecked Sendable {
    let events: AsyncStream<CommandEvent>

    private let continuation: AsyncStream<CommandEvent>.Continuation
    private let process = Process()
    private let usePseudoTerminal: Bool
    private let queue = DispatchQueue(label: "XperiaRescue.command")
    private var decoder = UTF8StreamDecoder()
    private var readSource: DispatchSourceRead?
    private var outputPipe: Pipe?
    private var masterFD: Int32 = -1
    private var exitStatus: Int32?
    private var outputClosed = false
    private var finished = false

    init(executable: URL, arguments: [String], workingDirectory: URL? = nil, usePseudoTerminal: Bool = false) {
        var continuation: AsyncStream<CommandEvent>.Continuation!
        events = AsyncStream(bufferingPolicy: .unbounded) { continuation = $0 }
        self.continuation = continuation
        self.usePseudoTerminal = usePseudoTerminal
        process.executableURL = executable
        process.arguments = arguments
        if let workingDirectory { process.currentDirectoryURL = workingDirectory }
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "dumb"
        process.environment = environment
    }

    var processIdentifier: Int32 { process.processIdentifier }
    var isRunning: Bool { process.isRunning }

    func start() throws {
        process.terminationHandler = { [weak self] finishedProcess in
            guard let self else { return }
            self.queue.async {
                self.exitStatus = finishedProcess.terminationStatus
                // A forked helper (adb starts a server daemon) can keep the
                // output open after the tool itself has exited. Don't wait for it.
                self.queue.asyncAfter(deadline: .now() + 1.5) {
                    if !self.outputClosed { self.readSource?.cancel() }
                }
                self.finishIfDone()
            }
        }

        if usePseudoTerminal {
            let slaveHandle = try openPseudoTerminal()
            process.standardInput = slaveHandle
            process.standardOutput = slaveHandle
            process.standardError = slaveHandle
            do {
                try process.run()
            } catch {
                close(masterFD)
                throw error
            }
            // Close the parent's copy of the slave so reads fail once the child exits.
            try? slaveHandle.close()
            startReading(fileDescriptor: masterFD, closeWhenDone: true)
        } else {
            let pipe = Pipe()
            outputPipe = pipe
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            startReading(fileDescriptor: pipe.fileHandleForReading.fileDescriptor, closeWhenDone: false)
        }
    }

    /// Types text into the tool's stdin (pseudo-terminal mode only).
    func send(_ text: String) {
        queue.async {
            guard self.masterFD >= 0, !self.outputClosed else { return }
            let bytes = Array(text.utf8)
            var offset = 0
            while offset < bytes.count {
                let written = bytes.withUnsafeBytes { buffer in
                    write(self.masterFD, buffer.baseAddress! + offset, buffer.count - offset)
                }
                if written <= 0 { break }
                offset += written
            }
        }
    }

    func terminate() {
        if process.isRunning { process.terminate() }
    }

    // MARK: - Private

    private func openPseudoTerminal() throws -> FileHandle {
        let master = posix_openpt(O_RDWR | O_NOCTTY)
        guard master >= 0 else { throw CommandError.pseudoTerminalUnavailable(String(cString: strerror(errno))) }
        _ = fcntl(master, F_SETFD, FD_CLOEXEC)
        guard grantpt(master) == 0, unlockpt(master) == 0, let name = ptsname(master) else {
            let reason = String(cString: strerror(errno))
            close(master)
            throw CommandError.pseudoTerminalUnavailable(reason)
        }
        let slave = open(name, O_RDWR | O_NOCTTY)
        guard slave >= 0 else {
            let reason = String(cString: strerror(errno))
            close(master)
            throw CommandError.pseudoTerminalUnavailable(reason)
        }
        var attributes = termios()
        if tcgetattr(slave, &attributes) == 0 {
            // Don't echo our answers back, and don't turn "\n" into "\r\n".
            attributes.c_lflag &= ~tcflag_t(ECHO)
            attributes.c_oflag &= ~tcflag_t(OPOST)
            _ = tcsetattr(slave, TCSANOW, &attributes)
        }
        masterFD = master
        return FileHandle(fileDescriptor: slave, closeOnDealloc: true)
    }

    private func startReading(fileDescriptor fd: Int32, closeWhenDone: Bool) {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            var buffer = [UInt8](repeating: 0, count: 16_384)
            let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if count > 0 {
                let text = self.decoder.decode(Data(buffer[0..<count]))
                if !text.isEmpty { self.continuation.yield(.output(text)) }
            } else if count == 0 || (errno != EAGAIN && errno != EINTR) {
                // EOF on a pipe, EIO on a pseudo-terminal whose child has exited.
                source.cancel()
            }
        }
        source.setCancelHandler { [weak self] in
            guard let self else { return }
            let rest = self.decoder.flush()
            if !rest.isEmpty { self.continuation.yield(.output(rest)) }
            if closeWhenDone {
                close(fd)
                self.masterFD = -1
            }
            self.outputPipe = nil
            self.outputClosed = true
            self.finishIfDone()
        }
        readSource = source
        source.resume()
    }

    private func finishIfDone() {
        guard !finished, outputClosed, let exitStatus else { return }
        finished = true
        continuation.yield(.exit(exitStatus))
        continuation.finish()
    }
}

struct CommandResult {
    let status: Int32
    let output: String

    var succeeded: Bool { status == 0 }
}
