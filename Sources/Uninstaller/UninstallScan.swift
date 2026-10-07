//
//  UninstallScan.swift
//  Uninstaller
//
//  Finding everything an app left behind: the related-file scanner.
//  Pure Foundation, no DroppyKit dependency, so it compiles standalone
//  for testing.
//

import Foundation

// MARK: - Model

/// Review list section, in display order.
enum UninstallSectionID: String, CaseIterable, Identifiable, Sendable {
    case application
    case support
    case caches
    case preferences
    case containers
    case scripts
    case launch
    case other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .application: return "Application"
        case .support: return "Support"
        case .caches: return "Caches"
        case .preferences: return "Preferences"
        case .containers: return "Containers"
        case .scripts: return "Application Scripts"
        case .launch: return "Launch agents"
        case .other: return "Other"
        }
    }
}

/// One file or folder related to the app.
struct UninstallFile: Identifiable, Hashable, Sendable {
    let id: String // absolute path
    let name: String
    let path: String
    let shortPath: String // ~/… form for the list
    let size: Int64
    let section: UninstallSectionID
    /// System-owned paths (/Library/LaunchDaemons…). Listed but never
    /// auto-selected and never trashed without admin: trashing them would
    /// fail or break other users.
    let requiresAdmin: Bool
    /// The app bundle itself.
    let isAppBundle: Bool
}

/// One section with its found files.
struct UninstallSection: Identifiable, Sendable {
    let id: UninstallSectionID
    var files: [UninstallFile]

    var totalSize: Int64 { files.reduce(0) { $0 + $1.size } }
}

enum UninstallPhase: Equatable, Sendable {
    case idle // no app chosen yet
    case ready // app chosen, not scanned
    case scanning
    case results
    case trashing
}

// MARK: - Formatting

enum UninstallFormat {
    static func string(_ size: Int64) -> String {
        if size <= 0 { return "Zero KB" }
        let f = ByteCountFormatter()
        f.allowedUnits = [.useKB, .useMB, .useGB]
        f.countStyle = .file
        return f.string(fromByteCount: size)
    }

    static func shortHome(_ path: String, home: String) -> String {
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}

// MARK: - Scanner

/// Bounded, symlink-safe size walk. Same contract as the Mac Cleaner
/// droplet: never follow links, never count VM/disk images as cleanable.
enum UninstallMeasure {
    static let maxFilesPerRoot = 4000

    static func sizeAndCount(of url: URL, budget: inout Int) -> (size: Int64, files: Int) {
        var total: Int64 = 0
        var count = 0
        let fm = FileManager.default
        // Single file fast path.
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue {
            return ((try? fm.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0, 1)
        }
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else {
            return ((try? fm.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0, 0)
        }
        while let file = enumerator.nextObject() as? URL {
            if budget <= 0 { break }
            budget -= 1
            guard let vals = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]) else { continue }
            if vals.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
            guard vals.isRegularFile == true else { continue }
            if UninstallScan.skippedExtensions.contains(file.pathExtension.lowercased()) { continue }
            count += 1
            total += Int64(vals.fileSize ?? 0)
        }
        return (total, count)
    }

    static func size(of url: URL) -> Int64 {
        var budget = maxFilesPerRoot
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue {
            return (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        }
        return sizeAndCount(of: url, budget: &budget).size
    }
}

enum UninstallScan {
    static let skippedExtensions: Set<String> = [
        "raw", "vmdk", "vhd", "vhdx", "vdi", "qcow2", "sparseimage", "sparsebundle"
    ]

    /// Inputs to the detached scan. All value types: safe to cross isolation.
    struct Target: Sendable {
        let appPath: String
        let bundleID: String?
        let appName: String
        let execName: String?
        let includeSystem: Bool
    }

    /// Lower-cased match tokens for a target: bundle ID plus app/exec name
    /// variants (`"My App"` also matches `myapp`, `my-app`, `my.app`).
    nonisolated static func tokens(bundleID: String?, appName: String, execName: String?) -> [String] {
        var tokens: [String] = []
        if let bid = bundleID, !bid.isEmpty {
            tokens.append(bid)
        }
        tokens.append(appName)
        if let exec = execName, exec != appName { tokens.append(exec) }
        // Normalized variants: "Mousecape", "mousecape", "mouse-cape".
        let lowered = Set(tokens.map { $0.lowercased() } + tokens.map {
            $0.lowercased().replacingOccurrences(of: " ", with: "")
        } + tokens.map {
            $0.lowercased().replacingOccurrences(of: " ", with: "-")
        } + tokens.map {
            $0.lowercased().replacingOccurrences(of: " ", with: ".")
        })
        return Array(lowered.filter { $0.count >= 2 })
    }

    nonisolated static func matchKind(_ name: String, bundleID: String?, tokenList: [String]) -> MatchKind {
        let n = name.lowercased()
        if let bid = bundleID?.lowercased(), !bid.isEmpty {
            if n == bid || n == bid + ".plist" { return .exact }
            if n.hasPrefix(bid + ".") || n.hasPrefix(bid + "-") { return .exact }
            // Helper / plugin of the same app: com.sdmj76.MousecapeHelper.
            if n.hasPrefix(bid) { return .prefix }
        }
        for t in tokenList where !t.contains(".") {
            if n == t || n == t + ".plist" { return .exact }
        }
        return .none
    }

    nonisolated static func scan(target: Target) -> [UninstallSection] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        var bySection: [UninstallSectionID: [UninstallFile]] = [:]
        func add(_ file: UninstallFile) { bySection[file.section, default: []].append(file) }

