import AppKit
import WebKit
import Security
import CryptoKit
import Darwin

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

    init(directory: URL? = nil) throws {
        let env = ProcessInfo.processInfo.environment
        guard let resources = Bundle.main.resourceURL,
              let executable = Bundle.main.executableURL
        else { throw StillError.message("Still could not find its local room.") }
        let defaults = UserDefaults.standard
        let explicit = directory?.path ?? env["STILL_DATA_DIRECTORY"]
        let fallback = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Still/Writing", isDirectory: true)
        let legacy = Bundle.main.object(forInfoDictionaryKey: "StillLegacyDataDirectory") as? String ??
            Bundle.main.object(forInfoDictionaryKey: "StillDataDirectory") as? String
        dataDirectory = try WritingLocation.resolve(override: explicit,
            bookmark: defaults.data(forKey: WritingLocation.bookmarkKey), legacyPath: legacy, fallback: fallback)
        let rememberedProfile = explicit == nil && defaults.data(forKey: WritingLocation.bookmarkKey) != nil
            ? defaults.string(forKey: WritingLocation.profileKey) : nil
        profile = WritingLocation.profile(for: dataDirectory, remembered: rememberedProfile)
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

    private func openRoom(directory: URL? = nil) async throws {
        openingRoom = true
        defer { openingRoom = false }
        let room = try Backend(directory: directory)
        do {
            try room.start()
            try await room.ready()
            if directory != nil || ProcessInfo.processInfo.environment["STILL_DATA_DIRECTORY"] == nil {
                let bookmark = try WritingLocation.bookmark(for: room.dataDirectory)
                UserDefaults.standard.set(bookmark, forKey: WritingLocation.bookmarkKey)
                UserDefaults.standard.set(room.profile.uuidString, forKey: WritingLocation.profileKey)
            }
        } catch {
            await room.stop()
            throw error
        }
        backend = room
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: room.profile)
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.underPageBackgroundColor = window.backgroundColor
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsMagnification = false
        webView.allowsLinkPreview = false
        webView.navigationDelegate = self
        webView.uiDelegate = self
        window.contentView = webView
        webView.load(URLRequest(url: reopeningURL(room)))
        room.process?.terminationHandler = { [weak self, weak room] _ in
            Task { @MainActor in
                if let self, let room, self.backend === room, !self.quitting {
                    self.showFailure(StillError.message("The local room closed unexpectedly. Unsent words remain in this app. Close and reopen Still."))
                }
            }
        }
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
                let editorReady = await editorReadyForBackup()
                let status = try? await backend?.storageStatus()
                if status?.changed != false || !editorReady {
                    let choice = await askCloseChoice(hasFolder: status?.configured == true && status?.available == true)
                    switch ClosePolicy.resolve(changed: status?.changed != false, editorReady: editorReady, choice: choice,
                                                hasBackupFolder: status?.configured == true && status?.available == true) {
                    case .cancel: cancelClose(); return
                    case .close: await finishClose(); return
                    case .backUp: break
                    case .chooseBackupFolder:
                        showCloseError("Choose a backup folder from File → Choose Backup Folder… before backing up and closing.")
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
                : "Your collection has changed and has no available backup folder. You can close now and choose a folder later."
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
        if item.action == #selector(chooseWritingFolder(_:)) { return !quitting && !openingRoom && !choosingFolder }
        if item.action == #selector(chooseBackupFolder(_:)) || item.action == #selector(clearBackupFolder(_:)) ||
            item.action == #selector(backupNow(_:)) || item.action == #selector(showBackupFolder(_:)) {
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
          if (editor && document.activeElement !== editor) editor.focus({preventScroll: true}); })()
        """, completionHandler: nil)
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
        if let directory = backend?.dataDirectory { NSWorkspace.shared.open(directory) }
    }

    @objc func openStorageSettings(_ sender: Any?) { navigate(to: "/storage") }

    @objc func chooseBackupFolder(_ sender: Any?) {
        guard !quitting, !closeInProgress, !choosingFolder else { return }
        choosingFolder = true
        let panel = NSOpenPanel()
        panel.title = "Choose Still’s backup folder"
        panel.message = "Choose a separate synchronized folder for verified backups of this collection."
        panel.prompt = "Use This Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            self.choosingFolder = false
            guard response == .OK, let folder = panel.url else { return }
            Task { await self.updateBackupFolder(folder.path) }
        }
    }

    @objc func clearBackupFolder(_ sender: Any?) { Task { await updateBackupFolder(nil) } }

    private func updateBackupFolder(_ folder: String?) async {
        guard !backingUp, !closeInProgress, let backend else { return }
        do {
            if let folder { _ = try await backend.storageRequest("PUT", body: ["folder": folder]) }
            else { _ = try await backend.storageRequest("DELETE") }
            showStorageNotice(folder == nil
                ? "Backup folder cleared. Existing backups are unchanged."
                : "Backup folder updated.")
        } catch { showCloseError(error.localizedDescription) }
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

    @objc func showBackupFolder(_ sender: Any?) {
        Task {
            do {
                guard let status = try await backend?.storageStatus(),
                      status.configured, let folder = status.folder else {
                    showStorageNotice("Choose a backup folder first.")
                    return
                }
                guard status.available else {
                    showStorageNotice(status.error ?? "The backup folder is unavailable.")
                    return
                }
                guard NSWorkspace.shared.open(URL(fileURLWithPath: folder, isDirectory: true)) else {
                    showStorageNotice("Still could not open the backup folder.")
                    return
                }
            } catch { showCloseError(error.localizedDescription) }
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
        panel.message = "Choose the folder containing still.db, or an empty folder for a new collection. Existing writing stays in its current folder."
        panel.prompt = "Use This Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = backend?.dataDirectory
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            self.choosingFolder = false
            guard response == .OK, let directory = panel.url else { return }
            if directory.resolvingSymlinksInPath().path == self.backend?.dataDirectory.resolvingSymlinksInPath().path { return }
            if !FileManager.default.fileExists(atPath: directory.appendingPathComponent("still.db").path) {
                let confirmation = NSAlert()
                confirmation.messageText = "Open an empty collection here?"
                confirmation.informativeText = "This folder has no Still database. Your existing writing stays in its current folder. Choose that folder again to return to it."
                confirmation.addButton(withTitle: "Open Empty Collection")
                confirmation.addButton(withTitle: "Cancel")
                confirmation.beginSheetModal(for: self.window) { result in
                    if result == .alertFirstButtonReturn { Task { await self.switchWritingFolder(to: directory) } }
                }
            } else { Task { await self.switchWritingFolder(to: directory) } }
        }
    }

    private func switchWritingFolder(to directory: URL) async {
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
                alert.informativeText = "Save or recover them in this collection before choosing another writing folder."
                alert.beginSheetModal(for: window, completionHandler: nil)
                return
            }
        }
        let previous = backend?.dataDirectory
        let previousRoom = backend
        backend = nil
        await previousRoom?.stop()
        do { try await openRoom(directory: directory) }
        catch {
            if let previous {
                do { try await openRoom(directory: previous) }
                catch { showFailure(error); return }
            }
            let alert = NSAlert()
            alert.messageText = "Still could not open that folder."
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
        let chooseBackup = file.addItem(withTitle: "Choose Backup Folder…", action: #selector(chooseBackupFolder(_:)), keyEquivalent: "")
        chooseBackup.target = self
        let clearBackup = file.addItem(withTitle: "Clear Backup Folder", action: #selector(clearBackupFolder(_:)), keyEquivalent: "")
        clearBackup.target = self
        let backup = file.addItem(withTitle: "Back Up Now", action: #selector(backupNow(_:)), keyEquivalent: "")
        backup.target = self
        let showBackup = file.addItem(withTitle: "Show Backup Folder", action: #selector(showBackupFolder(_:)), keyEquivalent: "")
        showBackup.target = self
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
        let application = NSApplication.shared
        let delegate = StillApplication()
        application.setActivationPolicy(.regular)
        application.delegate = delegate
        application.run()
    }
}
