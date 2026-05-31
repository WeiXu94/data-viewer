import AppKit
import DtaCore

final class TableViewController: NSViewController {
    private let gridView = DataGridView()
    private let gridHeader = DataGridHeaderView()
    private let gridScrollView = NSScrollView()
    private let variableSidebarView = VariableSidebarView()
    private let statusLabel = NSTextField(labelWithString: "Open a .dta file")
    private var document: DtaDocument?

    override func loadView() {
        // A fixed-width sidebar beside a flexible table area, with a status bar
        // along the bottom. Raw NSSplitView lays its panes out by frame and
        // ignores Auto Layout width constraints, so it is built directly here.
        let sidebar = buildSidebar()
        let tableArea = buildTableArea()

        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let statusBar = NSView()
        statusBar.translatesAutoresizingMaskIntoConstraints = false
        statusBar.wantsLayer = true
        statusBar.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        statusBar.addSubview(statusLabel)

        let container = NSView()
        container.addSubview(tableArea)
        container.addSubview(sidebar)
        container.addSubview(divider)
        container.addSubview(statusBar)
        view = container

        NSLayoutConstraint.activate([
            statusBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: 32),

            sidebar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: container.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 240),

            divider.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),
            divider.topAnchor.constraint(equalTo: container.topAnchor),
            divider.bottomAnchor.constraint(equalTo: statusBar.topAnchor),

            tableArea.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            tableArea.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            tableArea.topAnchor.constraint(equalTo: container.topAnchor),
            tableArea.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
            // AppKit sizes the window's width to the content's required minimum,
            // so this minimum is effectively the opening width of the table pane
            // (and the window). Without it the pane collapses to zero.
            tableArea.widthAnchor.constraint(greaterThanOrEqualToConstant: 760),

            statusLabel.leadingAnchor.constraint(equalTo: statusBar.leadingAnchor, constant: 20),
            statusLabel.trailingAnchor.constraint(equalTo: statusBar.trailingAnchor, constant: -20),
            statusLabel.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor)
        ])
    }

    func open(url: URL) throws {
        let opened = try DtaDocument(url: url)
        document = opened
        gridView.load(document: opened)
        gridScrollView.contentView.scroll(to: .zero)
        gridScrollView.reflectScrolledClipView(gridScrollView.contentView)
        gridHeader.xOffset = 0
        gridHeader.needsDisplay = true
        variableSidebarView.load(columns: opened.columns)
        let status = statusText(for: opened)
        statusLabel.stringValue = status
        statusLabel.toolTip = status
    }

    @objc private func gridDidScroll(_ notification: Notification) {
        gridHeader.xOffset = gridScrollView.contentView.bounds.origin.x
    }

    private func buildSidebar() -> NSView {
        variableSidebarView.translatesAutoresizingMaskIntoConstraints = false
        return variableSidebarView
    }

    private func buildTableArea() -> NSView {
        gridScrollView.documentView = gridView
        gridScrollView.hasVerticalScroller = true
        gridScrollView.hasHorizontalScroller = true
        gridScrollView.autohidesScrollers = false
        gridScrollView.borderType = .noBorder
        gridScrollView.drawsBackground = true
        gridScrollView.translatesAutoresizingMaskIntoConstraints = false

        gridHeader.grid = gridView
        gridHeader.translatesAutoresizingMaskIntoConstraints = false

        // Keep the header in sync with horizontal scrolling.
        let clip = gridScrollView.contentView
        clip.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(gridDidScroll(_:)),
            name: NSView.boundsDidChangeNotification, object: clip)

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(gridHeader)
        container.addSubview(gridScrollView)

        NSLayoutConstraint.activate([
            gridHeader.topAnchor.constraint(equalTo: container.topAnchor),
            gridHeader.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            gridHeader.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            gridHeader.heightAnchor.constraint(equalToConstant: gridView.rowHeight),

            gridScrollView.topAnchor.constraint(equalTo: gridHeader.bottomAnchor),
            gridScrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            gridScrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            gridScrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        return container
    }

    private func statusText(for document: DtaDocument) -> String {
        let obs = Self.countFormatter.string(from: NSNumber(value: document.rowCount)) ?? "\(document.rowCount)"
        let vars = Self.countFormatter.string(from: NSNumber(value: document.columns.count)) ?? "\(document.columns.count)"
        let label = document.datasetLabel.isEmpty ? "" : " — \(document.datasetLabel)"
        return "\(obs) obs × \(vars) vars\(label)"
    }

    private static let countFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()
}

