//
//  Shell.swift
//  PlayCover
//

import Foundation

class Shell: ObservableObject {
    @discardableResult
    static func run(print: Bool = true, _ binary: String, _ args: String...) throws -> String {
        let process = Process()
        let pipe = Pipe()

        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = args
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()

        let output = try pipe.fileHandleForReading.readToEnd() ?? Data()
        if print {
            Log.shared.log(String(data: output, encoding: .utf8) ?? "Shell error occured")
        }

        process.waitUntilExit()
        let status = process.terminationStatus
        if status != 0 {
            throw ShellError(output: String(data: output, encoding: .utf8) ?? "Shell error occurred")
        }
        return String(data: output, encoding: .utf8) ?? "Shell error occured"
    }

    static func runSu(_ args: [String], _ argc: String) -> Bool {
        let password = argc
        let passwordWithNewline = password + "\n"
        let sudo = Process()
        sudo.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        sudo.arguments = args
        let sudoIn = Pipe()
        let sudoOut = Pipe()
        sudo.standardOutput = sudoOut
        sudo.standardError = sudoOut
        sudo.standardInput = sudoIn
        do {
            try sudo.run()
        } catch {
            Log.shared.error(error)
            return false
        }

        // Show the output as it is produced
        sudoOut.fileHandleForReading.readabilityHandler = { fileHandle in
            let data = fileHandle.availableData
            if data.count == 0 { return }

            if let out = String(bytes: data, encoding: .utf8) {
                Log.shared.log(out)
            }
        }
        if let data = passwordWithNewline.data(using: .utf8) {
            // Write the password
            sudoIn.fileHandleForWriting.write(data)

            // Close the file handle after writing the password; avoids a
            // hang for incorrect password.
            try? sudoIn.fileHandleForWriting.close()
        }

        // Make sure we don't disappear while output is still being produced.
        sudo.waitUntilExit()
        sudoOut.fileHandleForReading.readabilityHandler = nil
        return sudo.terminationStatus == 0
    }

    static func signMacho(_ binary: URL) throws {
        try run("/usr/bin/codesign", "-fs-", binary.path)
    }

    static func signAppWith(_ exec: URL, entitlements: URL) throws {
        try run("/usr/bin/codesign", "-fs-", exec.deletingLastPathComponent().path,
                "--deep", "--entitlements", entitlements.path)
    }

    static func signApp(_ exec: URL) throws {
        try run("/usr/bin/codesign", "-fs-", exec.deletingLastPathComponent().path,
                "--deep", "--preserve-metadata=entitlements")
    }

    static func setMetalHUD(_ bundleID: String, enabled: Bool) throws {
        try run("/usr/bin/defaults", "write", bundleID,
                      "MetalForceHudEnabled", "-bool", String(enabled))
    }

    static func lldb(_ url: URL, withTerminalWindow: Bool = false) {
        Task(priority: .utility) {
            do {
                if withTerminalWindow {
                    let command = "/usr/bin/lldb -o run \(shellQuoted(url.path)) -o exit"
                    let appleScriptCommand = appleScriptQuoted(command)
                    let osascript = """
                        tell app "Terminal"
                            reopen
                            activate
                            do script "\(appleScriptCommand)"
                        end tell
                    """
                    let appleScript = NSAppleScript(source: osascript)
                    var possibleError: NSDictionary?
                    appleScript?.executeAndReturnError(&possibleError)

                    if let error = possibleError {
                        for key in error.allKeys {
                            if let key = key as? String {
                                Log.shared.error(error.value(forKey: key).debugDescription)
                            }
                        }
                    }
                } else {
                    try run("/usr/bin/lldb", "-o", "run", url.path, "-o", "exit")
                }
            } catch {
                Log.shared.error(error)
            }
        }
    }

    private static func shellQuoted(_ string: String) -> String {
        "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func appleScriptQuoted(_ string: String) -> String {
        string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
    }
}

struct ShellError: Error, LocalizedError {
    let output: String
    var errorDescription: String? { output }
}
