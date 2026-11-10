import AppKit
import WebKit
import UniformTypeIdentifiers
import Security
import CryptoKit
import Darwin

private final class StillWebView: WKWebView {
    var hasWritingEditor = false

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        for item in menu.items where item.action == #selector(insertPoem) {
            if let previous = menu.item(at: max(0, menu.index(of: item) - 1)), previous.isSeparatorItem {
                menu.removeItem(previous)
            }
            menu.removeItem(item)
        }
        guard hasWritingEditor else { return }
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        let item = NSMenuItem(title: "Insert poem…", action: #selector(insertPoem), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
    }

    @objc private func insertPoem() {
        evaluateJavaScript("window.dispatchEvent(new Event('still:insert-poem'))", completionHandler: nil)
    }
}

private final class WritingEditorPresenceHandler: NSObject, WKScriptMessageHandler {
    weak var webView: StillWebView?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "stillWritingEditor",
              message.frameInfo.isMainFrame,
              let exists = message.body as? Bool else { return }
        webView?.hasWritingEditor = exists
    }
}

private final class WritingExportMessageHandler: NSObject, WKScriptMessageHandler {
    weak var application: StillApplication?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame,
              let payload = message.body as? [String: Any],
              let origin = message.frameInfo.request.url else { return }
        let name = message.name
        Task { @MainActor [weak application] in
            guard let application, let backend = application.backend,
                  CorrespondenceNavigationPolicy.isLocalRoom(origin, port: backend.port) else { return }
            if name == "stillPDFExport" {
                await application.exportWritingPDF(payload)
            } else if name == "stillRevealExport" {
                await application.revealWritingExport(payload)
            }
        }
    }
}

enum StillError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case let .message(text) = self { return text }
        return nil
    }
}

@MainActor
final class Backend {
    private(set) var process: Process?
    private var lock: Int32 = -1
    let dataDirectory: URL
    let profile: UUID
    let port: Int
    let url: URL
    let release: URL
    let controlToken = UUID().uuidString
    private let guardURL: URL
    private var log: FileHandle?

    init() throws {
        let env = ProcessInfo.processInfo.environment
        guard let resources = Bundle.main.resourceURL,
              let executable = Bundle.main.executableURL
        else { throw StillError.message("Still could not find its local room.") }
        let explicit = env["STILL_DATA_DIRECTORY"]
        let fallback = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Still/Writing", isDirectory: true)
        dataDirectory = try WritingLocation.resolve(override: explicit,
            bookmark: nil, legacyPath: nil, fallback: fallback)
        profile = WritingLocation.profile(for: dataDirectory)
        let configuredPort = env["STILL_NATIVE_PORT"] ?? Bundle.main.object(forInfoDictionaryKey: "StillNativePort") as? String
        port = Int(configuredPort ?? "4040") ?? 4040
        guard (1024...65535).contains(port) else { throw StillError.message("Still’s local port is invalid.") }
        url = URL(string: "http://localhost:\(port)")!
        release = resources.appendingPathComponent("backend/bin/still")
        guardURL = executable.deletingLastPathComponent().appendingPathComponent("StillBackend")
    }

    func start() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dataDirectory, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        let work = dataDirectory.appendingPathComponent("native", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        lock = open(work.appendingPathComponent("backend.lock").path, O_CREAT | O_RDWR, 0o600)
        guard lock >= 0, flock(lock, LOCK_EX | LOCK_NB) == 0 else {
            throw StillError.message("Still is already open. Return to its existing window.")
        }
        _ = fcntl(lock, F_SETFD, FD_CLOEXEC)
        // A stable origin keeps WebKit's unsent recovery copies available after
        // reopening. Refuse an occupied port rather than loading another server.
        let probe = socket(AF_INET, SOCK_STREAM, 0)
        guard probe >= 0 else { throw StillError.message("Still could not open a local connection.") }
        // Match the backend's address reuse. A just-closed WebView connection
        // can leave TIME_WAIT behind without any application listening here.
        var reuse: Int32 = 1
        guard setsockopt(probe, SOL_SOCKET, SO_REUSEADDR, &reuse,
                         socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            close(probe)
            throw StillError.message("Still could not prepare a local connection.")
        }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let available = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(probe, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
        close(probe)
        guard available else {
            throw StillError.message("Another application is using Still’s local port \(port). Close it and reopen Still.")
        }
        let secretFile = dataDirectory.appendingPathComponent(".secret_key_base")
        if !fm.fileExists(atPath: secretFile.path) {
            var bytes = [UInt8](repeating: 0, count: 64)
            guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
                throw StillError.message("Still could not prepare its local key.")
            }
            try Data(Data(bytes).base64EncodedString().utf8).write(to: secretFile, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: secretFile.path)
        }
        let secret = try String(contentsOf: secretFile, encoding: .utf8)
        var env = ProcessInfo.processInfo.environment
        env["DATABASE_PATH"] = dataDirectory.appendingPathComponent("still.db").path
        env["SECRET_KEY_BASE"] = secret
        env["PHX_HOST"] = "localhost"
        env["PHX_SERVER"] = "true"
        env["STILL_NATIVE"] = "true"
        env["STILL_NATIVE_CONTROL_TOKEN"] = controlToken
        env["PORT"] = String(port)
        env["RELEASE_DISTRIBUTION"] = "none"
        env["RELEASE_TMP"] = work.path
        env["ERL_CRASH_DUMP"] = work.appendingPathComponent("erl_crash.dump").path
        env["ERL_FLAGS"] = "+S 2:2"
        let logFile = work.appendingPathComponent("backend.log")
        if fm.fileExists(atPath: logFile.path) {
            let previous = work.appendingPathComponent("backend.previous.log")
            try? fm.removeItem(at: previous)
            try? fm.moveItem(at: logFile, to: previous)
        }
        _ = fm.createFile(atPath: logFile.path, contents: nil, attributes: [.posixPermissions: 0o600])
        log = try FileHandle(forWritingTo: logFile)
        let child = Process()
        child.executableURL = guardURL
        child.arguments = [release.path]
        child.environment = env
        child.currentDirectoryURL = dataDirectory
        child.standardOutput = log
        child.standardError = log
        try child.run()
        process = child
    }

