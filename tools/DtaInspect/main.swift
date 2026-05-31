import Foundation
import DtaCore

func cString(_ pointer: UnsafeMutablePointer<CChar>?) -> String {
    guard let pointer else {
        return ""
    }
    return String(cString: pointer)
}

func printUsageAndExit() -> Never {
    fputs("Usage: dta-inspect <file.dta> [rows]\n", stderr)
    exit(2)
}

let arguments = CommandLine.arguments.dropFirst()
guard let path = arguments.first else {
    printUsageAndExit()
}

let rowsToPrint = arguments.dropFirst().first.flatMap(Int.init) ?? 5
var errorCode: Int32 = 0

guard let doc = dta_open(path, &errorCode) else {
    fputs("open failed: \(String(cString: dta_error_message(errorCode)))\n", stderr)
    exit(1)
}
defer {
    dta_close(doc)
}

guard let metaPointer = dta_metadata(doc) else {
    fputs("metadata unavailable\n", stderr)
    exit(1)
}

let meta = metaPointer.pointee
print("file: \(URL(fileURLWithPath: path).lastPathComponent)")
print("rows: \(meta.row_count)")
print("columns: \(meta.col_count)")
print("label: \(cString(meta.dataset_label))")

if let columns = meta.columns {
    for index in 0..<Int(meta.col_count) {
        let column = columns[index]
        let type = column.type == DTA_NUMERIC ? "numeric" : "string"
        print("column[\(index)]: \(cString(column.name)) \(type) \(cString(column.format)) \(cString(column.label))")
    }
}

let limitedRows = max(0, min(rowsToPrint, Int(meta.row_count)))
if limitedRows > 0, let chunk = dta_fetch(doc, 0, Int32(limitedRows)) {
    defer {
        dta_chunk_free(chunk)
    }

    print("preview:")
    if let cells = chunk.pointee.cells {
        for row in 0..<Int(chunk.pointee.count) {
            var values: [String] = []
            for col in 0..<Int(chunk.pointee.col_count) {
                let index = row * Int(chunk.pointee.col_count) + col
                values.append(cells[index].map { String(cString: $0) } ?? "")
            }
            print(values.joined(separator: "\t"))
        }
    }
}

let stats = dta_cache_stats(doc)
print("cache: chunks=\(stats.cached_chunks) hits=\(stats.hits) misses=\(stats.misses)")
