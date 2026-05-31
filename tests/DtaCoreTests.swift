import XCTest
import DtaCore

final class DtaCoreTests: XCTestCase {
    func testAutoMetadataAndFetch() throws {
        let fixture = Bundle.module.url(forResource: "auto", withExtension: "dta")
        let path = try XCTUnwrap(fixture?.path)

        var errorCode: Int32 = 0
        let doc = try XCTUnwrap(dta_open(path, &errorCode), "open failed: \(String(cString: dta_error_message(errorCode)))")
        defer {
            dta_close(doc)
        }

        let meta = try XCTUnwrap(dta_metadata(doc)).pointee
        XCTAssertEqual(meta.row_count, 74)
        XCTAssertEqual(meta.col_count, 12)
        XCTAssertEqual(String(cString: meta.columns[0].name), "make")

        let first = try XCTUnwrap(dta_fetch(doc, 0, 10))
        defer {
            dta_chunk_free(first)
        }
        XCTAssertEqual(first.pointee.count, 10)
        XCTAssertEqual(String(cString: first.pointee.cells[0]!), "AMC Concord")
        XCTAssertEqual(String(cString: first.pointee.cells[1]!), "4,099")
        XCTAssertEqual(String(cString: first.pointee.cells[10]!), "3.58")

        let overlapping = try XCTUnwrap(dta_fetch(doc, 3, 2))
        dta_chunk_free(overlapping)

        let stats = dta_cache_stats(doc)
        XCTAssertGreaterThanOrEqual(stats.cached_chunks, 1)
        XCTAssertGreaterThanOrEqual(stats.hits, 1)
    }
}
