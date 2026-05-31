import Foundation
import QuickLookUI
import UniformTypeIdentifiers
import DataCore

public final class DataPreviewProvider: QLPreviewProvider, QLPreviewingController {
    public func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {
        let fileURL = request.fileURL
        let contentSize = CGSize(width: 980, height: 720)

        let reply = QLPreviewReply(dataOfContentType: .html, contentSize: contentSize) { reply in
            reply.stringEncoding = .utf8
            reply.title = fileURL.lastPathComponent

            let html = Self.renderHTML(for: fileURL)
            return Data(html.utf8)
        }

        return reply
    }

    private static func renderHTML(for fileURL: URL) -> String {
        var errorCode: Int32 = 0
        guard let doc = data_open(fileURL.path, &errorCode) else {
            let message = String(cString: data_error_message(errorCode))
            return errorHTML(title: fileURL.lastPathComponent, message: message)
        }
        defer {
            data_close(doc)
        }

        guard let metaPointer = data_metadata(doc) else {
            return errorHTML(title: fileURL.lastPathComponent, message: "Metadata unavailable.")
        }

        let meta = metaPointer.pointee
        let columns = readColumns(meta)
        let previewRowCount = min(Int32(40), Int32(max(0, min(meta.row_count, Int64(Int32.max)))))
        let chunk = previewRowCount > 0 ? data_fetch(doc, 0, previewRowCount) : nil
        defer {
            if let chunk {
                data_chunk_free(chunk)
            }
        }

        return documentHTML(
            fileName: fileURL.lastPathComponent,
            datasetLabel: string(from: meta.dataset_label),
            rowCount: meta.row_count,
            columns: columns,
            chunk: chunk
        )
    }

    private static func readColumns(_ meta: DataMeta) -> [PreviewColumn] {
        guard let columnPointer = meta.columns else {
            return []
        }

        var columns: [PreviewColumn] = []
        for index in 0..<Int(meta.col_count) {
            let column = columnPointer[index]
            columns.append(
                PreviewColumn(
                    name: string(from: column.name),
                    label: string(from: column.label),
                    type: column.type
                )
            )
        }
        return columns
    }

