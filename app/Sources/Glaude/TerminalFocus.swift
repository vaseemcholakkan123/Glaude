import AppKit

/// Brings a session's own terminal tab to the front: by tty in Terminal and iTerm2, by
/// launch directory (then title) in Ghostty, else just the terminal app.
enum TerminalFocus {
    static func reveal(_ session: Session) {
        guard let app = hostingApp(pid: pid_t(session.pid)) else { NSSound.beep(); return }
        let script: String?
        switch app.bundleIdentifier ?? "" {
        case "com.apple.Terminal":
            script = session.tty.isEmpty ? nil : terminalScript(tty: session.tty)
        case "com.googlecode.iterm2":
            script = session.tty.isEmpty ? nil : itermScript(tty: session.tty)
        case "com.mitchellh.ghostty":
            let dir = session.launchDir.isEmpty ? session.cwd : session.launchDir
            script = dir.isEmpty ? nil : ghosttyScript(directory: dir)
        default:
            script = nil
        }
        if let script {
            var error: NSDictionary?
            NSAppleScript(source: script)?.executeAndReturnError(&error)
            if let error { NSLog("Glaude: couldn't select the terminal tab: \(error)") }
        }
        app.activate()
    }

    /// The GUI app the session's claude process runs under (Ghostty, iTerm, …).
    private static func hostingApp(pid start: pid_t) -> NSRunningApplication? {
        var pid = start
        for _ in 0..<12 where pid > 1 {
            if let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular { return app }
            guard let parent = parentPID(pid) else { break }
            pid = parent
        }
        return nil
    }

    private static func parentPID(_ pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }

    /// An AppleScript string literal.
    private static func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func terminalScript(tty: String) -> String {
        """
        tell application "Terminal"
          repeat with w in windows
            repeat with t in tabs of w
              if tty of t is \(quoted(tty)) then
                set selected of t to true
                set index of w to 1
                return true
              end if
            end repeat
          end repeat
        end tell
        return false
        """
    }

    private static func itermScript(tty: String) -> String {
        """
        tell application "iTerm2"
          repeat with w in windows
            repeat with t in tabs of w
              repeat with s in sessions of t
                if tty of s is \(quoted(tty)) then
                  select w
                  select t
                  select s
                  return true
                end if
              end repeat
            end repeat
          end repeat
        end tell
        return false
        """
    }

    /// Ghostty reports each terminal's working directory (where claude was started) and
    /// title, not its tty. Several tabs in one folder: prefer the one titled like Claude.
    private static func ghosttyScript(directory: String) -> String {
        """
        tell application "Ghostty"
          set fallback to missing value
          repeat with w in windows
            repeat with t in tabs of w
              repeat with term in terminals of t
                if (working directory of term) is \(quoted(directory)) then
                  set n to name of term
                  if n contains "claude" or n contains "✳" then
                    focus term
                    return true
                  end if
                  if fallback is missing value then set fallback to term
                end if
              end repeat
            end repeat
          end repeat
          if fallback is not missing value then
            focus fallback
            return true
          end if
        end tell
        return false
        """
    }
}