final class VariableSidebarView: NSView {
    private struct Row {
        let text: String
    }

    private var rows: [Row] = []
    private let rowHeight: CGFloat = 24
    private let horizontalInset: CGFloat = 20
    private let titleTopInset: CGFloat = 10
    private let titleHeight: CGFloat = 18
    private let rowTopInset: CGFloat = 36
    private var scrollOffset: CGFloat = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    convenience init() {
        self.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }

    private lazy var titleAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
        .foregroundColor: NSColor.labelColor
    ]

    private lazy var attributes: [NSAttributedString.Key: Any] = {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        return [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: style
        ]
    }()

    func load(columns: [DtaColumnInfo]) {
        scrollOffset = 0
        rows = columns.map { column in
            if column.label.isEmpty {
                return Row(text: column.name)
            }
            return Row(text: "\(column.name) - \(column.label)")
        }

        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(rect: bounds).setClip()

        NSColor.controlBackgroundColor.setFill()
        bounds.fill()

        let titleRect = NSRect(
            x: horizontalInset,
            y: titleTopInset,
            width: max(0, bounds.width - horizontalInset * 2),
            height: titleHeight
        )
        ("Variables" as NSString).draw(in: titleRect, withAttributes: titleAttributes)

        guard !rows.isEmpty else { return }

        let visibleTop = max(0, dirtyRect.minY - rowTopInset + scrollOffset)
        let visibleBottom = max(0, dirtyRect.maxY - rowTopInset + scrollOffset)
        let firstRow = max(0, Int((visibleTop / rowHeight).rounded(.down)))
        let lastRow = min(rows.count - 1, Int((visibleBottom / rowHeight).rounded(.up)))
        guard firstRow <= lastRow else { return }

        if let alt = NSColor.alternatingContentBackgroundColors.dropFirst().first {
            alt.withAlphaComponent(0.45).setFill()
            for row in firstRow...lastRow where row % 2 == 1 {
                NSRect(x: 0,
                       y: rowTopInset + CGFloat(row) * rowHeight - scrollOffset,
                       width: bounds.width, height: rowHeight).fill()
            }
        }

        let lineHeight = NSFont.systemFont(ofSize: 12).boundingRectForFont.height
        let textYInset = ((rowHeight - lineHeight) / 2).rounded()
        for row in firstRow...lastRow {
            let rect = NSRect(
                x: horizontalInset,
                y: rowTopInset + CGFloat(row) * rowHeight - scrollOffset + textYInset,
                width: max(0, bounds.width - horizontalInset * 2),
                height: lineHeight
            )
            (rows[row].text as NSString).draw(in: rect, withAttributes: attributes)
        }

        drawScrollThumb()
    }

    override func scrollWheel(with event: NSEvent) {
        let delta = event.scrollingDeltaY == 0 ? event.deltaY * 10 : event.scrollingDeltaY
        setScrollOffset(scrollOffset + delta)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        setScrollOffset(scrollOffset)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    private var maxScrollOffset: CGFloat {
        max(0, CGFloat(rows.count) * rowHeight - max(0, bounds.height - rowTopInset))
    }

    private func setScrollOffset(_ offset: CGFloat) {
        let clamped = min(max(0, offset), maxScrollOffset)
        if clamped != scrollOffset {
            scrollOffset = clamped
            needsDisplay = true
        }
    }

    private func drawScrollThumb() {
        let contentHeight = CGFloat(rows.count) * rowHeight
        let viewportHeight = max(1, bounds.height - rowTopInset)
        guard contentHeight > viewportHeight else { return }

        let trackHeight = viewportHeight
        let thumbHeight = max(24, trackHeight * viewportHeight / contentHeight)
        let travel = max(1, trackHeight - thumbHeight)
        let thumbY = rowTopInset + travel * (scrollOffset / maxScrollOffset)
        let thumbRect = NSRect(x: bounds.width - 8, y: thumbY, width: 4, height: thumbHeight)
        NSColor.tertiaryLabelColor.setFill()
        NSBezierPath(roundedRect: thumbRect, xRadius: 2, yRadius: 2).fill()
    }
}
