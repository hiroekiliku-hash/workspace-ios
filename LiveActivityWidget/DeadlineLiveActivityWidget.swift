import ActivityKit
import SwiftUI
import WidgetKit

private let activityAccent = Color(red: 0.64, green: 0.72, blue: 1)

private struct DeadlineTimerText: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let startedAt: Date
    let dueDate: Date
    let isStale: Bool
    var body: some View {
        // Archived timer text is horizontally flexible. A hidden static sample provides
        // a finite, content-sized proposal; text alignment controls the digits inside it.
        Text(widthSample).hidden().fixedSize()
            .overlay(alignment: .trailing) {
                animatedTimer.multilineTextAlignment(.trailing)
            }
            .monospacedDigit()
            .lineLimit(1).minimumScaleFactor(0.85)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(WorkspaceLocalization.string(isStale ? "已到截止" : "距离截止"))
            .accessibilityValue(isStale ? Text("零") : Text(dueDate, style: .relative))
    }
    private var widthSample: String {
        let duration = dueDate.timeIntervalSince(startedAt)
        if isStale || duration <= 0 { return "0:00" }
        if duration >= 3600 { return "8:88:88" }
        if duration >= 600 { return "88:88" }
        return "8:88"
    }
    private var animatedTimer: some View {
        Group {
            if isStale || dueDate <= startedAt { Text("0:00") }
            else if reduceMotion { timer }
            else { timer.contentTransition(.numericText(countsDown: true)) }
        }
    }
    private var timer: Text {
        // A bounded interval stops at zero instead of counting upwards after the deadline.
        Text(timerInterval: startedAt...dueDate, countsDown: true, showsHours: true)
    }
}

private struct DeadlineProgressRing: View {
    let startedAt: Date
    let dueDate: Date
    let isStale: Bool
    let diameter: CGFloat
    var body: some View {
        ZStack {
            Group {
                if isStale || dueDate <= startedAt { ProgressView(value: 0) }
                else {
                    ProgressView(timerInterval: startedAt...dueDate, countsDown: true) {
                        EmptyView()
                    } currentValueLabel: {
                        EmptyView()
                    }
                }
            }
            .progressViewStyle(.circular).tint(activityAccent).labelsHidden()
            Image(systemName: isStale ? "flag.checkered" : "hourglass")
                .font(.system(size: diameter * 0.38, weight: .semibold))
                .foregroundStyle(activityAccent)
        }
        .frame(width: diameter, height: diameter)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(WorkspaceLocalization.string(isStale ? "DDL 已到截止" : "DDL 剩余时间进度"))
        .accessibilityValue(isStale ? Text("零") : Text(dueDate, style: .relative))
    }
}

private struct DeadlineCompactTime: View {
    let timer: DeadlineTimerText
    var body: some View {
        timer
            .font(.system(.caption, weight: .semibold))
            .foregroundStyle(activityAccent)
    }
}

// New SDKs expose the narrow landscape presentation; older SDKs retain the iOS 17 layout.
#if compiler(>=6.4)
@available(iOS 27.0, *)
private struct DeadlineWidthAwareCompactTime: View {
    @Environment(\.isDynamicIslandLimitedInWidth) private var limitedInWidth
    let time: DeadlineCompactTime
    var body: some View {
        if !limitedInWidth { time }
    }
}
#endif

struct DeadlineLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DeadlineActivityAttributes.self) { context in
            DeadlineLockScreenCard(context: context)
                .environment(\.locale, WorkspaceLocalization.locale)
                .widgetURL(url(context))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.bottom) {
                    DeadlineActivityRows(context: context, isIsland: true)
                        .environment(\.locale, WorkspaceLocalization.locale)
                        .padding(.top, 6)
                }
            } compactLeading: {
                ring(context, diameter: 22)
            } compactTrailing: {
                compactTime(context)
            } minimal: {
                ring(context, diameter: 22)
            }
            .contentMargins(.horizontal, 20, for: .expanded)
            .contentMargins(.bottom, 16, for: .expanded)
            .widgetURL(url(context)).keylineTint(activityAccent)
        }
    }
    private func timer(_ context: ActivityViewContext<DeadlineActivityAttributes>) -> DeadlineTimerText {
        DeadlineTimerText(startedAt: context.attributes.startedAt, dueDate: context.state.dueDate, isStale: context.isStale)
    }
    private func ring(_ context: ActivityViewContext<DeadlineActivityAttributes>, diameter: CGFloat) -> some View {
        DeadlineProgressRing(startedAt: context.attributes.startedAt, dueDate: context.state.dueDate, isStale: context.isStale, diameter: diameter)
    }
    private func entries(_ context: ActivityViewContext<DeadlineActivityAttributes>) -> [DeadlineActivityAttributes.Entry] {
        context.state.entries ?? [.init(id: context.attributes.recordID, title: context.state.title, dueDate: context.state.dueDate)]
    }
    @ViewBuilder private func compactTime(_ context: ActivityViewContext<DeadlineActivityAttributes>) -> some View {
        let time = DeadlineCompactTime(timer: timer(context))
        #if compiler(>=6.4)
        if #available(iOS 27.0, *) { DeadlineWidthAwareCompactTime(time: time) }
        else { time }
        #else
        time
        #endif
    }
    private func url(_ context: ActivityViewContext<DeadlineActivityAttributes>) -> URL {
        deadlineActivityURL(context)
    }
}
private func deadlineActivityURL(_ context: ActivityViewContext<DeadlineActivityAttributes>, recordID: UUID? = nil) -> URL {
    var components = URLComponents(string: "guangyi-workspace://record/\((recordID ?? context.state.entries?.first?.id ?? context.attributes.recordID).uuidString)")!
    if let session = context.attributes.demoSessionID {
        components.queryItems = [URLQueryItem(name: "demo", value: session.uuidString)]
    }
    return components.url!
}

