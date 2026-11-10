import Foundation
import SwiftTerm
import Darwin

final class Probe: LocalProcessDelegate {
    var output = ""
    var exited = false
    lazy var process = LocalProcess(delegate: self)
    func processTerminated(_ source: LocalProcess, exitCode: Int32?) { exited = true }
    func dataReceived(slice: ArraySlice<UInt8>) { output += String(decoding: slice, as: UTF8.self) }
    func getWindowSize() -> winsize { winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0) }
}

@main
struct TerminalChecks {
    static func wait(_ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(8)
        while !condition() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        precondition(condition(), "Timed out waiting for terminal response")
    }
    static func main() {
        let a = Probe(), b = Probe()
        let script = "test -t 0 || exit 9; printf 'READY:'; pwd; while read line; do printf 'REPLY:%s\\n' \"$line\"; stty size; done"
        for probe in [a, b] {
            probe.process.startProcess(executable: "/bin/zsh", args: ["-f", "-c", script], currentDirectory: "/tmp")
        }
        wait { a.output.contains("READY:") && b.output.contains("READY:") }
        precondition(a.process.shellPid != b.process.shellPid)
        a.process.send(data: Array("alpha\n".utf8)[...])
        b.process.send(data: Array("beta\n".utf8)[...])
        wait { a.output.contains("REPLY:alpha") && b.output.contains("REPLY:beta") }
        precondition(!a.output.contains("beta") && !b.output.contains("alpha"))
        precondition(a.output.contains("24 80"))
        var size = winsize(ws_row: 36, ws_col: 120, ws_xpixel: 0, ws_ypixel: 0)
        precondition(PseudoTerminalHelpers.setWinSize(masterPtyDescriptor: a.process.childfd, windowSize: &size) == 0)
        a.process.send(data: Array("resized\n".utf8)[...])
        wait { a.output.contains("36 120") }
        a.process.send(data: [4]) // Ctrl-D, a natural process exit.
        wait { a.exited }
        precondition(b.process.running)
        b.process.send(data: Array("still-alive\n".utf8)[...])
        wait { b.output.contains("REPLY:still-alive") }
        let pid = b.process.shellPid
        b.process.terminate()
        wait { kill(pid, 0) == -1 || waitpid(pid, nil, WNOHANG) == pid }
        print("Passed: concurrent PTYs, independent input/output, interactive TTY, resize, natural exit, sibling survival, termination.")
    }
}
