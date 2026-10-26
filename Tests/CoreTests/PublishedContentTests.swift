import XCTest
#if SWIFT_PACKAGE
@testable import WorkspaceCore
#endif

final class PublishedContentTests: XCTestCase {
    private let digest = String(repeating: "a", count: 64)

    func testManifestRoundTripAllowsFutureEntriesWithoutRejectingKnownContent() throws {
        let entries = [entry(), entry(id: "future-card", kind: "future-card", minimum: 2)]
        let manifest = PublishedContentManifest(protocolVersion: PublishedContentRules.protocolVersion,
                                               revision: digest, entries: entries)
        try PublishedContentRules.validate(manifest)
        let data = try JSONEncoder().encode(manifest)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["protocol"] as? String, PublishedContentRules.protocolVersion)
        XCTAssertNil(object["protocolVersion"])
        XCTAssertEqual(try JSONDecoder().decode(PublishedContentManifest.self, from: data), manifest)
    }

    func testManifestRejectsDuplicatesInvalidMetadataAndSizeLimits() {
        func check(_ entries: [PublishedContentEntry], revision: String? = nil) {
            XCTAssertThrowsError(try PublishedContentRules.validate(PublishedContentManifest(
                protocolVersion: PublishedContentRules.protocolVersion, revision: revision ?? digest, entries: entries)))
        }
        check([entry(), entry()])
        check((0..<33).map { entry(id: "item-\($0)") })
        check((0..<5).map { entry(id: "item-\($0)", bytes: PublishedContentRules.packageLimit) })
        check([entry(bytes: 0)])
        check([entry(bytes: PublishedContentRules.packageLimit + 1)])
        check([entry(id: "../invalid")])
        check([entry(kind: "invalid.kind")])
        check([entry(version: 0)])
        check([entry(minimum: 0)])
        check([entry()], revision: digest.uppercased())
        var invalidDigest = entry(); invalidDigest.sha256 = String(repeating: "A", count: 64)
        check([invalidDigest])
    }

    func testPackageHeaderMustMatchEveryManifestFieldAndExactByteCount() throws {
        let baseline = try package(payload: tutorialPayload())
        let declaredEntry = try entry(for: baseline)
        for (key, replacement) in [
            ("protocol", "WORKSHOP-CONTENT/2" as Any),
            ("id", "different-tutorial" as Any),
            ("kind", "announcement" as Any),
            ("version", 2 as Any),
            ("minimumContentVersion", 2 as Any)
        ] {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: baseline) as? [String: Any])
            object[key] = replacement
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            var expected = declaredEntry; expected.byteCount = data.count
            XCTAssertThrowsError(try PublishedContentRules.decodePackage(data, entry: expected), key)
        }
        var wrongLength = declaredEntry; wrongLength.byteCount += 1
        XCTAssertThrowsError(try PublishedContentRules.decodePackage(baseline, entry: wrongLength))
        var padded = baseline
        padded.append(Data(repeating: 32, count: PublishedContentRules.packageLimit))
        XCTAssertThrowsError(try PublishedContentRules.decodePackage(padded, entry: declaredEntry))
    }

    func testTutorialAndAnnouncementDecodeAndRejectInvalidPayloads() throws {
        let tutorialData = try package(payload: tutorialPayload())
        guard case .tutorial(let tutorial) = try PublishedContentRules.decodePackage(tutorialData, entry: entry(for: tutorialData)) else {
            return XCTFail("Expected a tutorial")
        }
        XCTAssertEqual(tutorial.pages.map(\.id), ["home"])
        XCTAssertEqual(tutorial.pages[0].symbol, "house")
        let announcementData = try package(id: "notice", kind: "announcement", payload: [
            "id": "notice", "title": "内容已更新", "message": "可以查看新的演示课程。"
        ])
        XCTAssertEqual(try PublishedContentRules.decodePackage(announcementData, entry: entry(for: announcementData)),
                       .announcement(PublishedAnnouncement(id: "notice", title: "内容已更新", message: "可以查看新的演示课程。")))
        let invalidTutorials: [[String: Any]] = [
            ["pages": []],
            ["pages": Array(repeating: tutorialPage(), count: 2)],
            ["pages": (0..<13).map { tutorialPage(id: "page-\($0)") }],
            ["pages": [tutorialPage(title: String(repeating: "x", count: 241))]],
            ["pages": [tutorialPage(subtitle: String(repeating: "x", count: 2_001))]]
        ]
        for payload in invalidTutorials {
            let data = try package(payload: payload)
            XCTAssertThrowsError(try PublishedContentRules.decodePackage(data, entry: entry(for: data)))
        }
        let badAnnouncement = try package(id: "notice", kind: "announcement", payload: [
            "id": "../notice", "title": "标题", "message": "正文"
        ])
        XCTAssertThrowsError(try PublishedContentRules.decodePackage(badAnnouncement, entry: entry(for: badAnnouncement)))
        let invalidCourse = try package(id: "course", kind: "course", payload: [
            "protocol": "WORKSHOP-COURSE/1", "id": UUID().uuidString,
            "title": "无课时", "summary": "", "lessons": []
        ])
        XCTAssertThrowsError(try PublishedContentRules.decodePackage(invalidCourse, entry: entry(for: invalidCourse)))
    }

    func testUnsupportedPackagesCanBeSkippedBeforePayloadDecoding() throws {
        for (kind, minimum) in [("future-card", 1), ("tutorial", 2)] {
            // The manifest is valid, but an older interpreter must not apply this payload.
            let data = try package(kind: kind, minimum: minimum, payload: ["newShape": true])
            let value = try entry(for: data)
            XCTAssertNoThrow(try PublishedContentRules.validate(PublishedContentManifest(
                protocolVersion: PublishedContentRules.protocolVersion, revision: digest, entries: [value])))
            XCTAssertThrowsError(try PublishedContentRules.decodePackage(data, entry: value))
        }
    }

    func testAllPublishedServerFixturesDecodeWithCurrentNativeInterpreter() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let names = ["demo-course", "cpp-value-reference", "welcome-tutorial", "course-tutorial", "announcement"]
        var counts = ["course": 0, "tutorial": 0, "announcement": 0]
        var entries: [PublishedContentEntry] = []
        for name in names {
            let data = try Data(contentsOf: root.appendingPathComponent("Server/AppContent/\(name).json"))
            let value = try entry(for: data)
            entries.append(value)
            let payload = try PublishedContentRules.decodePackage(data, entry: value)
            switch payload {
            case .course(let course):
                XCTAssertFalse(course.lessons.isEmpty)
                counts["course", default: 0] += 1
            case .tutorial(let tutorial):
                XCTAssertEqual(tutorial.pages.count, 4)
                counts["tutorial", default: 0] += 1
            case .announcement(let announcement):
                XCTAssertFalse(announcement.message.isEmpty)
                counts["announcement", default: 0] += 1
            }
        }
        XCTAssertEqual(counts, ["course": 2, "tutorial": 2, "announcement": 1])
        XCTAssertNoThrow(try PublishedContentRules.validate(PublishedContentManifest(
            protocolVersion: PublishedContentRules.protocolVersion, revision: digest, entries: entries)))
    }

    private func entry(id: String = "welcome-tutorial", kind: String = "tutorial", version: Int = 1,
                       minimum: Int = 1, bytes: Int = 100) -> PublishedContentEntry {
        PublishedContentEntry(id: id, kind: kind, version: version, minimumContentVersion: minimum,
                              sha256: digest, byteCount: bytes)
    }

    private func entry(for data: Data) throws -> PublishedContentEntry {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return entry(id: try XCTUnwrap(object["id"] as? String),
                     kind: try XCTUnwrap(object["kind"] as? String),
                     version: try XCTUnwrap(object["version"] as? Int),
                     minimum: try XCTUnwrap(object["minimumContentVersion"] as? Int), bytes: data.count)
    }

    private func package(id: String = "welcome-tutorial", kind: String = "tutorial", minimum: Int = 1,
                         payload: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "protocol": PublishedContentRules.protocolVersion, "id": id, "kind": kind,
            "version": 1, "minimumContentVersion": minimum, "payload": payload
        ], options: [.sortedKeys])
    }

    private func tutorialPayload() -> [String: Any] { ["pages": [tutorialPage()]] }

    private func tutorialPage(id: String = "home", title: String = "开始使用", subtitle: String = "安排你的一天。") -> [String: Any] {
        ["id": id, "title": title, "subtitle": subtitle, "sectionTitle": "首页", "symbol": "house"]
    }
}