    private static func documentHTML(
        fileName: String,
        datasetLabel: String,
        rowCount: Int64,
        columns: [PreviewColumn],
        chunk: UnsafeMutablePointer<DataChunk>?
    ) -> String {
        let subtitle = datasetLabel.isEmpty ? "Dataset" : datasetLabel
        let columnList = columns.prefix(80).map { column in
            let label = column.label.isEmpty ? "" : "<span>\(escape(column.label))</span>"
            return "<li><strong>\(escape(column.name))</strong>\(label)</li>"
        }.joined()

        let headers = columns.map { column in
            "<th>\(escape(column.name))</th>"
        }.joined()

        let body = previewRows(columns: columns, chunk: chunk)
        let hiddenColumnNote = columns.count > 80 ? "<p class=\"note\">Showing first 80 variables in sidebar.</p>" : ""

        return """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <style>
        :root { color-scheme: light dark; }
        body {
            margin: 0;
            font: 13px -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif;
            color: CanvasText;
            background: Canvas;
        }
        .wrap { padding: 22px 24px 24px; }
        header {
            display: flex;
            align-items: baseline;
            justify-content: space-between;
            gap: 16px;
            margin-bottom: 16px;
        }
        h1 {
            font-size: 22px;
            margin: 0 0 4px;
            font-weight: 650;
        }
        .subtitle { color: color-mix(in srgb, CanvasText 66%, transparent); }
        .counts {
            white-space: nowrap;
            font-variant-numeric: tabular-nums;
            color: color-mix(in srgb, CanvasText 72%, transparent);
        }
        .grid {
            display: grid;
            grid-template-columns: 240px minmax(0, 1fr);
            gap: 18px;
        }
        aside {
            border: 1px solid color-mix(in srgb, CanvasText 14%, transparent);
            border-radius: 8px;
            padding: 12px;
            max-height: 590px;
            overflow: hidden;
        }
        h2 {
            font-size: 13px;
            margin: 0 0 10px;
            font-weight: 650;
        }
        ul {
            list-style: none;
            padding: 0;
            margin: 0;
        }
        li {
            padding: 4px 0;
            border-bottom: 1px solid color-mix(in srgb, CanvasText 8%, transparent);
        }
        li span {
            display: block;
            color: color-mix(in srgb, CanvasText 62%, transparent);
            overflow: hidden;
            text-overflow: ellipsis;
            white-space: nowrap;
        }
        .tableBox {
            border: 1px solid color-mix(in srgb, CanvasText 14%, transparent);
            border-radius: 8px;
            overflow: auto;
            max-height: 590px;
        }
        table {
            border-collapse: collapse;
            width: 100%;
            min-width: 940px;
            font-variant-numeric: tabular-nums;
        }
        th, td {
            padding: 7px 9px;
            border-right: 1px solid color-mix(in srgb, CanvasText 10%, transparent);
            border-bottom: 1px solid color-mix(in srgb, CanvasText 8%, transparent);
            white-space: nowrap;
        }
        th {
            position: sticky;
            top: 0;
            text-align: left;
            background: color-mix(in srgb, Canvas 88%, CanvasText 12%);
            font-weight: 650;
        }
        td.num { text-align: right; font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }
        td.str { max-width: 220px; overflow: hidden; text-overflow: ellipsis; }
        .note { color: color-mix(in srgb, CanvasText 58%, transparent); margin: 10px 0 0; }
        </style>
        </head>
        <body>
        <div class="wrap">
            <header>
                <div>
                    <h1>\(escape(fileName))</h1>
                    <div class="subtitle">\(escape(subtitle))</div>
                </div>
                <div class="counts">\(rowCount) rows x \(columns.count) columns</div>
            </header>
            <div class="grid">
                <aside>
                    <h2>Variables</h2>
                    <ul>\(columnList)</ul>
                    \(hiddenColumnNote)
                </aside>
                <main class="tableBox">
                    <table>
                        <thead><tr>\(headers)</tr></thead>
                        <tbody>\(body)</tbody>
                    </table>
                </main>
            </div>
        </div>
        </body>
        </html>
        """
    }

    private static func previewRows(columns: [PreviewColumn], chunk: UnsafeMutablePointer<DataChunk>?) -> String {
        guard let chunk, let cells = chunk.pointee.cells else {
            return "<tr><td colspan=\"\(max(columns.count, 1))\">No rows to preview.</td></tr>"
        }

        var rows: [String] = []
        for row in 0..<Int(chunk.pointee.count) {
            var cellsHTML: [String] = []
            for column in 0..<columns.count {
                let index = row * Int(chunk.pointee.col_count) + column
                let value = cells[index].map { String(cString: $0) } ?? ""
                let cssClass = columns[column].type == DATA_NUMERIC ? "num" : "str"
                cellsHTML.append("<td class=\"\(cssClass)\">\(escape(value))</td>")
            }
            rows.append("<tr>\(cellsHTML.joined())</tr>")
        }
        return rows.joined()
    }

    private static func errorHTML(title: String, message: String) -> String {
        """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <style>
        body { margin: 0; padding: 28px; font: 14px -apple-system, BlinkMacSystemFont, sans-serif; }
        h1 { font-size: 20px; margin: 0 0 8px; }
        p { color: #666; }
        </style>
        </head>
        <body>
        <h1>\(escape(title))</h1>
        <p>Unable to preview this data file: \(escape(message))</p>
        </body>
        </html>
        """
    }

    private static func string(from pointer: UnsafeMutablePointer<CChar>?) -> String {
        guard let pointer else {
            return ""
        }
        return String(cString: pointer)
    }

    private static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

private struct PreviewColumn {
    let name: String
    let label: String
    let type: DataColType
}
