import AppKit
import DataCore

/// Geometry + type for one grid column.
private struct GridColumn {
    let index: Int
    let title: String
    let isNumeric: Bool
    let width: CGFloat
    let x: CGFloat        // left edge in content coordinates
}

/// A custom-drawn data grid. Instead of instantiating one `NSView` per visible
/// cell (view-based `NSTableView`), it paints only the cells intersecting the
/// dirty rect straight from the in-memory cache. This is the approach the
/// Stata/Excel/Numbers grids use, and it stays smooth with hundreds of columns.
final class DataGridView: NSView {
    private weak var document: DataDocument?
    fileprivate private(set) var columns: [GridColumn] = []
    private(set) var contentWidth: CGFloat = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { nil }

    let rowHeight: CGFloat = 24
    private let cellInset: CGFloat = 6
    private var rowCount = 0

    static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }

    private lazy var leftAttributes = Self.makeAttributes(alignment: .left)
    private lazy var rightAttributes = Self.makeAttributes(alignment: .right)

    private static func makeAttributes(alignment: NSTextAlignment) -> [NSAttributedString.Key: Any] {
        let style = NSMutableParagraphStyle()
        style.alignment = alignment
        style.lineBreakMode = .byTruncatingTail
        return [
            .font: font,
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: style
        ]
    }

    func load(document: DataDocument) {
        self.document = document
        rowCount = Int(min(document.rowCount, Int64(Int.max)))

        var x: CGFloat = 0
        columns = document.columns.map { info in
            let titleWidth = CGFloat(info.name.count) * 8 + 2 * cellInset + 6
            let isNumeric = info.type == DATA_NUMERIC
            let width = max(isNumeric ? 80 : 100, min(260, titleWidth)).rounded()
            let column = GridColumn(index: info.index, title: info.name,
                                    isNumeric: isNumeric, width: width, x: x)
            x += width
            return column
        }
        contentWidth = x
        setFrameSize(NSSize(width: x, height: CGFloat(rowCount) * rowHeight))
        needsDisplay = true
    }

    /// Indices of columns whose horizontal extent intersects `[minX, maxX)`.
    fileprivate func columnRange(minX: CGFloat, maxX: CGFloat) -> Range<Int> {
        guard !columns.isEmpty else { return 0..<0 }
        var first = 0
        while first < columns.count && columns[first].x + columns[first].width <= minX { first += 1 }
        var last = first
        while last < columns.count && columns[last].x < maxX { last += 1 }
        return first..<last
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        dirtyRect.fill()

        guard let document, rowCount > 0, !columns.isEmpty else { return }

        let firstRow = max(0, Int((dirtyRect.minY / rowHeight).rounded(.down)))
        let lastRow = min(rowCount - 1, Int((dirtyRect.maxY / rowHeight).rounded(.up)))
        guard firstRow <= lastRow else { return }
        let cols = columnRange(minX: dirtyRect.minX, maxX: dirtyRect.maxX)
        guard !cols.isEmpty else { return }

        // Alternating row backgrounds (odd rows tinted).
        if let alt = NSColor.alternatingContentBackgroundColors.dropFirst().first {
            alt.setFill()
            for row in firstRow...lastRow where row % 2 == 1 {
                NSRect(x: dirtyRect.minX, y: CGFloat(row) * rowHeight,
                       width: dirtyRect.width, height: rowHeight).fill()
            }
        }

        // Grid lines.
        let lines = NSBezierPath()
        lines.lineWidth = 1
        for row in firstRow...(lastRow + 1) {
            let y = CGFloat(row) * rowHeight + 0.5
            lines.move(to: NSPoint(x: dirtyRect.minX, y: y))
            lines.line(to: NSPoint(x: dirtyRect.maxX, y: y))
        }
        for col in cols {
            let x = columns[col].x + columns[col].width - 0.5
            lines.move(to: NSPoint(x: x, y: dirtyRect.minY))
            lines.line(to: NSPoint(x: x, y: dirtyRect.maxY))
        }
        NSColor.gridColor.setStroke()
        lines.stroke()

        // Cell text — only the cells inside the dirty rect are touched.
        let lineHeight = Self.font.boundingRectForFont.height
        let insetY = ((rowHeight - lineHeight) / 2).rounded()
        for col in cols {
            let column = columns[col]
            let attrs = column.isNumeric ? rightAttributes : leftAttributes
            for row in firstRow...lastRow {
                guard let text = document.cell(row: row, column: column.index), !text.isEmpty else { continue }
                let rect = NSRect(x: column.x + cellInset,
                                  y: CGFloat(row) * rowHeight + insetY,
                                  width: column.width - 2 * cellInset,
                                  height: lineHeight)
                (text as NSString).draw(in: rect, withAttributes: attrs)
            }
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// Column-name header that stays pinned while the grid scrolls vertically and
/// tracks the grid's horizontal scroll via `xOffset`.
final class DataGridHeaderView: NSView {
    weak var grid: DataGridView?
    var xOffset: CGFloat = 0 {
        didSet { if oldValue != xOffset { needsDisplay = true } }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { nil }

    private static let font = NSFont.systemFont(ofSize: 12, weight: .semibold)
    private let cellInset: CGFloat = 6

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }

    private lazy var attributes: [NSAttributedString.Key: Any] = {
        let style = NSMutableParagraphStyle()
        style.alignment = .left
        style.lineBreakMode = .byTruncatingTail
        return [.font: Self.font, .foregroundColor: NSColor.labelColor, .paragraphStyle: style]
    }()

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
        guard let grid else { return }
        let columns = grid.columns

        // Only paint columns that intersect the dirty rect, and clip
        // everything to the header's own bounds so text/separators drawn
        // at negative screenX (scrolled-right columns) don't bleed into
        // the sidebar.
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: bounds).setClip()

        let range = grid.columnRange(minX: xOffset + dirtyRect.minX, maxX: xOffset + dirtyRect.maxX)

        let lines = NSBezierPath()
        lines.lineWidth = 1
        let bottom = bounds.maxY - 0.5
        lines.move(to: NSPoint(x: dirtyRect.minX, y: bottom))
        lines.line(to: NSPoint(x: dirtyRect.maxX, y: bottom))

        let lineHeight = Self.font.boundingRectForFont.height
        let textY = ((bounds.height - lineHeight) / 2).rounded()
        for col in range {
            let column = columns[col]
            let screenX = column.x - xOffset
            let separatorX = screenX + column.width - 0.5
            lines.move(to: NSPoint(x: separatorX, y: 0))
            lines.line(to: NSPoint(x: separatorX, y: bounds.maxY))

            let rect = NSRect(x: screenX + cellInset, y: textY,
                              width: column.width - 2 * cellInset, height: lineHeight)
            (column.title as NSString).draw(in: rect, withAttributes: attributes)
        }
        NSColor.gridColor.setStroke()
        lines.stroke()

        NSGraphicsContext.restoreGraphicsState()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