    func ready() async throws {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        for _ in 0..<100 {
            guard process?.isRunning == true else {
                throw StillError.message("Still could not open its room. Its local startup log is in \(dataDirectory.path)/native/backend.log.")
            }
            var request = URLRequest(url: url.appendingPathComponent("healthz"))
            request.timeoutInterval = 0.4
            if let (bytes, response) = try? await session.data(for: request),
               (response as? HTTPURLResponse)?.statusCode == 200,
               String(data: bytes, encoding: .utf8) == "ok" { return }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        throw StillError.message("Still took too long to open. Another application may be using its local port \(port).")
    }

    func stop() async {
        if let process, process.isRunning {
            process.terminate()
            for _ in 0..<75 {
                if !process.isRunning { break }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        try? log?.close()
        if lock >= 0 { flock(lock, LOCK_UN); close(lock); lock = -1 }
    }

    func storageRequest(_ method: String, path: String = "/native/storage", body: [String: Any]? = nil) async throws -> Data {
        var request = URLRequest(url: URL(string: path, relativeTo: url)!.absoluteURL)
        request.httpMethod = method
        request.timeoutInterval = 15
        request.setValue(controlToken, forHTTPHeaderField: "x-still-native-token")
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            let detail = (try? JSONDecoder().decode([String: String].self, from: data))?["error"] ??
                (String(data: data, encoding: .utf8) ?? "")
            throw StillError.message(detail.isEmpty ? "Still could not update backup settings." : detail)
        }
        return data
    }

    func storageStatus() async throws -> StorageStatus {
        let data = try await storageRequest("GET")
        do { return try JSONDecoder().decode(StorageStatus.self, from: data) }
        catch { throw StillError.message("Still received an unreadable backup status.") }
    }
}

struct StorageStatus: Decodable {
    struct Backup: Decodable { let path: String; let at: String }
    let configured: Bool
    let folder: String?
    let available: Bool
    let last_backup: Backup?
    let changed: Bool
    let error: String?
}

@MainActor
final class StillApplication: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    var window: NSWindow!
    var webView: WKWebView!
    var backend: Backend?
    private var openingRoom = false
    private var choosingFolder = false
    private var closeInProgress = false
    private var backingUp = false
    private var exportingPDF = false
    private struct PendingManuscriptDownload {
        let destination: URL
        let staging: URL
    }
    private var manuscriptDownloads: [ObjectIdentifier: PendingManuscriptDownload] = [:]
    var quitting = false

    private func generousFrame(on screen: NSScreen?) -> NSRect {
        let available = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let width = min(1700, available.width * 0.9)
        let height = min(1040, available.height * 0.9)
        return NSRect(x: available.midX - width / 2, y: available.midY - height / 2,
                      width: width, height: height)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        createMenu()
        let initialFrame = generousFrame(on: NSScreen.main)
        window = NSWindow(contentRect: initialFrame,
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "Still"
        window.titleVisibility = .hidden
        // Keep an actual AppKit titlebar above the WebView. AppKit owns its
        // dragging, double-click preference, desktop fill, zoom and restore.
        window.titlebarAppearsTransparent = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(srgbRed: 0.063, green: 0.078, blue: 0.102, alpha: 1)
        window.minSize = NSSize(width: 620, height: 460)
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenPrimary]
        window.tabbingMode = .disallowed
        window.delegate = self
        window.setFrameAutosaveName("StillRoom")
        let restored = window.setFrameUsingName("StillRoom")
        let firstGenerousLaunch = !UserDefaults.standard.bool(forKey: "Still.generousWindowDefault")
        let legacyDefault = abs(window.frame.width - 1120) < 1 && abs(window.frame.height - 820) < 1
        if !restored || (firstGenerousLaunch && legacyDefault) { window.setFrame(initialFrame, display: false) }
        UserDefaults.standard.set(true, forKey: "Still.generousWindowDefault")
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        Task {
            do { try await openRoom() }
            catch { if !quitting { showFailure(error) } }
        }
    }

    private func openRoom() async throws {
        openingRoom = true
        defer { openingRoom = false }
        let room = try Backend()
        do {
            try room.start()
            try await room.ready()
        } catch {
            await room.stop()
            throw error
        }
        backend = room
        let status = try? await room.storageStatus()
        let profile = status?.folder.map { WritingLocation.profile(for: URL(fileURLWithPath: $0, isDirectory: true)) } ?? room.profile
        webView = makeWebView(profile: profile)
        webView.load(URLRequest(url: reopeningURL(room)))
        room.process?.terminationHandler = { [weak self, weak room] _ in
            Task { @MainActor in
                if let self, let room, self.backend === room, !self.quitting {
                    self.showFailure(StillError.message("The local room closed unexpectedly. Unsent words remain in this app. Close and reopen Still."))
                }
            }
        }
    }

    private func makeWebView(profile: UUID) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: profile)
        let userContentController = WKUserContentController()
        let editorPresenceScript = WKUserScript(source: """
        (() => {
          const selector = 'textarea[data-writing-segment], #file-writing-body, #writing-body';
          let previous;
          const report = () => {
            const exists = Boolean(document.querySelector(selector));
            if (exists !== previous) {
              previous = exists;
              window.webkit.messageHandlers.stillWritingEditor.postMessage(exists);
            }
          };
          document.addEventListener('DOMContentLoaded', report);
          window.addEventListener('phx:page-loading-stop', report);
          report();
        })();
        """, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        userContentController.addUserScript(editorPresenceScript)
        configuration.userContentController = userContentController
        let view = StillWebView(frame: .zero, configuration: configuration)
        let editorPresenceHandler = WritingEditorPresenceHandler()
        editorPresenceHandler.webView = view
        userContentController.add(editorPresenceHandler, name: "stillWritingEditor")
        let exportHandler = WritingExportMessageHandler()
        exportHandler.application = self
        userContentController.add(exportHandler, name: "stillPDFExport")
        userContentController.add(exportHandler, name: "stillRevealExport")
        view.underPageBackgroundColor = window.backgroundColor
        view.allowsBackForwardNavigationGestures = false
        view.allowsMagnification = false
        view.allowsLinkPreview = false
        view.navigationDelegate = self
        view.uiDelegate = self
        window.contentView = view
        return view
    }

