import AppKit
import DataCore

final class TableViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let gridView = DataGridView()
    private let gridHeader = DataGridHeaderView()
    private let gridScrollView = NSScrollView()
    private let variablesTableView = NSTableView()
    private let sidebarTitle = NSTextField(labelWithString: "Variables")
    private let statusLabel = NSTextField(labelWithString: "Open a .dta, .rds, or .mat file")
    private var document: DataDocument?

    private static let variableFont = NSFont.systemFont(ofSize: 12)

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
        let opened = try DataDocument(url: url)
        document = opened
        gridView.load(document: opened)
        gridScrollView.contentView.scroll(to: .zero)
        gridScrollView.reflectScrolledClipView(gridScrollView.contentView)
        gridHeader.xOffset = 0
        gridHeader.needsDisplay = true
        variablesTableView.reloadData()
        let status = statusText(for: opened)
        statusLabel.stringValue = status
        statusLabel.toolTip = status
    }

    @objc private func gridDidScroll(_ notification: Notification) {
        gridHeader.xOffset = gridScrollView.contentView.bounds.origin.x
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        document?.columns.count ?? 0
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        variableCell(row: row)
    }

    private func buildSidebar() -> NSView {
        let sidebar = NSView()
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        sidebar.wantsLayer = true
        sidebar.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

        sidebarTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        sidebarTitle.translatesAutoresizingMaskIntoConstraints = false

        variablesTableView.headerView = nil
        variablesTableView.dataSource = self
        variablesTableView.delegate = self
        variablesTableView.rowSizeStyle = .custom
        variablesTableView.rowHeight = 24
        variablesTableView.usesAutomaticRowHeights = false
        variablesTableView.selectionHighlightStyle = .regular
        variablesTableView.backgroundColor = .controlBackgroundColor
        variablesTableView.intercellSpacing = NSSize(width: 0, height: 0)
        variablesTableView.autoresizingMask = [.width]

        let variableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("variable"))
        variableColumn.width = 220
        variableColumn.minWidth = 80
        variableColumn.resizingMask = [.autoresizingMask]
        variablesTableView.addTableColumn(variableColumn)

        let scrollView = NSScrollView()
        scrollView.documentView = variablesTableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .controlBackgroundColor
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        sidebar.addSubview(sidebarTitle)
        sidebar.addSubview(scrollView)

        NSLayoutConstraint.activate([
            sidebarTitle.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 20),
            sidebarTitle.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -12),
            sidebarTitle.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 10),

            scrollView.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: sidebarTitle.bottomAnchor, constant: 8),
            scrollView.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor)
        ])

        return sidebar
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

    private func statusText(for document: DataDocument) -> String {
        let obs = Self.countFormatter.string(from: NSNumber(value: document.rowCount)) ?? "\(document.rowCount)"
        let vars = Self.countFormatter.string(from: NSNumber(value: document.columns.count)) ?? "\(document.columns.count)"
        let label = document.datasetLabel.isEmpty ? "" : " — \(document.datasetLabel)"
        return "\(obs) obs × \(vars) vars\(label)"
    }

    private func variableCell(row: Int) -> NSView? {
        guard let document, row < document.columns.count else {
            return nil
        }

        let identifier = NSUserInterfaceItemIdentifier("VariableCell")
        let cellView: NSTableCellView
        if let recycled = variablesTableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView {
            cellView = recycled
        } else {
            cellView = NSTableCellView()
            cellView.identifier = identifier

            let field = NSTextField(labelWithString: "")
            field.translatesAutoresizingMaskIntoConstraints = false
            field.font = Self.variableFont
            field.lineBreakMode = .byTruncatingTail
            field.maximumNumberOfLines = 1
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

            cellView.addSubview(field)
            cellView.textField = field

            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: cellView.leadingAnchor, constant: 20),
                field.trailingAnchor.constraint(equalTo: cellView.trailingAnchor, constant: -8),
                field.centerYAnchor.constraint(equalTo: cellView.centerYAnchor)
            ])
        }

        let column = document.columns[row]
        let text = column.label.isEmpty ? column.name : "\(column.name) - \(column.label)"
        cellView.textField?.stringValue = text
        cellView.textField?.toolTip = text
        return cellView
    }

    private static let countFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()
}
