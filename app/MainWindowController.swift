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
        window.title = "DtaViewer"
        window.center()
        window.contentMinSize = NSSize(width: 760, height: 480)
        window.sharingType = .readWrite
        window.contentViewController = tableViewController

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
