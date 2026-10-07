//
//  UninstallerDroplet.swift
//  Uninstaller
//
//  A Droppy droplet that fully uninstalls a Mac app: drop an .app on it,
//  it finds the app bundle plus every related file (support, caches,
//  preferences, containers, scripts, launch agents…), you review the list,
//  then it quits the app and moves everything to the Trash.
//

import AppKit
import Combine
import DroppyKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// The class Droppy's loader instantiates, named in the bundle's
/// `NSPrincipalClass`. Keep it empty: it runs before the host is ready.
@objc(UninstallerPrincipal)
public final class UninstallerPrincipal: NSObject, DropletPrincipal {
    public override init() { super.init() }

    @MainActor public func makeDroplet() -> AnyObject { UninstallerDroplet() }
}

// MARK: - Droplet

@MainActor
public final class UninstallerDroplet: NSObject, ObservableObject, Droplet {
    /// Must equal `DroppyDropletID` in the bundle's Info.plist and `id` in
    /// droplet.json. The loader refuses the bundle if the three disagree.
    public nonisolated static let id: DropletID = "uninstaller"

    private var host: DropletHost?
    private var scanTask: Task<Void, Never>?
    private var trashTask: Task<Void, Never>?

    @Published var phase: UninstallPhase = .idle
    @Published var appPath: String?
    @Published var appName: String?
    @Published var bundleID: String?
    @Published var execName: String?
    @Published var sections: [UninstallSection] = []
    @Published var selectedIDs: Set<String> = []
    @Published var isDropping = false
    @Published var lastTrashedBytes: Int64 = 0
    @Published var lastTrashedDate: Date?
    /// True while the NSOpenPanel file picker is on screen.
    private var filePanelOpen = false

    var totalFound: Int64 { sections.reduce(0) { $0 + $1.totalSize } }
    var selectableFiles: [UninstallFile] {
        sections.flatMap(\.files).filter { !$0.requiresAdmin }
    }
    var selectedBytes: Int64 {
        sections.flatMap(\.files).filter { selectedIDs.contains($0.id) }.reduce(0) { $0 + $1.size }
    }
    var selectedCount: Int { selectedIDs.count }
    var totalCount: Int { sections.reduce(0) { $0 + $1.files.count } }

    // MARK: Lifecycle

    public func activate(host: DropletHost) throws {
        self.host = host
        host.log.info("Uninstaller activated")
        if host.environment.isHarness {
            // Demo content for the harness shots: stable, no disk access.
            let demo = UninstallScan.demo()
            appName = demo.appName
            bundleID = demo.bundleID
            appPath = demo.appPath
            sections = demo.sections
            selectedIDs = Set(demo.sections.flatMap(\.files).filter { $0.size > 0 }.map(\.id))
            phase = .results
        } else if let saved = host.preferences.value(forKey: "lastAppPath", as: String.self),
                  FileManager.default.fileExists(atPath: saved) {
            setApp(path: saved, autoscan: false)
            phase = .ready
        }
        refreshShelfHold()
    }

    public func deactivate() {
        scanTask?.cancel()
        trashTask?.cancel()
        scanTask = nil
        trashTask = nil
        host = nil
    }

    // MARK: Preferences

    var includeSystem: Bool {
        host?.preferences.value(forKey: "includeSystem", default: true) ?? true
    }

    var includeSystemBinding: Binding<Bool> {
        Binding(
            get: { self.includeSystem },
            set: { self.host?.preferences.setValue($0, forKey: "includeSystem") }
        )
    }

    var quitBeforeTrash: Bool {
        host?.preferences.value(forKey: "quitBeforeTrash", default: true) ?? true
    }

    var quitBeforeTrashBinding: Binding<Bool> {
        Binding(
            get: { self.quitBeforeTrash },
            set: { self.host?.preferences.setValue($0, forKey: "quitBeforeTrash") }
        )
    }

    // MARK: Shelf hold

