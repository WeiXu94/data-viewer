import XCTest
import DataCore

final class DataCoreTests: XCTestCase {
    func testAutoMetadataAndFetch() throws {
        let fixture = Bundle.module.url(forResource: "auto", withExtension: "dta")
        let path = try XCTUnwrap(fixture?.path)

        var errorCode: Int32 = 0
        let doc = try XCTUnwrap(data_open(path, &errorCode), "open failed: \(String(cString: data_error_message(errorCode)))")
        defer {
            data_close(doc)
        }

        let meta = try XCTUnwrap(data_metadata(doc)).pointee
        XCTAssertEqual(meta.row_count, 74)
        XCTAssertEqual(meta.col_count, 12)
        XCTAssertEqual(String(cString: meta.columns[0].name), "make")

        let first = try XCTUnwrap(data_fetch(doc, 0, 10))
        defer {
            data_chunk_free(first)
        }
        XCTAssertEqual(first.pointee.count, 10)
        XCTAssertEqual(String(cString: first.pointee.cells[0]!), "AMC Concord")
        XCTAssertEqual(String(cString: first.pointee.cells[1]!), "4,099")
        XCTAssertEqual(String(cString: first.pointee.cells[10]!), "3.58")

        let overlapping = try XCTUnwrap(data_fetch(doc, 3, 2))
        data_chunk_free(overlapping)

        let stats = data_cache_stats(doc)
        XCTAssertGreaterThanOrEqual(stats.cached_chunks, 1)
        XCTAssertGreaterThanOrEqual(stats.hits, 1)
    }

    func testRdsMetadataAndFetch() throws {
        let fixture = Bundle.module.url(forResource: "sample", withExtension: "rds")
        let path = try XCTUnwrap(fixture?.path)

        var errorCode: Int32 = 0
        let doc = try XCTUnwrap(data_open(path, &errorCode), "open failed: \(String(cString: data_error_message(errorCode)))")
        defer {
            data_close(doc)
        }

        let meta = try XCTUnwrap(data_metadata(doc)).pointee
        XCTAssertEqual(meta.file_type, DATA_FILE_RDS)
        XCTAssertEqual(meta.row_count, 3)
        XCTAssertEqual(meta.col_count, 4)
        XCTAssertEqual(String(cString: meta.columns[0].name), "name")
        XCTAssertEqual(meta.columns[0].type, DATA_STRING)
        XCTAssertEqual(meta.columns[1].type, DATA_NUMERIC)

        let first = try XCTUnwrap(data_fetch(doc, 0, 3))
        defer {
            data_chunk_free(first)
        }

        XCTAssertEqual(String(cString: first.pointee.cells[0]!), "alpha")
        XCTAssertEqual(String(cString: first.pointee.cells[1]!), "1.25")
        XCTAssertNil(first.pointee.cells[5])
        XCTAssertEqual(String(cString: first.pointee.cells[7]!), "FALSE")
        XCTAssertNil(first.pointee.cells[11])
    }

    func testMatMetadataAndFetch() throws {
        let fixture = Bundle.module.url(forResource: "sample", withExtension: "mat")
        let path = try XCTUnwrap(fixture?.path)

        var errorCode: Int32 = 0
        let doc = try XCTUnwrap(data_open(path, &errorCode), "open failed: \(String(cString: data_error_message(errorCode)))")
        defer {
            data_close(doc)
        }

        let meta = try XCTUnwrap(data_metadata(doc)).pointee
        XCTAssertEqual(meta.file_type, DATA_FILE_MAT)
        XCTAssertEqual(meta.row_count, 3)
        XCTAssertEqual(meta.col_count, 2)
        XCTAssertEqual(String(cString: meta.columns[0].name), "values[1]")
        XCTAssertEqual(String(cString: meta.columns[1].name), "values[2]")

        let first = try XCTUnwrap(data_fetch(doc, 0, 3))
        defer {
            data_chunk_free(first)
        }

        XCTAssertEqual(String(cString: first.pointee.cells[0]!), "1.5")
        XCTAssertEqual(String(cString: first.pointee.cells[1]!), "10")
        XCTAssertEqual(String(cString: first.pointee.cells[4]!), "3.75")
        XCTAssertEqual(String(cString: first.pointee.cells[5]!), "30")
    }
}
