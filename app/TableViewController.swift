import AppKit
import DtaCore

final class TableViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let splitView = NSSplitView()
    private let tableView = NSTableView()
    private let variablesTableView = NSTableView()
    private let statusLabel = NSTextField(labelWithString: "Open a .dta file")
    private let sidebarTitle = NSTextField(labelWithString: "Variables")
    private var document: DtaDocument?

    override func loadView() {
        let root = NSStackView()
        root.orientation = .vertical
        root.spacing = 0
        root.translatesAutoresizingMaskIntoConstraints = false

        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.translatesAutoresizingMaskIntoConstraints = false

        let sidebar = buildSidebar()
        let tableArea = buildTableArea()
        splitView.addArrangedSubview(sidebar)
        splitView.addArrangedSubview(tableArea)

        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingMiddle
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let statusBar = NSView()
        statusBar.translatesAutoresizingMaskIntoConstraints = false
        statusBar.addSubview(statusLabel)

        root.addArrangedSubview(splitView)
        root.addArrangedSubview(statusBar)

        view = NSView()
        view.addSubview(root)

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            root.topAnchor.constraint(equalTo: view.topAnchor),
            root.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 240),
            statusBar.heightAnchor.constraint(equalToConstant: 28),
            statusLabel.leadingAnchor.constraint(equalTo: statusBar.leadingAnchor, constant: 12),
            statusLabel.trailingAnchor.constraint(equalTo: statusBar.trailingAnchor, constant: -12),
            statusLabel.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor)
        ])
    }

    func open(url: URL) throws {
        let opened = try DtaDocument(url: url)
        document = opened
        configureColumns(for: opened)
        tableView.reloadData()
        variablesTableView.reloadData()
        statusLabel.stringValue = statusText(for: opened)
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        guard let document else {
            return 0
        }
        if tableView === variablesTableView {
            return document.columns.count
        }
        if document.rowCount > Int64(Int.max) {
            return Int.max
        }
        return Int(document.rowCount)
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableView === variablesTableView {
            return variableCell(row: row)
        }
        return dataCell(tableColumn: tableColumn, row: row)
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        24
    }

    private func buildSidebar() -> NSView {
        let sidebar = NSView()
        sidebar.translatesAutoresizingMaskIntoConstraints = false

        sidebarTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        sidebarTitle.translatesAutoresizingMaskIntoConstraints = false

        variablesTableView.headerView = nil
        variablesTableView.dataSource = self
        variablesTableView.delegate = self
        variablesTableView.rowSizeStyle = .small
        variablesTableView.selectionHighlightStyle = .regular
        variablesTableView.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("variable")))

        let scrollView = NSScrollView()
        scrollView.documentView = variablesTableView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        sidebar.addSubview(sidebarTitle)
        sidebar.addSubview(scrollView)

        NSLayoutConstraint.activate([
            sidebarTitle.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 12),
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
        tableView.dataSource = self
        tableView.delegate = self
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.gridStyleMask = [.solidHorizontalGridLineMask, .solidVerticalGridLineMask]
        tableView.columnAutoresizingStyle = .sequentialColumnAutoresizingStyle
        tableView.rowSizeStyle = .small

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = false
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        return scrollView
    }

    private func configureColumns(for document: DtaDocument) {
        for column in tableView.tableColumns {
            tableView.removeTableColumn(column)
        }

        for columnInfo in document.columns {
            let identifier = NSUserInterfaceItemIdentifier(String(columnInfo.index))
            let column = NSTableColumn(identifier: identifier)
            column.title = columnInfo.name
            column.minWidth = 70
            column.width = max(90, min(240, CGFloat(columnInfo.name.count * 9 + 36)))
            column.resizingMask = [.userResizingMask, .autoresizingMask]
            tableView.addTableColumn(column)
        }
    }

    private func variableCell(row: Int) -> NSView? {
        guard let document, row < document.columns.count else {
            return nil
        }

        let identifier = NSUserInterfaceItemIdentifier("VariableCell")
        let cell = variablesTableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
            ?? makeTextCell(identifier: identifier)

        let column = document.columns[row]
        if column.label.isEmpty {
            cell.textField?.stringValue = column.name
        } else {
            cell.textField?.stringValue = "\(column.name) - \(column.label)"
        }
        cell.textField?.alignment = .left
        cell.textField?.font = .systemFont(ofSize: 12)
        return cell
    }

    private func dataCell(tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let document,
              let tableColumn,
              let columnIndex = Int(tableColumn.identifier.rawValue),
              columnIndex < document.columns.count
        else {
            return nil
        }

        let identifier = NSUserInterfaceItemIdentifier("DataCell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
            ?? makeTextCell(identifier: identifier)

        cell.textField?.stringValue = document.cell(row: row, column: columnIndex) ?? ""
        cell.textField?.alignment = document.columns[columnIndex].type == DTA_NUMERIC ? .right : .left
        cell.textField?.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        return cell
    }

    private func makeTextCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier

        let textField = NSTextField(labelWithString: "")
        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.lineBreakMode = .byTruncatingTail
        textField.maximumNumberOfLines = 1
        textField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        cell.addSubview(textField)
        cell.textField = textField

        NSLayoutConstraint.activate([
            textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
            textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
            textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])

        return cell
    }

    private func statusText(for document: DtaDocument) -> String {
        let label = document.datasetLabel.isEmpty ? "" : " - \(document.datasetLabel)"
        return "\(document.url.lastPathComponent): \(document.rowCount) obs x \(document.columns.count) vars\(label) - \(document.cacheStatsSummary())"
    }
}
