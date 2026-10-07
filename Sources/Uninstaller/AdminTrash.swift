//
//  AdminTrash.swift
//  Uninstaller
//
//  Privileged Trash support: moves root-owned items to the Trash through the
//  system's own administrator approval dialog (Touch ID / password).
//

import Foundation

/// Moves files to the Trash with administrator privileges.
///
/// A droplet runs with Droppy's permissions, so root-owned items — most
/// notably app bundles under /Applications, which live in a root-owned
/// directory — refuse a normal `trashItem`. The fix is the system's own
/// authorization dialog (Touch ID or password): `do shell script … with
/// administrator privileges` presents it, one prompt for the whole batch,
/// and `mv` into ~/.Trash keeps Trash semantics (restorable, emptied via
/// Finder) instead of a permanent `rm`.
enum AdminTrash {
    struct Request: Sendable {
        let id: String
        let path: String
        let size: Int64
    }

    struct Result: Sendable {
        let movedIDs: Set<String>
        let movedBytes: Int64
        let failed: Int
        let cancelled: Bool
    }

    /// Single-quote a string for sh. Handles names like `Bob's App.app`.
    nonisolated static func shQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Double-quote a string for the AppleScript layer. The shell script
    /// travels inside `do shell script "..."`, so `\` and `"` must be
    /// escaped for AppleScript before osascript ever sees them.
    nonisolated static func appleScriptQuote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// A Trash destination that does not collide, Finder-style
    /// (`Name copy 2.ext`). `claimed` tracks destinations already promised
    /// to other items in the same batch.
    nonisolated static func uniqueDestination(in trash: String, name: String, claimed: inout Set<String>) -> String {
        let fm = FileManager.default
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = (trash as NSString).appendingPathComponent(name)
        var i = 1
        while fm.fileExists(atPath: candidate) || claimed.contains(candidate) {
            i += 1
            let numbered = ext.isEmpty ? "\(base) copy \(i)" : "\(base) copy \(i).\(ext)"
            candidate = (trash as NSString).appendingPathComponent(numbered)
        }
        claimed.insert(candidate)
        return candidate
    }

    /// The shell fragment moving every item into `trash`, plus the resolved
    /// (src, dest) pairs. Separated for testing: the exact string the shell
    /// will run can be inspected and executed without administrator rights.
    nonisolated static func buildMoves(
        items: [Request],
        trash: String
    ) -> (shell: String, pairs: [(id: String, src: String, dest: String, size: Int64)]) {
        let fm = FileManager.default
        var claimed: Set<String> = []
        var pairs: [(id: String, src: String, dest: String, size: Int64)] = []
        for item in items {
            guard fm.fileExists(atPath: item.path) else { continue }
            let dest = uniqueDestination(
                in: trash,
                name: URL(fileURLWithPath: item.path).lastPathComponent,
                claimed: &claimed
            )
            pairs.append((item.id, item.path, dest, item.size))
        }
        let shell = pairs.map { "mv -f -- \(shQuote($0.src)) \(shQuote($0.dest))" }.joined(separator: " ; ")
        return (shell, pairs)
    }

    /// Moves every item into the user's ~/.Trash as administrator. One auth
    /// dialog for the batch; returns per-item truth by checking what is gone.
    nonisolated static func moveToTrash(items: [Request], prompt: String) -> Result {
        let fm = FileManager.default
        let trash = fm.homeDirectoryForCurrentUser.appendingPathComponent(".Trash", isDirectory: true).path
        let (moves, pairs) = buildMoves(items: items, trash: trash)
        guard !pairs.isEmpty else {
            return Result(movedIDs: [], movedBytes: 0, failed: 0, cancelled: false)
        }
        let script = "do shell script \(appleScriptQuote(moves))"
            + " with administrator privileges"
            + " with prompt \(appleScriptQuote(prompt))"

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", script]
        let errPipe = Pipe()
        proc.standardError = errPipe
        proc.standardOutput = Pipe()
        do {
            try proc.run()
        } catch {
            return Result(movedIDs: [], movedBytes: 0, failed: pairs.count, cancelled: false)
        }
        proc.waitUntilExit()

        // Ground truth: what is actually gone. A per-item `;`-chained batch
        // keeps going past a single failure, so verify each path.
        var moved: Set<String> = []
        var bytes: Int64 = 0
        var failed = 0
        for pair in pairs {
            if !fm.fileExists(atPath: pair.src) {
                moved.insert(pair.id)
                bytes += pair.size
            } else {
                failed += 1
            }
        }
        var cancelled = false
        if proc.terminationStatus != 0 {
            let errText = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            // "User canceled." (err -128): the person dismissed the auth dialog.
            cancelled = errText.localizedCaseInsensitiveContains("canceled")
                || errText.localizedCaseInsensitiveContains("cancelled")
        }
        return Result(movedIDs: moved, movedBytes: bytes, failed: failed, cancelled: cancelled)
    }
}