    /// Keeps the shelf open while the user is getting an app into the
    /// widget. The shelf otherwise collapses the moment the pointer leaves
    /// for Finder, which makes both drag-and-drop and the file picker
    /// unusable: the widget is gone before the app arrives.
    ///
    /// - Idle / ready (the choose-or-drag drop zone): always held, so a
    ///   trip to Finder never collapses the shelf mid-drag.
    /// - Scanning / trashing: held while the work runs.
    /// - Results: released, except while the file picker is up (Change…)
    ///   or a drag hovers the widget.
    ///
    /// The hold only counts while this widget is on the expanded shelf, and
    /// the user can still close it (close button, swipe, shortcut), so a
    /// forgotten hold cannot pin the shelf forever. Droppy also releases it
    /// on deactivate.
    func refreshShelfHold() {
        guard let host else { return }
        switch phase {
        case .idle, .ready, .scanning, .trashing:
            host.shelf.setHoldsOpen(true)
        case .results:
            host.shelf.setHoldsOpen(filePanelOpen || isDropping)
        }
    }

    // MARK: Picking an app

    /// NSOpenPanel restricted to .app bundles. The shelf is held open for
    /// the picker's lifetime: without it, the shelf collapses under the
    /// Finder window the moment it opens.
    func chooseApp() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Choose"
        panel.message = "Choose an app to scan for related files."
        filePanelOpen = true
        refreshShelfHold()
        panel.begin { [weak self] response in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.filePanelOpen = false
                self.refreshShelfHold()
                guard response == .OK, let url = panel.url else { return }
                self.setApp(path: url.path, autoscan: true)
            }
        }
    }

    func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers {
            guard provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else { continue }
            handled = true
            _ = provider.loadObject(ofClass: URL.self) { [weak self] url, _ in
                guard let url else { return }
                // Resolve Finder aliases / symlinks to the real .app.
                let resolved = url.resolvingSymlinksInPath()
                Task { @MainActor [weak self] in
                    self?.setApp(path: resolved.path, autoscan: true)
                    self?.isDropping = false
                }
            }
        }
        return handled
    }

    func setApp(path: String, autoscan: Bool) {
        scanTask?.cancel()
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir) else {
            presentNote("App not found")
            return
        }
        let url = URL(fileURLWithPath: path)
        let bundle = Bundle(url: url)
        let name = url.deletingPathExtension().lastPathComponent
        appPath = path
        appName = bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? name
        bundleID = bundle?.bundleIdentifier
        execName = bundle?.object(forInfoDictionaryKey: "CFBundleExecutable") as? String
        sections = []
        selectedIDs = []
        phase = .ready
        host?.preferences.setValue(path, forKey: "lastAppPath")
        host?.log.info("Uninstaller picked \(appName ?? name) (\(bundleID ?? "no bundle id"))")
        refreshShelfHold()
        if autoscan { scan() }
    }

    func clearApp() {
        scanTask?.cancel()
        trashTask?.cancel()
        appPath = nil
        appName = nil
        bundleID = nil
        execName = nil
        sections = []
        selectedIDs = []
        phase = .idle
        host?.preferences.setValue(nil as String?, forKey: "lastAppPath")
        refreshShelfHold()
    }

    // MARK: Scan

    func scan() {
        guard let appPath, phase != .scanning && phase != .trashing else { return }
        scanTask?.cancel()
        scanTask = Task { [weak self] in
            guard let self else { return }
            await self.runScan(appPath: appPath)
        }
    }

    func cancelScan() {
        scanTask?.cancel()
        if phase == .scanning { phase = appPath == nil ? .idle : .ready }
        refreshShelfHold()
    }

    private func runScan(appPath: String) async {
        phase = .scanning
        sections = []
        selectedIDs = []
        refreshShelfHold()

        let target = UninstallScan.Target(
            appPath: appPath,
            bundleID: bundleID,
            appName: appName ?? URL(fileURLWithPath: appPath).deletingPathExtension().lastPathComponent,
            execName: execName,
            includeSystem: includeSystem
        )
        let found: [UninstallSection]
        if host?.environment.isHarness == true {
            try? await Task.sleep(nanoseconds: 400_000_000)
            let demo = UninstallScan.demo()
            found = demo.sections
        } else {
            found = await Task.detached(priority: .utility) {
                UninstallScan.scan(target: target)
            }.value
        }

        if Task.isCancelled {
            phase = sections.isEmpty ? .ready : .results
            refreshShelfHold()
            return
        }
        sections = found
        // Pre-select everything trashable except empty (Zero KB) support
        // husks: they read as noise in the review list.
        selectedIDs = Set(found.flatMap(\.files).filter { file in
            guard !file.requiresAdmin else { return false }
            if file.isAppBundle { return true }
            return file.size > 0
        }.map(\.id))
        phase = .results
        refreshShelfHold()
        host?.log.info("Uninstaller scan found \(UninstallFormat.string(totalFound)) in \(totalCount) items")
        if found.isEmpty {
            presentNote("No related files found")
        }
    }

    // MARK: Selection

    func toggleFile(_ file: UninstallFile) {
        if selectedIDs.contains(file.id) { selectedIDs.remove(file.id) }
        else { selectedIDs.insert(file.id) }
    }

    func isSectionSelected(_ section: UninstallSection) -> Bool {
        guard !section.files.isEmpty else { return false }
        return section.files.allSatisfy { selectedIDs.contains($0.id) }
    }

    func toggleSection(_ section: UninstallSection) {
        if isSectionSelected(section) {
            for f in section.files { selectedIDs.remove(f.id) }
        } else {
            // System-owned items are included too: removing them goes
            // through the administrator prompt in runTrash.
            for f in section.files { selectedIDs.insert(f.id) }
        }
    }

    // MARK: Trash

    /// Review-first removal: confirm, quit the app, trash what we can, and
    /// ask for administrator approval (Touch ID / password) for the rest.
    func trashSelected() {
        guard phase == .results else { return }
        guard !selectedIDs.isEmpty else {
            presentNote("Nothing selected — tick what to remove first")
            return
        }
        let count = selectedCount
        let bytes = selectedBytes
        let ok = DropletConfirmationDialog.present(
            title: "Move to Trash?",
            message: "\(count) items (\(UninstallFormat.string(bytes))) will be moved to the Trash. The app will be quit first. Administrator approval may be requested.",
            confirmTitle: "Move to Trash",
            symbol: "trash"
        )
        guard ok else { return }
        trashTask?.cancel()
        trashTask = Task { [weak self] in
            guard let self else { return }
            await self.runTrash()
        }
    }

    /// Cocoa "no permission" plus the POSIX errors `trashItem` surfaces for
    /// root-owned paths. Anything else (busy file, I/O error) fails outright.
    nonisolated static func isPermissionError(_ error: NSError) -> Bool {
        if error.domain == NSCocoaErrorDomain && error.code == NSFileWriteNoPermissionError { return true }
        if error.domain == NSPOSIXErrorDomain && (error.code == Int(EACCES) || error.code == Int(EPERM)) { return true }
        return false
    }

    private func runTrash() async {
        let targets = sections.flatMap(\.files).filter { selectedIDs.contains($0.id) }
        guard !targets.isEmpty else { return }
        phase = .trashing
        refreshShelfHold()

        // Quit the running app first so its bundle and prefs can be trashed.
        if quitBeforeTrash, let bid = bundleID, !bid.isEmpty {
            for app in NSWorkspace.shared.runningApplications where app.bundleIdentifier == bid {
                app.terminate()
            }
            // Half a second for a graceful quit before trashing.
            try? await Task.sleep(nanoseconds: 500_000_000)
        }

        // Files first, app bundle last: if the bundle trash fails the
        // leftovers are still gone, and the review list stays truthful.
        let ordered = targets.sorted { (!$0.isAppBundle ? 0 : 1) < (!$1.isAppBundle ? 0 : 1) }

        var freed: Int64 = 0
        var gone: Set<String> = []
        var failed = 0
        var needAdmin: [AdminTrash.Request] = []
        for item in ordered {
            if Task.isCancelled { break }
            let url = URL(fileURLWithPath: item.path)
            guard FileManager.default.fileExists(atPath: item.path) else {
                gone.insert(item.id)
                continue
            }
            // System-owned items always need administrator approval.
            if item.requiresAdmin {
                needAdmin.append(AdminTrash.Request(id: item.id, path: item.path, size: item.size))
                continue
            }
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                freed += item.size
                gone.insert(item.id)
            } catch {
                let nsError = error as NSError
                if Self.isPermissionError(nsError) {
                    // Root-owned file in a user-writable listing (most
                    // commonly the .app itself under /Applications): retry
                    // with administrator approval below, one prompt total.
                    host?.log.info("Uninstaller needs administrator for \(item.path), will ask once")
                    needAdmin.append(AdminTrash.Request(id: item.id, path: item.path, size: item.size))
                } else {
                    host?.log.error("Uninstaller could not trash \(item.path): \(error.localizedDescription)")
                    failed += 1
                }
            }
        }

        // Escalate the remainder through one system Touch ID / password
        // prompt. Runs off the main actor: the dialog lives in
        // SecurityAgent, and `waitUntilExit` must never block Droppy's UI.
        var adminCancelled = false
        if !needAdmin.isEmpty, !Task.isCancelled {
            let label = appName ?? "Uninstaller"
            let result = await Task.detached(priority: .userInitiated) {
                AdminTrash.moveToTrash(
                    items: needAdmin,
                    prompt: "\(label) needs administrator permission to move \(needAdmin.count) item\(needAdmin.count == 1 ? "" : "s") to the Trash."
                )
            }.value
            freed += result.movedBytes
            gone.formUnion(result.movedIDs)
            failed += result.failed
            adminCancelled = result.cancelled
        }

        sections = sections.map { s in
            var c = s
            c.files.removeAll { gone.contains($0.id) }
            return c
        }.filter { !$0.files.isEmpty }
        selectedIDs.subtract(gone)

        lastTrashedBytes += freed
        lastTrashedDate = Date()
        host?.preferences.setValue(lastTrashedBytes, forKey: "lastTrashedBytes")

        phase = .results
        refreshShelfHold()
        if adminCancelled, freed > 0 {
            host?.log.notice("Uninstaller moved \(UninstallFormat.string(freed)); administrator approval was cancelled for the rest")
            presentNote("Moved \(UninstallFormat.string(freed)) — the rest was cancelled")
        } else if adminCancelled {
            presentNote("Cancelled — nothing was removed")
        } else if freed > 0, failed == 0 {
            host?.feedback.play(.success)
            host?.log.notice("Uninstaller moved \(UninstallFormat.string(freed)) to Trash")
            presentNote("Moved \(UninstallFormat.string(freed)) to Trash")
        } else if freed > 0 {
            host?.feedback.play(.success)
            presentNote("Moved \(UninstallFormat.string(freed)) — \(failed) items failed")
        } else if failed > 0 {
            host?.feedback.play(.failure)
            presentNote("Couldn't move to Trash — try again")
        }
        // App fully gone: reset to idle so the next app starts clean.
        if sections.isEmpty {
            clearApp()
        }
    }

    // MARK: HUD + review surface

    private func presentNote(_ text: String) {
        guard let host else { return }
        let request = DropletHUDRequest(
            id: "uninstaller.done",
            duration: 3.0,
            priority: .high,
            accessibilityLabel: text
        ) {
            HStack(spacing: 0) {
                Image(systemName: "trash")
                    .font(.system(size: DroppyLiveActivityMetrics.iconSize, weight: .semibold))
                Spacer(minLength: 0)
                Text(verbatim: text)
                    .font(.system(size: DroppyLiveActivityMetrics.labelFontSize, weight: .semibold))
                    .monospacedDigit()
            }
            .frame(maxWidth: .infinity)
            .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
        }
        _ = host.hud.present(request)
    }

    func closeReview() {
        host?.notchSurface.dismissExpandedSurface("uninstall-detail")
    }

    func openReview() {
        guard let host else { return }
        if host.isGranted(.expandedSurface) {
            let presentation = host.notchSurface.presentExpandedSurface(
                ExpandedSurfacePresentationRequest(surfaceID: "uninstall-detail", opensShelf: true)
            )
            if presentation != nil { return }
            host.log.error("Uninstaller review surface was refused, falling back to the shelf widget")
        }
        _ = host.shelf.open(revealing: "uninstaller")
    }
}