    fileprivate func exportWritingPDF(_ payload: [String: Any]) async {
        let requestID = payload["request_id"] as? String ?? ""
        let complete: ([String: String]) -> Void = { [weak self] detail in
            self?.writingExportResult(detail.merging(["request_id": requestID]) { _, new in new })
        }
        guard !exportingPDF else {
            complete(["error": "A PDF is already being prepared. Wait for it to finish."])
            return
        }
        guard let backend, let ticket = payload["ticket"] as? String, !requestID.isEmpty else {
            complete(["error": "The PDF request is incomplete. Export it again."])
            return
        }
        exportingPDF = true
        defer { exportingPDF = false }
        do {
            // Fetch verified words directly; page scripts supply only the signed request.
            let input = try await backend.storageRequest("POST", path: "/native/exports/pdf/input", body: ["ticket": ticket])
            guard let prepared = try JSONSerialization.jsonObject(with: input) as? [String: Any],
                  let title = prepared["title"] as? String,
                  let rawSegments = prepared["segments"] as? [[String: Any]], rawSegments.count <= 2000 else {
                throw StillError.message("The PDF content is incomplete. Export it again.")
            }
            var segments: [WritingPDF.Segment] = []
            var size = 0
            for raw in rawSegments {
                guard let body = raw["body"] as? String,
                      let kind = raw["kind"] as? String, ["text", "poem"].contains(kind) else {
                    throw StillError.message("The PDF passage is incomplete. Export it again.")
                }
                size += body.utf8.count
                guard size <= 10_000_000 else {
                    throw StillError.message("This writing is too large for PDF export. Markdown export remains available.")
                }
                segments.append(WritingPDF.Segment(body: body, inset: kind == "poem"))
            }
            let renderSegments = segments
            let data = try await Task.detached(priority: .userInitiated) {
                try WritingPDF.render(title: title, segments: renderSegments)
            }.value
            let response = try await backend.storageRequest("POST", path: "/native/exports/pdf", body: [
                "ticket": ticket, "pdf": data.base64EncodedString()
            ])
            guard let result = try JSONSerialization.jsonObject(with: response) as? [String: String],
                  let path = result["path"] else {
                throw StillError.message("Still could not confirm the PDF was saved.")
            }
            complete(["path": path])
        } catch {
            complete(["error": error.localizedDescription])
        }
    }

    private func writingExportResult(_ detail: [String: String]) {
        guard let data = try? JSONSerialization.data(withJSONObject: detail),
              let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.dispatchEvent(new CustomEvent('still:pdf-export-result', {detail: \(json)}))", completionHandler: nil)
    }

