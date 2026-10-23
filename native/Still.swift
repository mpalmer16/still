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
}

@MainActor
final class StillApplication: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation, WKNavigationDelegate, WKUIDelegate {
    var window: NSWindow!
    var webView: WKWebView!
    var backend: Backend?
    private var openingRoom = false
    private var choosingFolder = false
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
        quitting = true
        // Flush through the editor's recovery hook before stopping its local
        // backend. A still-new draft leaves a local path cursor for reopening.
        Task {
            await prepareToLeave(wait: 900_000_000)
            await backend?.stop()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
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
        if item.action == #selector(chooseWritingFolder(_:)) { return !quitting && !openingRoom && !choosingFolder }
        if item.action == #selector(fullscreen(_:)) {
            item.title = window?.styleMask.contains(.fullScreen) == true ? "Exit Full Screen" : "Enter Full Screen"
        }
        return true
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let address = navigationAction.request.url, let room = backend,
              address.scheme == "http", ["localhost", "127.0.0.1"].contains(address.host ?? ""),
              address.port == room.port else { decisionHandler(.cancel); return }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        updateRoomEnvironment()
        window.makeFirstResponder(webView)
        webView.evaluateJavaScript("""
        (() => { const editor = document.getElementById('writing-body');
          if (editor && document.activeElement !== editor) editor.focus({preventScroll: true}); })()
        """, completionHandler: nil)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
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
        navigate(to: "/pages?written=1")
    }
    @objc func saveWriting(_ sender: Any?) {
        guard !quitting, let webView else { return }
        webView.evaluateJavaScript("window.dispatchEvent(new Event('still:save'))", completionHandler: nil)
    }

    private var pendingCursorKey: String {
        "Still.pendingNew." + (backend?.profile.uuidString ?? "")
    }

    private func reopeningURL(_ room: Backend) -> URL {
        let legacyKey = "Still.pendingNew." + room.dataDirectory.resolvingSymlinksInPath().path
        if let path = UserDefaults.standard.string(forKey: pendingCursorKey) ?? UserDefaults.standard.string(forKey: legacyKey),
           path.range(of: #"^/(\?new=1|\?beside=[0-9]+|list\?resume=1|list\?beside=[0-9]+&resume=1)$"#, options: .regularExpression) != nil {
            return URL(string: path, relativeTo: room.url)!.absoluteURL
        }
        return room.url
    }

    private func navigate(to path: String) {
        guard !quitting, let room = backend else { return }
        Task {
            await prepareToLeave(wait: 200_000_000)
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
        let script = """
        (() => { const editor = document.getElementById('writing-body');
          return editor ? {editor: true, id: editor.dataset.entryId,
            scope: editor.dataset.draftScope || '', hasWords: editor.value.trim().length > 0 ||
              (document.getElementById('writing-title')?.value.trim().length || 0) > 0}
            : {editor: false}; })()
        """
        let state: [String: Any]? = await withCheckedContinuation { done in
            webView.evaluateJavaScript(script) { value, _ in done.resume(returning: value as? [String: Any]) }
        }
        guard let state else { return }
        if let room = backend {
            UserDefaults.standard.removeObject(forKey: "Still.pendingNew." + room.dataDirectory.resolvingSymlinksInPath().path)
        }
        guard state["editor"] as? Bool == true else {
            UserDefaults.standard.removeObject(forKey: pendingCursorKey)
            return
        }
        if state["id"] as? String == "new" {
            if state["hasWords"] as? Bool == true {
                let scope = state["scope"] as? String ?? ""
                let path: String
                if scope == "list" {
                    path = "/list?resume=1"
                } else if scope.hasPrefix("list:beside:"), let id = Int(scope.dropFirst(12)), id > 0 {
                    path = "/list?beside=\(id)&resume=1"
                } else if scope.hasPrefix("beside:"), let id = Int(scope.dropFirst(7)), id > 0 {
                    path = "/?beside=\(id)"
                } else if let id = Int(scope), id > 0 {
                    path = "/?beside=\(id)"
                } else {
                    path = "/?new=1"
                }
                UserDefaults.standard.set(path, forKey: pendingCursorKey)
            } else {
                UserDefaults.standard.removeObject(forKey: pendingCursorKey)
            }
        } else {
            UserDefaults.standard.removeObject(forKey: pendingCursorKey)
        }
    }

    @objc func showWritingFolder(_ sender: Any?) {
        if let directory = backend?.dataDirectory { NSWorkspace.shared.open(directory) }
    }

    @objc func chooseWritingFolder(_ sender: Any?) {
        guard !quitting, !openingRoom, !choosingFolder else { return }
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
        if let webView {
            let pending: Bool = await withCheckedContinuation { done in
                webView.evaluateJavaScript("""
                (() => { try { return Object.keys(localStorage).some(key => key.startsWith('still:draft:')); }
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