// MARK: - Shelf widget

extension UninstallerDroplet: ShelfWidgetProviding {
    public var widgetDescriptors: [ShelfWidgetDescriptor] {
        [
            ShelfWidgetDescriptor(
                id: "uninstaller",
                title: "Uninstaller",
                systemImage: "trash",
                layoutTraits: ShelfWidgetLayoutTraits(
                    preferredSoloWidth: 420,
                    preferredPairedWidth: 210,
                    contentHeight: .fixed(190)
                ),
                searchKeywords: ["uninstall", "remove", "delete", "app", "clean"]
            )
        ]
    }

    public func makeWidgetView(_ id: ShelfWidgetID, context: ShelfWidgetContext) -> AnyView {
        AnyView(UninstallerWidget(droplet: self, context: context))
    }

    public func makeWidgetSettingsPopover(_ id: ShelfWidgetID) -> AnyView? { nil }
}

private struct UninstallerWidget: View {
    @ObservedObject var droplet: UninstallerDroplet
    let context: ShelfWidgetContext

    var body: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.sm) {
            HStack(spacing: DroppySpacing.xsm) {
                Image(systemName: "trash")
                    .font(.system(size: 12, weight: .medium))
                Text("Uninstaller")
                    .font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 0)
                Text(verbatim: trailingText)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
            }
            .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)

            if context.isCompact {
                compactBody
            } else {
                fullBody
            }

            Spacer(minLength: 0)
        }
        .padding(context.contentInsets)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onDrop(of: [.fileURL], isTargeted: $droplet.isDropping) { providers in
            droplet.handleDrop(providers)
        }
        .onChange(of: droplet.isDropping) { _, _ in
            // A drag hovering the widget holds the shelf even in results.
            droplet.refreshShelfHold()
        }
        .overlay {
            if droplet.isDropping {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(.white.opacity(0.6), lineWidth: 1.5)
            }
        }
    }

    private var trailingText: String {
        if droplet.totalFound > 0 { return UninstallFormat.string(droplet.totalFound) + " found" }
        return droplet.appName ?? "Drop an app here"
    }

    private var compactBody: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.xsm) {
            Text(verbatim: droplet.appName ?? "No app")
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
            Button(droplet.sections.isEmpty ? "Scan" : "Review") {
                if droplet.sections.isEmpty { droplet.scan() } else { droplet.openReview() }
            }
            .buttonStyle(DroppyAccentButtonStyle(size: .small))
            .disabled(droplet.appPath == nil || droplet.phase == .scanning || droplet.phase == .trashing)
        }
    }

    private var fullBody: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.sm) {
            switch droplet.phase {
            case .idle:
                dropZone
            case .ready:
                appRow
                HStack(spacing: DroppySpacing.sm) {
                    Button("Scan for leftovers") { droplet.scan() }
                        .buttonStyle(DroppyAccentButtonStyle(size: .small))
                    Button("Change…") { droplet.chooseApp() }
                        .buttonStyle(DroppyQuietButtonStyle(size: .small))
                }
            case .scanning:
                HStack(spacing: DroppySpacing.sm) {
                    ProgressView().controlSize(.small).tint(.white)
                    Text("Scanning for related files…")
                        .font(.system(size: 13))
                        .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                    Spacer(minLength: 0)
                    Button("Cancel") { droplet.cancelScan() }
                        .buttonStyle(DroppyQuietButtonStyle(size: .small))
                }
            case .results:
                appRow
                HStack(spacing: DroppySpacing.sm) {
                    Button("Rescan") { droplet.scan() }
                        .buttonStyle(DroppyQuietButtonStyle(size: .small))
                    Button("Review") { droplet.openReview() }
                        .buttonStyle(DroppyQuietButtonStyle(size: .small))
                    Spacer(minLength: 0)
                    Text(verbatim: "\(droplet.selectedCount) of \(droplet.totalCount) selected")
                        .font(.system(size: 11))
                        .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
                }
                if droplet.selectedBytes > 0 {
                    Button("Move \(UninstallFormat.string(droplet.selectedBytes)) to Trash") {
                        droplet.trashSelected()
                    }
                    .buttonStyle(DroppyAccentButtonStyle(size: .small))
                }
            case .trashing:
                HStack(spacing: DroppySpacing.sm) {
                    ProgressView().controlSize(.small).tint(.white)
                    Text("Moving to Trash…")
                        .font(.system(size: 13))
                        .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                }
            }
        }
    }

    private var dropZone: some View {
        VStack(spacing: DroppySpacing.sm) {
            Image(systemName: "square.and.arrow.down")
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
            Text("Drag an app here")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
            Text("or choose one to scan")
                .font(.system(size: 12))
                .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
            Button {
                droplet.chooseApp()
            } label: {
                Label("Choose app…", systemImage: "plus.circle")
            }
            .buttonStyle(DroppyQuietButtonStyle(size: .small))
            Text("Nothing is removed without your confirmation.")
                .font(.system(size: 11))
                .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DroppySpacing.sm)
    }

    private var appRow: some View {
        HStack(spacing: DroppySpacing.sm) {
            if let path = droplet.appPath {
                Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                    .resizable()
                    .frame(width: 32, height: 32)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: droplet.appName ?? "App")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                    .lineLimit(1)
                Text(verbatim: droplet.bundleID ?? "")
                    .font(.system(size: 11))
                    .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            Button {
                droplet.clearApp()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(DroppyCircleButtonStyle(size: 20))
            .help("Choose a different app")
            .accessibilityLabel("Clear selected app")
        }
    }
}