    fileprivate func revealWritingExport(_ payload: [String: Any]) async {
        guard let path = payload["path"] as? String,
              let status = try? await backend?.storageStatus(), let folder = status.folder else { return }
        let root = URL(fileURLWithPath: folder, isDirectory: true)
        let exports = root.deletingLastPathComponent().appendingPathComponent(root.lastPathComponent + " Exports", isDirectory: true).standardizedFileURL
        let file = URL(fileURLWithPath: path).standardizedFileURL
        guard file.path.hasPrefix(exports.path + "/"),
              ["md", "pdf"].contains(file.pathExtension.lowercased()),
              file.resolvingSymlinksInPath().path == file.path,
              FileManager.default.fileExists(atPath: file.path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([file])
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if quitting { return .terminateNow }
        if backingUp {
            showStorageNotice("A backup is in progress. Wait for it to finish before closing Still.")
            return .terminateCancel
        }
        beginCloseFlow()
        return .terminateLater
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !quitting else { return true }
        NSApp.terminate(nil)
        return false
    }

    private func beginCloseFlow() {
        guard !closeInProgress else { return }
        closeInProgress = true
        Task {
            do {
                await setEditorFrozen(true)
                // Give the editor recovery hook its normal window before
                // checking changed state, since that flush can save new text.
                await prepareToLeave(wait: 900_000_000)
                guard await fileReadyForLeaving() else {
                    showStorageNotice("This writing has no safe recovery copy. Save it to the collection or copy its words before closing Still.")
                    cancelClose()
                    return
                }
                let remindersEnabled = UserDefaults.standard.bool(forKey: "Still.backupReminderOnClose")
                let editorReady = remindersEnabled ? await editorReadyForBackup() : true
                let status = remindersEnabled ? (try? await backend?.storageStatus()) : nil
                if ClosePolicy.resolve(changed: status?.changed != false, editorReady: editorReady,
                                       remindersEnabled: remindersEnabled) == .askForChoice {
                    let choice = await askCloseChoice(hasFolder: status?.configured == true && status?.available == true)
                    switch ClosePolicy.resolve(changed: status?.changed != false, editorReady: editorReady, choice: choice,
                                                hasBackupFolder: status?.configured == true && status?.available == true) {
                    case .cancel: cancelClose(); return
                    case .close: await finishClose(); return
                    case .backUp: break
                    case .chooseBackupFolder:
                        showCloseError("Choose a writing folder from File → Choose Writing Folder… before backing up and closing.")
                        cancelClose(); return
                    case .askForChoice: break
                    }
                    guard status != nil else {
                        showCloseError("Still cannot reach its local backup settings. You can close without a backup or cancel and try again.")
                        cancelClose(); return
                    }
                    guard editorReady else {
                        showCloseError("Some words are still waiting to be saved. Save or recover them before backing up and closing.")
                        cancelClose(); return
                    }
                    let backupData = try await backend!.storageRequest("POST", path: "/native/backup")
                    let backedUp = try JSONDecoder().decode(StorageStatus.self, from: backupData)
                    let result = ClosePolicy.backupResult(editorReady: editorReady,
                        backupConfirmed: true, stillChanged: backedUp.changed)
                    guard result == .close else {
                        throw StillError.message("A newer writing change arrived during the backup. Run Back Up Now again before closing.")
                    }
                    await finishClose()
                    return
                }
                await finishClose()
            } catch {
                showCloseError(error.localizedDescription)
                cancelClose()
            }
        }
    }

    private func askCloseChoice(hasFolder: Bool) async -> CloseChoice {
        await withCheckedContinuation { continuation in
            let alert = NSAlert()
            alert.messageText = "Back up your writing before closing?"
            alert.informativeText = hasFolder
                ? "Your database has changed since its last backup. New writing files and local drafts are separate from this database snapshot."
                : "Your collection has changed and has no available writing folder for its database backup. You can close now and choose a folder later."
            alert.addButton(withTitle: "Back Up & Close")
            alert.addButton(withTitle: "Close Without Backing Up")
            alert.addButton(withTitle: "Cancel")
            alert.beginSheetModal(for: window) { response in
                continuation.resume(returning: response == .alertFirstButtonReturn ? .backUpAndClose :
                                    response == .alertSecondButtonReturn ? .closeWithoutBackingUp : .cancel)
            }
        }
    }

    private func editorReadyForBackup() async -> Bool {
        guard await fileReadyForLeaving() else { return false }
        guard let webView else { return true }
        let script = """
        (() => { const form = document.getElementById('writing-form');
          return !form || (form.dataset.unsaved !== 'true' && form.dataset.saveBlocked !== 'true'); })()
        """
        for _ in 0..<12 {
            let value: Any? = await withCheckedContinuation { done in
                webView.evaluateJavaScript(script) { value, _ in done.resume(returning: value) }
            }
            if value as? Bool == true { return true }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return false
    }

    private func fileReadyForLeaving() async -> Bool {
        guard let webView else { return true }
        let script = """
        (() => { const form = document.getElementById('file-writing-form');
          const body = document.getElementById('file-writing-body');
          return {hasFile: !!form, authoritative: form?.dataset.authoritative === 'true',
            unsaved: form?.dataset.unsaved === 'true',
            hasContent: !!body?.value.length || !!document.getElementById('file-writing-title')?.value.length,
            recoverySafe: form?.dataset.recoverySafe === 'true'}; })()
        """
        let state: [String: Bool]? = await withCheckedContinuation { done in
            webView.evaluateJavaScript(script) { value, _ in done.resume(returning: value as? [String: Bool]) }
        }
        guard let state else { return false }
        return FileLeavePolicy.allowsLeaving(hasFile: state["hasFile"] == true,
            authoritative: state["authoritative"] == true, unsaved: state["unsaved"] == true,
            hasContent: state["hasContent"] == true, recoverySafe: state["recoverySafe"] == true)
    }

    private func setEditorFrozen(_ frozen: Bool) async {
        guard let webView else { return }
        let script = frozen
            ? "window.__stillHadEditorFocus = ['writing-body','file-writing-body','file-writing-title'].includes(document.activeElement?.id) ? document.activeElement.id : null; document.body.inert = true; true"
            : "document.body.inert = false; if (window.__stillHadEditorFocus) document.getElementById(window.__stillHadEditorFocus)?.focus({preventScroll:true}); delete window.__stillHadEditorFocus; true"
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            webView.evaluateJavaScript(script) { _, _ in done.resume() }
        }
    }

    private func finishClose() async {
        quitting = true
        await backend?.stop()
        NSApp.reply(toApplicationShouldTerminate: true)
    }

    private func cancelClose() {
        closeInProgress = false
        quitting = false
        Task { await setEditorFrozen(false) }
        NSApp.reply(toApplicationShouldTerminate: false)
    }

    private func showCloseError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Still could not complete that backup action."
        alert.informativeText = message
        alert.beginSheetModal(for: window, completionHandler: nil)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        window.makeKeyAndOrderFront(nil)
        return true
    }

