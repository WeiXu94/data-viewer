import AppKit

final class MainWindowController: NSWindowController {
    private let tableViewController = TableViewController()

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "DataViewer"
        window.contentMinSize = NSSize(width: 760, height: 480)
        window.sharingType = .readWrite
        // Use contentView, not contentViewController: the latter continuously
        // auto-sizes the window to the content's minimum fitting size in both
        // axes. With contentView the frame's height is honored; the width still
        // follows the content's minimum (the table's minimum width, ~1001pt).
        let content = tableViewController.view
        content.translatesAutoresizingMaskIntoConstraints = true
        content.frame = NSRect(x: 0, y: 0, width: 1120, height: 720)
        content.autoresizingMask = [.width, .height]
        window.contentView = content
        window.center()

        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        nil
    }

    func open(url: URL) {
        do {
            try tableViewController.open(url: url)
            window?.title = url.lastPathComponent
        } catch {
            let alert = NSAlert(error: error)
            alert.beginSheetModal(for: window ?? NSWindow())
        }
    }
}
