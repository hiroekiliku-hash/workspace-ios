import XCTest
#if SWIFT_PACKAGE
@testable import WorkspaceCore
#endif

final class RecordIndexTests: XCTestCase {
    func testMembershipIndexPreservesOrderDeduplicatesParentsAndExcludesHiddenChildren() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var group = WorkspaceRecord(kind: .project, title: "Parent")
        group.projectID = group.id
        var pinned = WorkspaceRecord(kind: .task, title: "Pinned")
        pinned.projectID = group.id; pinned.pinned = true
        var early = WorkspaceRecord(kind: .task, title: "Early")
        early.dateOnly = false; early.projectID = group.id; early.areaID = group.id; early.dueDate = now
        var later = WorkspaceRecord(kind: .task, title: "Later")
        later.dateOnly = false; later.areaID = group.id; later.dueDate = now.addingTimeInterval(3600)
        var finished = WorkspaceRecord(kind: .task, title: "Finished")
        finished.projectID = group.id; finished.status = "DONE"
        var archived = WorkspaceRecord(kind: .project, title: "Hidden")
        archived.projectID = group.id; archived.archivedAt = now
        var hiddenChild = WorkspaceRecord(kind: .task, title: "Hidden child")
        hiddenChild.projectID = group.id; hiddenChild.areaID = archived.id
        let unrelated = (0..<1_000).map { WorkspaceRecord(kind: .task, title: "Other \($0)") }
        let index = WorkspaceRecordIndex([finished, later, group, archived, pinned, hiddenChild, early] + unrelated)
        XCTAssertEqual(index.members(of: group).map(\.id), [pinned.id, early.id, later.id, finished.id])
        XCTAssertTrue(index.members(of: archived).isEmpty)
        XCTAssertEqual(index.members(of: group).filter { $0.id == early.id }.count, 1)
    }
}
