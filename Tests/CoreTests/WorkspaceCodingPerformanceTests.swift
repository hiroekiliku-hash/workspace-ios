import XCTest
#if SWIFT_PACKAGE
@testable import WorkspaceCore
#endif

final class WorkspaceCodingPerformanceTests: XCTestCase {
    func testCachedDatesMatchOriginalFormatterForWireVariantsAndReusedCodec() throws {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let ordinary = ISO8601DateFormatter()
        let strings = [
            "2026-10-20T07:59:21.123Z", "2026-10-20T15:59:21.123+08:00",
            "2026-10-20T07:59:21Z", "2026-10-20T15:59:21+08:00",
            "2026-10-20T07:59:21.123456Z", "1970-01-01T00:00:00.000Z",
            "1960-01-01T00:00:00.999Z"
        ]
        let data = try JSONEncoder().encode(strings + strings)
        let expected = try (strings + strings).map { value in
            try XCTUnwrap(fractional.date(from: value) ?? ordinary.date(from: value))
        }
        let decoder = WorkspaceCoding.decoder()
        XCTAssertEqual(try decoder.decode([Date].self, from: data), expected)
        XCTAssertEqual(try decoder.decode([Date].self, from: data), expected)

        let encoder = WorkspaceCoding.encoder()
        let expectedStrings = expected.map { fractional.string(from: $0) }
        XCTAssertEqual(try JSONDecoder().decode([String].self, from: encoder.encode(expected)), expectedStrings)
        XCTAssertEqual(try JSONDecoder().decode([String].self, from: encoder.encode(expected)), expectedStrings)
    }

    func testDateCacheEvictionKeepsEncodingAndDecodingSemantics() throws {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let origin = Date(timeIntervalSince1970: 1_792_481_321.123456)
        let dates = (0..<8_220).map { origin.addingTimeInterval(Double($0) * 1.234567) }
        let all = dates + [dates[0], dates[1], dates.last!, dates[0]]
        let encoder = WorkspaceCoding.encoder()
        let data = try encoder.encode(all)
        let strings = try JSONDecoder().decode([String].self, from: data)
        XCTAssertEqual(strings, all.map { formatter.string(from: $0) })
        let expected = try strings.map { try XCTUnwrap(formatter.date(from: $0)) }
        let decoder = WorkspaceCoding.decoder()
        XCTAssertEqual(try decoder.decode([Date].self, from: data), expected)
        XCTAssertEqual(try decoder.decode([Date].self, from: data), expected)
        // Millisecond normalization remains a wire-format operation, not a cache-key rounding rule.
        let submillisecond = [origin, origin.addingTimeInterval(0.0009), origin.addingTimeInterval(0.0011)]
        XCTAssertEqual(try JSONDecoder().decode([String].self, from: encoder.encode(submillisecond)),
            submillisecond.map { formatter.string(from: $0) })
    }

    func testCachedDecoderStillRejectsInvalidDatesAfterSuccessfulReads() throws {
        let decoder = WorkspaceCoding.decoder()
        _ = try decoder.decode([Date].self, from: Data("[\"2026-10-20T07:59:21.123Z\"]".utf8))
        for value in ["", "not-a-date", "2026-99-99T07:59:21Z"] {
            let data = try JSONEncoder().encode([value])
            XCTAssertThrowsError(try decoder.decode([Date].self, from: data))
            XCTAssertThrowsError(try decoder.decode([Date].self, from: data))
        }
    }
}
