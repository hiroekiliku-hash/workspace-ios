#if os(iOS)
import ActivityKit
import Foundation

struct DeadlineActivityAttributes: ActivityAttributes {
    struct Entry: Codable, Hashable, Identifiable {
        var id: UUID
        var title: String
        var dueDate: Date
    }
    struct ContentState: Codable, Hashable {
        var title: String
        var dueDate: Date
        // Optional so activities from earlier versions remain decodable.
        var entries: [Entry]? = nil
        var lockScreenAppearance: String? = nil
    }
    var recordID: UUID
    var startedAt: Date
    // Optional preserves decoding of activities created before demo sessions.
    var demoSessionID: UUID? = nil
}
#endif