// MARK: - Expanded surface (review list)

extension UninstallerDroplet: ExpandedSurfaceHosting {
    public var expandedSurfaceProvider: (any ExpandedSurfaceProviding)? { self }
}

extension UninstallerDroplet: ExpandedSurfaceProviding {
    public var expandedSurfaces: [ExpandedSurfaceDescriptor] {
        [
            ExpandedSurfaceDescriptor(
                id: "uninstall-detail",
                title: "Uninstaller",
                systemImage: "trash",
                suppresses: [.shelfWidgets, .autoCollapse]
            )
        ]
    }

    public func makeExpandedSurfaceView(_ id: ExpandedSurfaceID, context: ExpandedSurfaceContext) -> AnyView {
        AnyView(UninstallerDetail(droplet: self))
    }

    public func expandedSurfaceSize(_ id: ExpandedSurfaceID, fitting proposal: ExpandedSurfaceSizeProposal) -> CGSize? {
        let rows = CGFloat(max(sections.count, 1))
        let height = min(proposal.maximumSize.height, max(400, 170 + rows * 90))
        return CGSize(width: proposal.standardSize.width, height: height)
    }

    public func expandedSurfaceDidDismiss(
        _ id: ExpandedSurfaceID,
        presentation: ExpandedSurfacePresentation,
        reason: ExpandedSurfaceDismissalReason
    ) {
        host?.log.debug("Uninstall detail dismissed: \(reason)")
    }
}