private struct DeadlineLockScreenCard: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let context: ActivityViewContext<DeadlineActivityAttributes>
    private var resolvedScheme: ColorScheme {
        switch context.state.lockScreenAppearance {
        case "light": .light
        case "dark": .dark
        default: colorScheme
        }
    }
    private var accent: Color {
        resolvedScheme == .dark ? activityAccent : Color(red: 0.30, green: 0.43, blue: 0.67)
    }
    var body: some View {
        DeadlineActivityRows(context: context, isIsland: false)
            .padding(.horizontal, 20).padding(.vertical, 16)
        .environment(\.colorScheme, resolvedScheme)
        .activityBackgroundTint((resolvedScheme == .dark ? Color.black : Color.white)
            .opacity(reduceTransparency ? 1 : 0.82))
        .activitySystemActionForegroundColor(accent)
    }
}

private struct DeadlineActivityRows: View {
    @Environment(\.colorScheme) private var colorScheme
    let context: ActivityViewContext<DeadlineActivityAttributes>
    let isIsland: Bool
    private var entries: [DeadlineActivityAttributes.Entry] {
        context.state.entries ?? [.init(id: context.attributes.recordID, title: context.state.title, dueDate: context.state.dueDate)]
    }
    private var accent: Color {
        isIsland || colorScheme == .dark ? activityAccent : Color(red: 0.30, green: 0.43, blue: 0.67)
    }
    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                Link(destination: deadlineActivityURL(context, recordID: entry.id)) {
                    HStack(spacing: 12) {
                        Circle().fill(accent.opacity(index == 0 ? 1 : 0.5))
                            .frame(width: index == 0 ? 7 : 5, height: index == 0 ? 7 : 5)
                            .frame(width: 8)
                            .accessibilityHidden(true)
                        Text(entry.title)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(isIsland ? Color.white : Color.primary)
                            .lineLimit(1).truncationMode(.tail).privacySensitive()
                        Spacer(minLength: 0)
                        DeadlineTimerText(startedAt: context.attributes.startedAt, dueDate: entry.dueDate, isStale: context.isStale)
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(accent).fixedSize()
                    }
                    .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                    .contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }
        .background(alignment: .leading) {
            if entries.count > 1 {
                Rectangle().fill(accent.opacity(0.18))
                    .frame(width: 1)
                    .padding(.vertical, 16).padding(.leading, 3.5)
                    .accessibilityHidden(true)
            }
        }
    }
}

@main struct DeadlineWidgetBundle: WidgetBundle {
    var body: some Widget {
        WorkspaceTodayWidget()
        WorkspaceDeadlineWidget()
        WorkspaceFocusWidget()
        DeadlineLiveActivityWidget()
    }
}

#if DEBUG
private enum DeadlineActivityPreview {
    static let now = Date()
    static let attributes = DeadlineActivityAttributes(recordID: UUID(), startedAt: now.addingTimeInterval(-1800))
    static let short = DeadlineActivityAttributes.ContentState(title: "提交课程报告", dueDate: now.addingTimeInterval(5400))
    static let combined = DeadlineActivityAttributes.ContentState(title: "高数习题", dueDate: now.addingTimeInterval(1800), entries: [
        .init(id: UUID(), title: "高等数学 · 第三组习题", dueDate: now.addingTimeInterval(1800)),
        .init(id: UUID(), title: "英语展示开场稿与本周课程报告", dueDate: now.addingTimeInterval(5400)),
        .init(id: UUID(), title: "提交物理实验数据复核", dueDate: now.addingTimeInterval(7200))
    ])
    static let long = DeadlineActivityAttributes.ContentState(
        title: "提交本周课程报告与实验记录，附研究摘要和下一阶段的行动计划", dueDate: now.addingTimeInterval(65))
}

#Preview("紧凑", as: .dynamicIsland(.compact), using: DeadlineActivityPreview.attributes) {
    DeadlineLiveActivityWidget()
} contentStates: {
    DeadlineActivityPreview.short
    DeadlineActivityPreview.long
    DeadlineActivityPreview.combined
}

#Preview("展开", as: .dynamicIsland(.expanded), using: DeadlineActivityPreview.attributes) {
    DeadlineLiveActivityWidget()
} contentStates: {
    DeadlineActivityPreview.short
    DeadlineActivityPreview.long
    DeadlineActivityPreview.combined
}

#Preview("最小", as: .dynamicIsland(.minimal), using: DeadlineActivityPreview.attributes) {
    DeadlineLiveActivityWidget()
} contentStates: {
    DeadlineActivityPreview.short
    DeadlineActivityPreview.long
    DeadlineActivityPreview.combined
}

#Preview("锁屏", as: .content, using: DeadlineActivityPreview.attributes) {
    DeadlineLiveActivityWidget()
} contentStates: {
    DeadlineActivityPreview.short
    DeadlineActivityPreview.long
    DeadlineActivityPreview.combined
}
#endif
