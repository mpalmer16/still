import Foundation
import Darwin

// A separate, small supervisor outlives a crashing window just long enough to
// stop its BEAM. It never attaches to or stops a backend it did not start.
let owner = getppid()
let arguments = CommandLine.arguments
guard arguments.count == 2 else { exit(64) }
let backend = Process()
backend.executableURL = URL(fileURLWithPath: arguments[1])
backend.arguments = ["start"]
backend.environment = ProcessInfo.processInfo.environment
backend.standardOutput = FileHandle.standardOutput
backend.standardError = FileHandle.standardError

var stopping = false
var stopAt: Date?
func stopBackend() {
    if !stopping {
        stopping = true
        stopAt = Date()
        if backend.isRunning { backend.terminate() }
    }
}
signal(SIGTERM, SIG_IGN)
signal(SIGINT, SIG_IGN)
let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
term.setEventHandler { stopBackend() }
interrupt.setEventHandler { stopBackend() }
term.resume()
interrupt.resume()
do { try backend.run() } catch {
    fputs("Still backend could not start: \(error.localizedDescription)\n", stderr)
    exit(70)
}
let timer = DispatchSource.makeTimerSource(queue: .main)
timer.schedule(deadline: .now(), repeating: .milliseconds(200))
timer.setEventHandler {
    if getppid() != owner { stopBackend() }
    if !backend.isRunning { exit(backend.terminationStatus) }
    if let start = stopAt, Date().timeIntervalSince(start) > 12 {
        kill(backend.processIdentifier, SIGKILL)
    }
}
timer.resume()
dispatchMain()
