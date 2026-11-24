import AppKit
import Foundation

@MainActor
final class NextMenuController: NSObject, NSMenuDelegate {
    struct TaskItem: Decodable {
        let id: String
        let title: String
    }

    private struct Response: Decodable {
        let tasks: [TaskItem]
        let available: Bool
    }

    private let fetch: () async throws -> Data
    private let openNext: () -> Void
    private let openTask: (String) -> Void
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private var loading = false

    init(fetch: @escaping () async throws -> Data,
         openNext: @escaping () -> Void,
         openTask: @escaping (String) -> Void) {
        self.fetch = fetch
        self.openNext = openNext
        self.openTask = openTask
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        if let button = statusItem.button {
            button.title = "Next"
            button.image = NSImage(systemSymbolName: "checklist", accessibilityDescription: "Still Next")
            button.imagePosition = .imageLeading
            button.toolTip = "Still Next"
            button.setAccessibilityLabel("Still Next")
        }
        menu.delegate = self
        statusItem.menu = menu
        statusItem.isVisible = false
        render(message: "Open Still Next to load today’s tasks.", tasks: [])
    }

    var isVisible: Bool {
        get { statusItem.isVisible }
        set { statusItem.isVisible = newValue }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard !loading else { return }
        loading = true
        render(message: "Loading today’s tasks…", tasks: [])
        Task {
            defer { loading = false }
            do {
                let response = try JSONDecoder().decode(Response.self, from: await fetch())
                guard response.available else {
                    render(message: "Today’s tasks are unavailable.", tasks: [])
                    return
                }
                render(message: response.tasks.isEmpty ? "No tasks for today." : nil,
                       tasks: Array(response.tasks.prefix(5)))
            } catch {
                render(message: "Could not load today’s tasks. Open Next in Still to retry.", tasks: [])
            }
        }
    }

    private func render(message: String?, tasks: [TaskItem]) {
        menu.removeAllItems()
        if let message { menu.addItem(NSMenuItem(title: message, action: nil, keyEquivalent: "")) }
        for task in tasks {
            let item = NSMenuItem(title: task.title, action: #selector(selectTask(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = task.id
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let open = NSMenuItem(title: "Open Next", action: #selector(selectNext), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
    }

    @objc private func selectNext() { openNext() }

    @objc private func selectTask(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        openTask(id)
    }
}
