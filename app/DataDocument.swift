import Foundation
import DataCore

struct DataColumnInfo {
    let index: Int
    let name: String
    let label: String
    let type: DataColType
    let format: String
}

enum DataDocumentError: LocalizedError {
    case openFailed(String)
    case metadataUnavailable

    var errorDescription: String? {
        switch self {
        case .openFailed(let message):
            return message
        case .metadataUnavailable:
            return "The file opened but metadata was unavailable."
        }
    }
}

final class DataDocument {
    let url: URL
    let rowCount: Int64
    let columns: [DataColumnInfo]
    let datasetLabel: String

    private let handle: OpaquePointer
    private let swiftChunkSize: Int32 = 1000
    private var currentChunk: UnsafeMutablePointer<DataChunk>?

    init(url: URL) throws {
        self.url = url

        var errorCode: Int32 = 0
        guard let opened = data_open(url.path, &errorCode) else {
            let message = String(cString: data_error_message(errorCode))
            throw DataDocumentError.openFailed(message)
        }
        handle = opened

        guard let metaPointer = data_metadata(opened) else {
            data_close(opened)
            throw DataDocumentError.metadataUnavailable
        }

        let meta = metaPointer.pointee
        rowCount = meta.row_count
        datasetLabel = DataDocument.string(from: meta.dataset_label)

        var parsedColumns: [DataColumnInfo] = []
        if let columnPointer = meta.columns {
            for index in 0..<Int(meta.col_count) {
                let column = columnPointer[index]
                parsedColumns.append(
                    DataColumnInfo(
                        index: Int(column.index),
                        name: DataDocument.string(from: column.name),
                        label: DataDocument.string(from: column.label),
                        type: column.type,
                        format: DataDocument.string(from: column.format)
                    )
                )
            }
        }
        columns = parsedColumns
    }

    deinit {
        if let currentChunk {
            data_chunk_free(currentChunk)
        }
        data_close(handle)
    }

    func cell(row: Int, column: Int) -> String? {
        guard row >= 0, column >= 0, Int64(row) < rowCount, column < columns.count else {
            return nil
        }
        guard ensureChunk(containing: row) else {
            return nil
        }
        guard let currentChunk else {
            return nil
        }

        let chunk = currentChunk.pointee
        let localRow = row - Int(chunk.offset)
        guard localRow >= 0, localRow < Int(chunk.count), let cells = chunk.cells else {
            return nil
        }

        let cellIndex = localRow * Int(chunk.col_count) + column
        guard let cString = cells[cellIndex] else {
            return nil
        }
        return String(cString: cString)
    }

    func cacheStatsSummary() -> String {
        let stats = data_cache_stats(handle)
        return "cache \(stats.cached_chunks) chunks, \(stats.hits) hits, \(stats.misses) misses"
    }

    private func ensureChunk(containing row: Int) -> Bool {
        if let currentChunk {
            let chunk = currentChunk.pointee
            if Int64(row) >= chunk.offset && Int64(row) < chunk.offset + Int64(chunk.count) {
                return true
            }
        }

        if let currentChunk {
            data_chunk_free(currentChunk)
            self.currentChunk = nil
        }

        let offset = (Int64(row) / Int64(swiftChunkSize)) * Int64(swiftChunkSize)
        guard let fetched = data_fetch(handle, offset, swiftChunkSize) else {
            return false
        }
        currentChunk = fetched
        return true
    }

    private static func string(from pointer: UnsafeMutablePointer<CChar>?) -> String {
        guard let pointer else {
            return ""
        }
        return String(cString: pointer)
    }
}