    func windowWillUseStandardFrame(_ window: NSWindow, defaultFrame newFrame: NSRect) -> NSRect {
        window.screen?.visibleFrame ?? newFrame
    }

    func windowDidEnterFullScreen(_ notification: Notification) { updateRoomEnvironment() }
    func windowDidExitFullScreen(_ notification: Notification) { updateRoomEnvironment() }

    private func updateRoomEnvironment() {
        guard let webView else { return }
        let fullscreen = window.styleMask.contains(.fullScreen) ? "true" : "false"
        webView.evaluateJavaScript("document.documentElement.dataset.nativeFullscreen = '\(fullscreen)'", completionHandler: nil)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if closeInProgress || backingUp { return false }
        if item.action == #selector(toggleBackupReminder(_:)) {
            item.state = UserDefaults.standard.bool(forKey: "Still.backupReminderOnClose") ? .on : .off
            return !quitting
        }
        if item.action == #selector(chooseWritingFolder(_:)) { return !quitting && !openingRoom && !choosingFolder }
        if item.action == #selector(clearWritingFolder(_:)) || item.action == #selector(backupNow(_:)) {
            return !quitting && !openingRoom && !choosingFolder
        }
        if item.action == #selector(fullscreen(_:)) {
            item.title = window?.styleMask.contains(.fullScreen) == true ? "Exit Full Screen" : "Enter Full Screen"
        }
        return true
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let userInitiated = navigationAction.navigationType == .linkActivated
        let choice = CorrespondenceNavigationPolicy.decide(
            navigationAction.request.url,
            localPort: backend?.port ?? -1,
            userInitiated: userInitiated
        )

        switch choice {
        case .allowInApp:
            decisionHandler(.allow)
        case .openExternal:
            decisionHandler(.cancel)
            if let address = navigationAction.request.url, !NSWorkspace.shared.open(address) {
                showStorageNotice("Still could not open that website in your default browser.")
            }
        case .cancel:
            decisionHandler(.cancel)
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        guard let address = navigationResponse.response.url,
              CorrespondenceNavigationPolicy.isLocalRoom(address, port: backend?.port ?? -1) else {
            decisionHandler(.cancel)
            return
        }

        let response = navigationResponse.response as? HTTPURLResponse
        if CorrespondenceNavigationPolicy.shouldDownloadResponse(
            url: address,
            localPort: backend?.port ?? -1,
            statusCode: response?.statusCode,
            contentDisposition: response?.value(forHTTPHeaderField: "Content-Disposition")
        ) {
            decisionHandler(.download)
        } else {
            decisionHandler(.allow)
        }
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        guard let address = navigationAction.request.url,
              CorrespondenceNavigationPolicy.isLocalRoom(address, port: backend?.port ?? -1),
              CorrespondenceNavigationPolicy.isManuscriptExport(address) else {
            download.cancel(nil)
            return
        }
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        guard let address = navigationResponse.response.url,
              CorrespondenceNavigationPolicy.isLocalRoom(address, port: backend?.port ?? -1),
              CorrespondenceNavigationPolicy.isManuscriptExport(address) else {
            download.cancel(nil)
            return
        }
        download.delegate = self
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        guard let window else { completionHandler(nil); return }
        let panel = NSSavePanel()
        panel.title = "Save manuscript"
        panel.message = "Choose where to save this manuscript."
        panel.prompt = "Save"
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = URL(fileURLWithPath: suggestedFilename).lastPathComponent
        panel.beginSheetModal(for: window) { [weak self] result in
            guard let self, result == .OK, let destination = panel.url else {
                completionHandler(nil)
                return
            }

            let parent = destination.deletingLastPathComponent()
            guard FileManager.default.fileExists(atPath: parent.path),
                  let parentValues = try? parent.resourceValues(forKeys: [.isDirectoryKey]),
                  parentValues.isDirectory == true,
                  self.isSafeDownloadDestination(destination) else {
                self.showDownloadError("Choose a writable folder and a regular file name.")
                completionHandler(nil)
                return
            }

            let staging = parent.appendingPathComponent(
                ".\(destination.lastPathComponent).still-\(UUID().uuidString).partial"
            )
            self.manuscriptDownloads[ObjectIdentifier(download)] =
                PendingManuscriptDownload(destination: destination, staging: staging)
            completionHandler(staging)
        }
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let pending = manuscriptDownloads.removeValue(forKey: ObjectIdentifier(download)) else { return }
        do {
            guard isRegularFile(pending.staging) else {
                throw StillError.message("The downloaded manuscript is missing or unsafe.")
            }
            if try publishDownload(from: pending.staging, to: pending.destination) {
                showStorageNotice("Manuscript saved as \(pending.destination.lastPathComponent).")
            } else {
                showDownloadError("The manuscript is present, but Still could not confirm that the folder entry is durable. Check the selected folder before continuing.")
            }
        } catch {
            try? FileManager.default.removeItem(at: pending.staging)
            showDownloadError(error.localizedDescription)
        }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        guard let pending = manuscriptDownloads.removeValue(forKey: ObjectIdentifier(download)) else { return }
        try? FileManager.default.removeItem(at: pending.staging)
        let nsError = error as NSError
        if nsError.code != NSURLErrorCancelled {
            showDownloadError("The manuscript download did not finish. \(error.localizedDescription)")
        }
    }

    private func isSafeDownloadDestination(_ url: URL) -> Bool {
        var info = stat()
        let result = url.path.withCString { lstat($0, &info) }
        if result == 0 { return (info.st_mode & S_IFMT) == S_IFREG }
        return errno == ENOENT
    }

    private func isRegularFile(_ url: URL) -> Bool {
        var info = stat()
        return url.path.withCString { lstat($0, &info) } == 0 && (info.st_mode & S_IFMT) == S_IFREG
    }

    private func publishDownload(from staging: URL, to destination: URL) throws -> Bool {
        guard isSafeDownloadDestination(destination) else {
            throw StillError.message("The chosen destination changed or is not a regular file. The existing item was left untouched.")
        }
        let file = staging.path.withCString { open($0, O_RDWR) }
        guard file >= 0 else {
            throw StillError.message("Still could not prepare the downloaded manuscript for saving.")
        }
        let fileReady = fchmod(file, 0o600) == 0 && fsync(file) == 0
        close(file)
        guard fileReady else {
            throw StillError.message("Still could not sync the downloaded manuscript. The existing file was left untouched.")
        }
        let result = staging.path.withCString { source in
            destination.path.withCString { target in Darwin.rename(source, target) }
        }
        guard result == 0 else {
            let reason = String(cString: strerror(errno))
            throw StillError.message("Still could not save the completed manuscript: \(reason)")
        }
        return syncDirectory(destination.deletingLastPathComponent())
    }

    private func syncDirectory(_ directory: URL) -> Bool {
        let descriptor = directory.path.withCString { open($0, O_RDONLY) }
        guard descriptor >= 0 else { return false }
        let result = fsync(descriptor)
        close(descriptor)
        return result == 0
    }

    private func showDownloadError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Still could not save the manuscript."
        alert.informativeText = message
        alert.beginSheetModal(for: window, completionHandler: nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        updateRoomEnvironment()
        window.makeFirstResponder(webView)
        webView.evaluateJavaScript("""
        (() => { const editor = document.getElementById('writing-body') || document.getElementById('file-writing-body');
          if (editor && document.activeElement !== editor && !editor.linkedEditor?.owns(document.activeElement)) {
            if (editor.linkedEditor) editor.linkedEditor.focus();
            else editor.focus({preventScroll: true});
          } })()
        """, completionHandler: nil)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        (webView as? StillWebView)?.hasWritingEditor = false
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        let choice = CorrespondenceNavigationPolicy.decide(
            navigationAction.request.url,
            localPort: backend?.port ?? -1,
            userInitiated: navigationAction.navigationType == .linkActivated
        )
        switch choice {
        case .allowInApp:
            webView.load(navigationAction.request)
        case .openExternal:
            if let address = navigationAction.request.url, !NSWorkspace.shared.open(address) {
                showStorageNotice("Still could not open that website in your default browser.")
            }
        case .cancel:
            break
        }
        return nil
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        guard frame.isMainFrame, let frameURL = frame.request.url,
              CorrespondenceNavigationPolicy.isLocalRoom(frameURL, port: backend?.port ?? -1)
        else { completionHandler(nil); return }
        let panel = NSOpenPanel()
        panel.title = "Import Places"
        panel.message = "Choose a JSON file to review. No places are added until you confirm in Still."
        panel.allowedContentTypes = [.json]
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: window) { response in
            completionHandler(response == .OK ? panel.urls : nil)
        }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { result in completionHandler(result == .alertFirstButtonReturn) }
    }

    @objc func fullscreen(_ sender: Any?) { window.toggleFullScreen(sender) }
    @objc func newWriting(_ sender: Any?) {
        navigate(to: "/?new=1")
    }
    @objc func findWriting(_ sender: Any?) {
        navigate(to: "/pages")
    }

    @objc func openWriting(_ sender: Any?) {
        navigate(to: "/writing")
    }
    @objc func saveWriting(_ sender: Any?) {
        guard !quitting, let webView else { return }
        webView.evaluateJavaScript("window.dispatchEvent(new Event('still:save'))", completionHandler: nil)
    }

    private func reopeningURL(_ room: Backend) -> URL { room.url }

    private func navigate(to path: String) {
        guard !quitting, let room = backend else { return }
        Task {
            await prepareToLeave(wait: 200_000_000)
            guard await fileReadyForLeaving() else {
                showStorageNotice("The writing’s local recovery copy is unavailable. Save the writing or copy its words before leaving this page.")
                return
            }
            if !quitting {
                webView.load(URLRequest(url: URL(string: path, relativeTo: room.url)!.absoluteURL))
            }
        }
    }

    private func prepareToLeave(wait: UInt64) async {
        guard let webView else { return }
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            webView.evaluateJavaScript("window.dispatchEvent(new Event('still:prepare-to-leave'))") { _, _ in
                done.resume()
            }
        }
        try? await Task.sleep(nanoseconds: wait)
    }

    @objc func showWritingFolder(_ sender: Any?) {
        Task {
            do {
                guard let status = try await backend?.storageStatus(),
                      status.configured, let folder = status.folder else {
                    showStorageNotice("Choose a writing folder first.")
                    return
                }
                guard status.available else {
                    showStorageNotice(status.error ?? "The writing folder is unavailable.")
                    return
                }
                guard NSWorkspace.shared.open(URL(fileURLWithPath: folder, isDirectory: true)) else {
                    showStorageNotice("Still could not open the writing folder.")
                    return
                }
            } catch { showCloseError(error.localizedDescription) }
        }
    }

    @objc func openStorageSettings(_ sender: Any?) { navigate(to: "/storage") }

    @objc func clearWritingFolder(_ sender: Any?) { Task { await switchWritingFolder(to: nil) } }

    @objc func toggleBackupReminder(_ sender: NSMenuItem) {
        let enabled = !UserDefaults.standard.bool(forKey: "Still.backupReminderOnClose")
        UserDefaults.standard.set(enabled, forKey: "Still.backupReminderOnClose")
        sender.state = enabled ? .on : .off
    }

    @objc func backupNow(_ sender: Any?) {
        Task {
            guard !backingUp, !closeInProgress else { return }
            backingUp = true
            defer { backingUp = false }
            await setEditorFrozen(true)
            await prepareToLeave(wait: 900_000_000)
            guard await editorReadyForBackup() else {
                await setEditorFrozen(false)
                showCloseError("Some words are still waiting to be saved. Save or recover them before backing up.")
                return
            }
            do {
                guard let backend else { throw StillError.message("Still’s local room is not ready.") }
                let data = try await backend.storageRequest("POST", path: "/native/backup")
                let status = try JSONDecoder().decode(StorageStatus.self, from: data)
                await setEditorFrozen(false)
                showStorageNotice(status.changed
                    ? "A newer writing change arrived during the backup. Run Back Up Now again."
                    : "Backup completed.")
            } catch {
                await setEditorFrozen(false)
                showCloseError(error.localizedDescription)
            }
        }
    }

    private func showStorageNotice(_ message: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.beginSheetModal(for: window, completionHandler: nil)
    }

    @objc func chooseWritingFolder(_ sender: Any?) {
        guard !quitting, !openingRoom, !choosingFolder, !backingUp, !closeInProgress else { return }
        choosingFolder = true
        let panel = NSOpenPanel()
        panel.title = "Choose Still’s writing folder"
        panel.message = "Choose an existing local folder for ordinary text files. Still keeps its live database in local application data."
        panel.prompt = "Use This Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.directoryURL = backend?.dataDirectory
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            self.choosingFolder = false
            guard response == .OK, let directory = panel.url else { return }
            Task { await self.switchWritingFolder(to: directory) }
        }
    }

    private func switchWritingFolder(to directory: URL?) async {
        guard !choosingFolder, !openingRoom, !quitting else { return }
        choosingFolder = true
        defer { choosingFolder = false }
        await prepareToLeave(wait: 900_000_000)
        guard !quitting else { return }
        guard await fileReadyForLeaving() else {
            showStorageNotice("This writing has no safe recovery copy. Save it or copy its words before choosing another writing folder.")
            return
        }
        if let webView {
            let pending: Bool = await withCheckedContinuation { done in
                webView.evaluateJavaScript("""
                (() => { try { return Object.keys(localStorage).some(key => key.startsWith('still:draft:') || key.startsWith('still:poem-draft:')); }
                  catch (_) { return true; } })()
                """) { value, error in done.resume(returning: error != nil || (value as? Bool ?? true)) }
            }
            if pending {
                let alert = NSAlert()
                alert.messageText = "Some words are still waiting to be saved."
                alert.informativeText = "Save or recover them before choosing another writing folder."
                alert.beginSheetModal(for: window, completionHandler: nil)
                return
            }
        }
        do {
            guard let backend else { throw StillError.message("Still’s local room is not ready.") }
            if let directory {
                _ = try await backend.storageRequest("PUT", body: ["folder": directory.path])
            } else {
                _ = try await backend.storageRequest("DELETE")
            }
            let root = try await backend.storageStatus().folder
            let profile = root.map {
                WritingLocation.profile(for: URL(fileURLWithPath: $0, isDirectory: true))
            } ?? backend.profile
            webView = makeWebView(profile: profile)
            webView.load(URLRequest(url: reopeningURL(backend)))
        } catch {
            let alert = NSAlert()
            alert.messageText = "Still could not use that writing folder."
            alert.informativeText = error.localizedDescription
            alert.beginSheetModal(for: window, completionHandler: nil)
        }
    }

    private func showFailure(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Still could not open."
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "Choose Writing Folder…")
        alert.addButton(withTitle: "Close")
        alert.beginSheetModal(for: window) { [weak self] result in
            if result == .alertFirstButtonReturn { self?.chooseWritingFolder(nil) }
            else { NSApp.terminate(nil) }
        }
    }

    private func createMenu() {
        let bar = NSMenu()
        let appItem = NSMenuItem(title: "Still", action: nil, keyEquivalent: "")
        bar.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: "Hide Still", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Still", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let fileItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        bar.addItem(fileItem)
        let file = NSMenu(title: "File")
        fileItem.submenu = file
        let newPage = file.addItem(withTitle: "New Writing", action: #selector(newWriting(_:)), keyEquivalent: "n")
        newPage.target = self
        let open = file.addItem(withTitle: "Open Writing…", action: #selector(openWriting(_:)), keyEquivalent: "o")
        open.target = self
        let save = file.addItem(withTitle: "Save", action: #selector(saveWriting(_:)), keyEquivalent: "s")
        save.target = self
        let find = file.addItem(withTitle: "Find", action: #selector(findWriting(_:)), keyEquivalent: "k")
        find.target = self
        file.addItem(.separator())
        let choose = file.addItem(withTitle: "Choose Writing Folder…", action: #selector(chooseWritingFolder(_:)), keyEquivalent: "")
        choose.target = self
        let show = file.addItem(withTitle: "Show Writing Folder", action: #selector(showWritingFolder(_:)), keyEquivalent: "")
        show.target = self
        file.addItem(.separator())
        let storage = file.addItem(withTitle: "Storage & Backups…", action: #selector(openStorageSettings(_:)), keyEquivalent: "")
        storage.target = self
        let clearWriting = file.addItem(withTitle: "Clear Writing Folder", action: #selector(clearWritingFolder(_:)), keyEquivalent: "")
        clearWriting.target = self
        let backup = file.addItem(withTitle: "Back Up Now", action: #selector(backupNow(_:)), keyEquivalent: "")
        backup.target = self
        let reminder = file.addItem(withTitle: "Remind Me to Back Up on Close", action: #selector(toggleBackupReminder(_:)), keyEquivalent: "")
        reminder.target = self
        reminder.state = UserDefaults.standard.bool(forKey: "Still.backupReminderOnClose") ? .on : .off
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        bar.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        editItem.submenu = edit
        for (title, action, key) in [("Undo", "undo:", "z"), ("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            edit.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
        }
        let redo = NSMenuItem(title: "Redo", action: NSSelectorFromString("redo:"), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.insertItem(redo, at: 1)
        edit.addItem(.separator())
        let spellingItem = edit.addItem(withTitle: "Spelling", action: nil, keyEquivalent: "")
        let spelling = NSMenu(title: "Spelling")
        spellingItem.submenu = spelling
        // Standard responder-chain actions let WebKit own the selected word,
        // suggestions, document ignores, and the Mac's learned dictionary.
        spelling.addItem(withTitle: "Show Spelling…", action: #selector(NSTextView.showGuessPanel(_:)), keyEquivalent: "")
        spelling.addItem(withTitle: "Check Spelling", action: #selector(NSTextView.checkSpelling(_:)), keyEquivalent: ";")
        spelling.addItem(.separator())
        spelling.addItem(withTitle: "Check Spelling While Typing", action: #selector(NSTextView.toggleContinuousSpellChecking(_:)), keyEquivalent: "")
        let viewItem = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        bar.addItem(viewItem)
        let view = NSMenu(title: "Window")
        viewItem.submenu = view
        view.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        view.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        let full = view.addItem(withTitle: "Enter Full Screen", action: #selector(fullscreen(_:)), keyEquivalent: "f")
        full.keyEquivalentModifierMask = [.command, .control]
        full.target = self
        NSApp.mainMenu = bar
        NSApp.windowsMenu = view
    }
}

@main
struct StillMain {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--check-backend") {
            Task {
                var room: Backend?
                do {
                    room = try Backend()
                    try room!.start()
                    try await room!.ready()
                    print("Still backend ready at localhost:\(room!.port)")
                    await room!.stop()
                    exit(0)
                } catch {
                    fputs("\(error.localizedDescription)\n", stderr)
                    await room?.stop()
                    exit(1)
                }
            }
            dispatchMain()
        }
        // WebKit reads these app-scoped defaults when its text checker starts.
        // Register defaults so later choices in its native menu are remembered;
        // never change the user's global macOS spelling or grammar preferences.
        UserDefaults.standard.register(defaults: [
            "WebContinuousSpellCheckingEnabled": true,
            "WebGrammarCheckingEnabled": false,
            "WebAutomaticSpellingCorrectionEnabled": false,
        ])
        let application = NSApplication.shared
        let delegate = StillApplication()
        application.setActivationPolicy(.regular)
        application.delegate = delegate
        application.run()
    }
}