        // 0. The app bundle itself.
        let appURL = URL(fileURLWithPath: target.appPath)
        let appSize = UninstallMeasure.size(of: appURL)
        add(UninstallFile(
            id: target.appPath,
            name: appURL.lastPathComponent,
            path: target.appPath,
            shortPath: target.appPath.replacingOccurrences(of: "/Users/", with: "~/../"),
            size: appSize,
            section: .application,
            requiresAdmin: !target.appPath.hasPrefix(home) && target.appPath.hasPrefix("/"),
            isAppBundle: true
        ))

        let tokenList = tokens(bundleID: target.bundleID, appName: target.appName, execName: target.execName)

        func matches(_ name: String) -> MatchKind {
            matchKind(name, bundleID: target.bundleID, tokenList: tokenList)
        }

        // (parent dir, section, match files inside?, match style)
        let homeDirs: [(String, UninstallSectionID)] = [
            ("Library/Application Support", .support),
            ("Library/Caches", .caches),
            ("Library/Preferences", .preferences),
            ("Library/Containers", .containers),
            ("Library/Group Containers", .containers),
            ("Library/Application Scripts", .scripts),
            ("Library/LaunchAgents", .launch),
            ("Library/Logs", .other),
            ("Library/Saved Application State", .other),
            ("Library/WebKit", .other),
            ("Library/HTTPStorages", .other),
            ("Library/Cookies", .other),
        ]
        for (rel, section) in homeDirs {
            let parent = (home as NSString).appendingPathComponent(rel)
            guard let kids = try? fm.contentsOfDirectory(atPath: parent) else { continue }
            for kid in kids {
                let kind = matches(kid)
                guard kind != .none else { continue }
                // Preferences: only .plist files (or the exact bundle dir).
                if section == .preferences, kind == .prefix { continue }
                let full = (parent as NSString).appendingPathComponent(kid)
                // Never follow top-level symlinks.
                if (try? URL(fileURLWithPath: full).resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { continue }
                let size = UninstallMeasure.size(of: URL(fileURLWithPath: full))
                add(UninstallFile(
                    id: full, name: kid, path: full,
                    shortPath: UninstallFormat.shortHome(full, home: home),
                    size: size, section: section,
                    requiresAdmin: false, isAppBundle: false
                ))
            }
        }

        // System locations: listed, flagged, never auto-selected.
        if target.includeSystem {
            let sysDirs: [(String, UninstallSectionID)] = [
                ("/Library/Application Support", .support),
                ("/Library/Caches", .caches),
                ("/Library/Preferences", .preferences),
                ("/Library/LaunchAgents", .launch),
                ("/Library/LaunchDaemons", .launch),
                ("/Library/Preferences", .preferences),
            ]
            for (parent, section) in sysDirs {
                guard let kids = try? fm.contentsOfDirectory(atPath: parent) else { continue }
                for kid in kids where matches(kid) != .none {
                    let full = (parent as NSString).appendingPathComponent(kid)
                    // Size without deep walk for system paths: cheap stat.
                    let size = (try? fm.attributesOfItem(atPath: full)[.size] as? Int64) ?? 0
                    add(UninstallFile(
                        id: full, name: kid, path: full, shortPath: full,
                        size: size, section: section,
                        requiresAdmin: true, isAppBundle: false
                    ))
                }
            }
        }

        // Order sections, sort files biggest-first.
        var out: [UninstallSection] = []
        for section in UninstallSectionID.allCases {
            guard var files = bySection[section], !files.isEmpty else { continue }
            files.sort { $0.size > $1.size }
            out.append(UninstallSection(id: section, files: files))
        }
        return out
    }

    enum MatchKind: Sendable { case none, prefix, exact }

    // MARK: Demo data for the harness (stable, no disk access)

    nonisolated static func demo() -> (appName: String, bundleID: String, appPath: String, sections: [UninstallSection]) {
        func f(_ section: UninstallSectionID, _ name: String, _ short: String, _ bytes: Int64, admin: Bool = false, bundle: Bool = false) -> UninstallFile {
            UninstallFile(id: "/demo/\(section.rawValue)/\(name)", name: name, path: "/demo/\(section.rawValue)/\(name)",
                          shortPath: short, size: bytes, section: section, requiresAdmin: admin, isAppBundle: bundle)
        }
        let mb: Int64 = 1024 * 1024
        let sections = [
            UninstallSection(id: .application, files: [
                f(.application, "Mousecape.app", "/Applications", 9_800_000, bundle: true),
            ]),
            UninstallSection(id: .support, files: [
                f(.support, "Mousecape", "~/Library/Application Support", 0),
            ]),
            UninstallSection(id: .caches, files: [
                f(.caches, "com.sdmj76.Mousecape", "~/…/Caches/…", 348 * 1024),
                f(.caches, "com.sdmj76.MousecapeHelper", "~/…/Caches/…", 0),
            ]),
            UninstallSection(id: .preferences, files: [
                f(.preferences, "com.sdmj76.Mousecape.plist", "~/Library/Preferences", 4 * 1024),
            ]),
            UninstallSection(id: .containers, files: [
                f(.containers, "com.sdmj76.Mo…cape.QuickLook", "~/Library/Containers", 4 * 1024),
                f(.containers, "com.sdmj76.Mo…kLookThumbnail", "~/Library/Containers", 4 * 1024),
            ]),
            UninstallSection(id: .scripts, files: [
                f(.scripts, "com.sdmj76.M…ape.QuickLook", "~/Library/Application Scripts", 0),
                f(.scripts, "com.sdmj76.M…ookThumbnail", "~/Library/Application Scripts", 0),
            ]),
        ]
        _ = mb
        return ("Mousecape", "com.sdmj76.Mousecape", "/Applications/Mousecape.app", sections)
    }
}

// MARK: - Privileged Trash (Touch ID / administrator approval)