private struct UninstallerDetail: View {
    @ObservedObject var droplet: UninstallerDroplet

    var body: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.sm) {
            header
            if droplet.phase == .scanning {
                scanningRow
            } else if droplet.sections.isEmpty {
                emptyRow
            } else {
                list
            }
            footer
        }
        .padding(DroppySpacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        HStack(spacing: DroppySpacing.xsm) {
            if let path = droplet.appPath {
                Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                    .resizable()
                    .frame(width: 28, height: 28)
            } else {
                Image(systemName: "trash")
                    .font(.system(size: 12, weight: .medium))
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: droplet.appName ?? "Uninstaller")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                    .lineLimit(1)
                Text(verbatim: droplet.bundleID ?? "")
                    .font(.system(size: 11))
                    .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            Text(verbatim: droplet.totalFound > 0 ? UninstallFormat.string(droplet.totalFound) + " found" : "")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
            Button {
                droplet.closeReview()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(DroppyCircleButtonStyle(size: 20))
            .help("Back")
            .accessibilityLabel("Back to the shelf")
        }
    }

    private var scanningRow: some View {
        HStack(spacing: DroppySpacing.sm) {
            ProgressView().controlSize(.small).tint(.white)
            Text("Scanning for related files…")
                .font(.system(size: 13))
                .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
            Spacer(minLength: 0)
            Button("Cancel") { droplet.cancelScan() }
                .buttonStyle(DroppyQuietButtonStyle(size: .small))
        }
        .padding(.vertical, DroppySpacing.md)
    }

    private var emptyRow: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.sm) {
            Text("No app selected")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
            Text("Choose an app in the shelf widget first — drag it on or pick one to scan.")
                .font(.system(size: 13))
                .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
            Button("Choose app…") { droplet.chooseApp() }
                .buttonStyle(DroppyAccentButtonStyle(size: .small))
        }
        .padding(.vertical, DroppySpacing.sm)
    }

    private var list: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: DroppySpacing.md) {
                ForEach(droplet.sections) { section in
                    VStack(alignment: .leading, spacing: DroppySpacing.xsm) {
                        HStack(spacing: DroppySpacing.sm) {
                            Toggle("", isOn: Binding(
                                get: { droplet.isSectionSelected(section) },
                                set: { _ in droplet.toggleSection(section) }
                            ))
                            .labelsHidden()
                            .toggleStyle(.checkbox)
                            Text(section.id.title.uppercased())
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
                            Spacer(minLength: 0)
                            Text(verbatim: UninstallFormat.string(section.totalSize))
                                .font(.system(size: 12, weight: .medium, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                        }
                        ForEach(section.files) { file in
                            HStack(spacing: DroppySpacing.xsm) {
                                Toggle("", isOn: Binding(
                                    get: { droplet.selectedIDs.contains(file.id) },
                                    set: { _ in droplet.toggleFile(file) }
                                ))
                                .labelsHidden()
                                .toggleStyle(.checkbox)
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(verbatim: file.name)
                                        .font(.system(size: 12))
                                        .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Text(verbatim: file.shortPath)
                                        .font(.system(size: 10))
                                        .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                        .help(file.path)
                                    if file.requiresAdmin {
                                        Text("System-owned — Touch ID approval is requested.")
                                            .font(.system(size: 10, weight: .medium))
                                            .foregroundStyle(.orange)
                                    }
                                }
                                Spacer(minLength: DroppySpacing.sm)
                                Text(verbatim: UninstallFormat.string(file.size))
                                    .font(.system(size: 12, weight: .medium, design: .rounded))
                                    .monospacedDigit()
                                    .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                            }
                            .opacity(file.requiresAdmin ? 0.6 : 1)
                        }
                    }
                    Divider().opacity(0.25)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 320)
    }

    private var footer: some View {
        HStack(spacing: DroppySpacing.sm) {
            Text(verbatim: "\(droplet.selectedCount) of \(droplet.totalCount) selected")
                .font(.system(size: 12))
                .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                .lineLimit(1)
            Spacer(minLength: 0)
            Button("Cancel") { droplet.closeReview() }
                .buttonStyle(DroppyQuietButtonStyle(size: .small))
            Button("Move to Trash") {
                droplet.trashSelected()
            }
            .buttonStyle(DroppyAccentButtonStyle(size: .small))
            .disabled(droplet.selectedIDs.isEmpty || droplet.phase == .trashing)
        }
    }
}

// MARK: - HUD

extension UninstallerDroplet: HUDPresenting {}

// MARK: - Settings pane

extension UninstallerDroplet: SettingsPaneProviding {
    public func makeSettingsPane(context: SettingsPaneContext) -> AnyView {
        AnyView(UninstallerSettings(droplet: self))
    }

    public var settingsSearchEntries: [SettingsSearchEntry] {
        [SettingsSearchEntry(title: "Uninstaller", keywords: ["uninstall", "remove", "delete", "app"])]
    }
}

private struct UninstallerSettings: View {
    @ObservedObject var droplet: UninstallerDroplet

    var body: some View {
        DropletSettingsPane {
            DropletSettingsCard {
                DropletToggleRow(
                    title: "Quit the app before removing",
                    subtitle: "Running apps are quit so their bundle and preferences can be trashed.",
                    isOn: droplet.quitBeforeTrashBinding
                )
                DropletToggleRow(
                    title: "List system-owned leftovers",
                    subtitle: "Shows matches under /Library too. Touch ID approval is requested when removing them.",
                    isOn: droplet.includeSystemBinding
                )
            }

            DropletSettingsSection {
                settingsSectionHeader("Last removal")
            } content: {
                DropletSettingsCard {
                    DropletControlRow(title: "Moved to Trash so far") {
                        DropletValuePill(text: UninstallFormat.string(droplet.lastTrashedBytes))
                    }
                }
            }
        }
    }
}
