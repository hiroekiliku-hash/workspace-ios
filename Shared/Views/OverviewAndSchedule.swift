import SwiftUI
import Charts

/// Presentation-only priorities: urgency wins over distant stars; no stored order is changed.
enum HomePresentationOrder {
    static func moment(_ record: WorkspaceRecord) -> Date? {
        record.dueDate.map(record.effectiveDueDate) ?? record.scheduledAt ?? record.remindAt
    }
    static func priority(_ record: WorkspaceRecord, now: Date) -> Int {
        priority(record, moment: moment(record), now: now)
    }
    private static func priority(_ record: WorkspaceRecord, moment: Date?, now: Date) -> Int {
        guard let date = moment else { return record.pinned ? 3 : 5 }
        let interval = date.timeIntervalSince(now)
        if record.dueDate != nil && interval < 0 { return 0 }
        if interval <= 2 * 86_400 { return 1 }
        if interval <= 14 * 86_400 { return 2 }
        if interval <= 60 * 86_400 { return 4 }
        return 6
    }
    static func uniqueSeries(_ records: [WorkspaceRecord]) -> [WorkspaceRecord] {
        var seen: Set<UUID> = []
        return records.filter { record in record.recurrenceSeriesID.map { seen.insert($0).inserted } ?? true }
    }
    static func pending(_ records: [WorkspaceRecord], now: Date = Date()) -> [WorkspaceRecord] {
        // Resolve calendar dates once per record instead of again for every comparison.
        let values = records.compactMap { record -> (record: WorkspaceRecord, moment: Date, priority: Int)? in
            guard record.isLive, !record.isFinished, record.kind.isItem || record.kind == .deadline else { return nil }
            let date = moment(record)
            return (record, date ?? .distantFuture, priority(record, moment: date, now: now))
        }
        return uniqueSeries(values.sorted { a, b in
            if a.priority != b.priority { return a.priority < b.priority }
            // Stars only promote work in the same near-term urgency band.
            if a.priority < 6 && a.record.pinned != b.record.pinned { return a.record.pinned }
            if a.moment != b.moment { return a.moment < b.moment }
            if a.record.updatedAt != b.record.updatedAt { return a.record.updatedAt > b.record.updatedAt }
            return a.record.id.uuidString < b.record.id.uuidString
        }.map(\.record))
    }
    static func nearestDeadlines(_ records: [WorkspaceRecord]) -> [WorkspaceRecord] {
        let values = records.compactMap { record -> (record: WorkspaceRecord, moment: Date)? in
            guard record.kind == .deadline, record.isLive, !record.isFinished, record.dueDate != nil,
                  let date = moment(record) else { return nil }
            return (record, date)
        }
        return uniqueSeries(values.sorted {
            $0.moment == $1.moment ? $0.record.id.uuidString < $1.record.id.uuidString : $0.moment < $1.moment
        }.map(\.record))
    }
}

struct OverviewView: View {
    @Environment(WorkspaceStore.self) private var store
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var openedCountdown: UUID?
    var body: some View {
        let home = store.homePresentation
        overviewContent(nearest: home.nearest, pending: home.pending)
            .navigationTitle(store.isDemoMode ? WorkspaceLocalization.string("演示首页") : WorkspaceLocalization.string("首页"))
            .workspaceResponsiveTitle()
            .sensoryFeedback(.impact(weight: .medium, intensity: 0.9), trigger: openedCountdown) { _, value in store.hapticsEnabled && value != nil }
            .navigationDestination(item: $openedCountdown) { id in RecordDetailView(id: id) }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        RecordCreationActions { store.createKind = $0 }
                    } label: { Label(WorkspaceLocalization.string("添加"), systemImage: "plus") }
                    .disabled(store.isReadOnlyWorkspace)
                }
            }
            .refreshable { store.refresh() }
    }
    @ViewBuilder private func overviewContent(nearest: [WorkspaceRecord], pending: [WorkspaceRecord]) -> some View {
        #if os(iOS)
        GeometryReader { geometry in
            if geometry.size.width >= 680 && !typeSize.isAccessibilitySize && !nearest.isEmpty {
                HStack(spacing: 0) {
                    List { deadlineSection(nearest) }
                        .contentMargins(.horizontal, 16, for: .scrollContent)
                        .contentMargins(.top, 8, for: .scrollContent)
                        .frame(width: geometry.size.width * 0.46)
                    List { pendingSection(pending) }
                        .contentMargins(.horizontal, 16, for: .scrollContent)
                        .contentMargins(.top, 8, for: .scrollContent)
                }
                .accessibilityIdentifier("overview-columns")
            } else {
                List { deadlineSection(nearest); pendingSection(pending) }
            }
        }
        #else
        MacOverviewDashboard(nearest: nearest, pending: pending) { openedCountdown = $0 }
        #endif
    }
    @ViewBuilder private func deadlineSection(_ records: [WorkspaceRecord]) -> some View {
        if !records.isEmpty {
            Section(WorkspaceLocalization.string("截止事项")) {
                DeadlineCountdownSurface {
                    ForEach(records) { record in
                        Button { openedCountdown = record.id } label: { HomeDeadlineCard(record: record) }
                    }
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
            }
        }
    }
    private func pendingSection(_ records: [WorkspaceRecord]) -> some View {
        Section(WorkspaceLocalization.string("事项")) {
            if records.isEmpty {
                Text(WorkspaceLocalization.string("暂时没有事项。")).foregroundStyle(.secondary)
                Button(WorkspaceLocalization.string("新建事项"), systemImage: "plus") { store.createKind = .task }
                    .disabled(store.isReadOnlyWorkspace)
            } else {
                ForEach(records.prefix(10)) { record in
                    NavigationLink { RecordDetailView(id: record.id) } label: { HomeSummaryRow(record: record) }
                }
            }
        }
    }
}

/// One outer shape; adjacent gradients meet without gaps or divider strokes.
struct DeadlineCountdownSurface<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) { content }
            .buttonStyle(.plain)
            .background(.background)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.primary.opacity(0.06), lineWidth: 1) }
    }
}

/// Distant cards show minutes, so only the final day needs a per-second update.
/// Include the boundary explicitly so entering that final day never waits a minute.
private struct HomeDeadlineTimelineSchedule: TimelineSchedule {
    let target: Date
    func entries(from startDate: Date, mode: Mode) -> AnySequence<Date> {
        let countdownTarget = target
        return AnySequence {
            var nextDate = startDate
            return AnyIterator<Date> {
                let current = nextDate
                let remaining = countdownTarget.timeIntervalSince(current)
                var next = current.addingTimeInterval(1)
                if remaining >= 86_400 {
                    // Match changes in the displayed whole minutes, not the clock minute.
                    next = countdownTarget.addingTimeInterval(-floor(remaining / 60) * 60 + 1)
                } else if remaining <= -86_400 {
                    next = countdownTarget.addingTimeInterval((floor(-remaining / 60) + 1) * 60)
                }
                let startsShowingSeconds = countdownTarget.addingTimeInterval(-86_400 + 1)
                if current < startsShowingSeconds && startsShowingSeconds < next { next = startsShowingSeconds }
                nextDate = next
                return current
            }
        }
    }
}

struct HomeDeadlineCard: View {
    @Environment(\.workspacePalette) private var palette
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @ScaledMetric(relativeTo: .largeTitle) private var countdownSize = 40
    let record: WorkspaceRecord
    var body: some View {
        let due = record.dueDate.map(record.effectiveDueDate) ?? Date()
        TimelineView(HomeDeadlineTimelineSchedule(target: due)) { context in
            let overdue = due <= context.date
            let tint: Color = overdue
                ? (colorScheme == .dark ? Color(red: 0.86, green: 0.64, blue: 0.66) : Color(red: 0.65, green: 0.35, blue: 0.39))
                : palette.accent
            let seconds = Int(abs(due.timeIntervalSince(context.date)))
            let days = seconds / 86_400
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(record.title).font(.title3.bold()).foregroundStyle(.primary)
                        .lineLimit(typeSize.isAccessibilitySize ? nil : 2)
                        .fixedSize(horizontal: false, vertical: true)
                    if record.pinned { Image(systemName: "star.fill").font(.caption).foregroundStyle(.orange) }
                }
                Label {
                    Text(due, format: dueDateStyle)
                } icon: {
                    Image(systemName: "calendar.badge.clock")
                }.font(.caption).foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                        if days > 0 {
                            timeUnit(days, label: WorkspaceLocalization.string("天"), tint: tint)
                            timeUnit((seconds % 86_400) / 3600, label: WorkspaceLocalization.string("小时"), tint: tint)
                            timeUnit((seconds % 3600) / 60, label: WorkspaceLocalization.string("分"), tint: tint)
                        } else {
                            timeUnit(seconds / 3600, label: WorkspaceLocalization.string("小时"), tint: tint)
                            timeUnit((seconds % 3600) / 60, label: WorkspaceLocalization.string("分"), tint: tint)
                            timeUnit(seconds % 60, label: WorkspaceLocalization.string("秒"), tint: tint)
                        }
                }.padding(.top, 1)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(LinearGradient(colors: [tint.opacity(0.13), tint.opacity(0.018)], startPoint: .top, endPoint: .bottom))
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(record.title + (record.pinned ? WorkspaceLocalization.string("，星标") : ""))
            .accessibilityValue(WorkspaceLocalization.format("%@%@天 %@小时 %@分 %@秒，截止于%@", String(describing: overdue ? WorkspaceLocalization.string("已逾期") : WorkspaceLocalization.string("剩余")), String(describing: days), String(describing: (seconds % 86_400) / 3600), String(describing: (seconds % 3600) / 60), String(describing: seconds % 60), String(describing: due.formatted(dueDateStyle))))
        }
        .workspaceRecordDragSource(record)
    }
    private func timeUnit(_ value: Int, label: String, tint: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(value, format: .number.precision(.integerLength(2...)))
                .font(.system(size: countdownSize, weight: .heavy, design: .default).monospacedDigit())
                .foregroundStyle(tint)
                .lineLimit(1).minimumScaleFactor(0.5)
                .contentTransition(reduceMotion ? .identity : .numericText())
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }
    private var dueDateStyle: Date.FormatStyle {
        var style: Date.FormatStyle = record.dateOnly ? .dateTime.year().month().day().weekday() : .dateTime.month().day().weekday().hour().minute()
        style.locale = WorkspaceLocalization.locale
        style.timeZone = record.calendar.timeZone
        return style
    }
}
struct HomeSummaryRow: View {
    @Environment(\.workspacePalette) private var palette
    @Environment(\.dynamicTypeSize) private var typeSize
    let record: WorkspaceRecord
    var body: some View {
        HStack(alignment: typeSize.isAccessibilitySize ? .top : .center, spacing: 10) {
            Image(systemName: record.isFinished ? "checkmark.circle.fill" : record.pinned ? "star.fill" : record.kind.symbol)
                .foregroundStyle(record.isFinished ? Color.workspaceCompleted : record.pinned ? Color.orange : record.isOverdue ? Color.red : palette.accent)
                .frame(width: 24)
                .accessibilityLabel(record.pinned ? WorkspaceLocalization.string("星标") : record.kind.title)
            VStack(alignment: .leading, spacing: 3) {
                Text(record.title).font(.headline).foregroundStyle(record.isFinished ? Color.workspaceCompleted : Color.primary)
                    .lineLimit(typeSize.isAccessibilitySize ? nil : 2)
                    .fixedSize(horizontal: false, vertical: true)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) { supportingDetails }
                    VStack(alignment: .leading, spacing: 2) { supportingDetails }
                }
                .font(.caption).foregroundStyle(record.isOverdue ? .red : .secondary)
            }
        }.padding(.vertical, 2)
        .workspaceRecordDragSource(record)
    }
    @ViewBuilder private var supportingDetails: some View {
        Text(record.kind == .deadline ? WorkspaceLocalization.string("截止事项") : WorkspaceLocalization.string("事项")).fontWeight(.semibold)
        if record.isOverdue { Text(WorkspaceLocalization.string("已逾期")) }
        if let date = record.dueDate ?? record.remindAt ?? record.scheduledAt ?? record.targetDate {
            Text(date, format: rowDateStyle)
        }
    }
    private var rowDateStyle: Date.FormatStyle {
        var style: Date.FormatStyle = record.dateOnly && record.dueDate != nil ? .dateTime.month().day() : .dateTime.month().day().hour().minute()
        style.locale = WorkspaceLocalization.locale
        style.timeZone = record.calendar.timeZone
        return style
    }
}
struct CalendarEntry: Identifiable {
    let record: WorkspaceRecord
    let date: Date
    let label: String
    var id: String { "\(record.id)-\(label)" }
}
enum CalendarEntries {
    static func entries(_ state: WorkspaceState, from: Date? = nil, through: Date? = nil) -> [CalendarEntry] {
        let displayCalendar = WorkspaceDates.calendar(state.profile.timezone)
        func displayedDay(_ date: Date, record: WorkspaceRecord) -> Date {
            // Date-only values keep their calendar day when the workspace timezone changes.
            displayCalendar.date(from: record.calendar.dateComponents([.year, .month, .day], from: date)) ?? date
        }
        let records = from.flatMap { start in through.map { RecurrenceEngine.projectedRecords(in: state, from: start, through: $0) } } ?? state.records
        return WorkspaceRecordIndex(records).visibleRecords.flatMap { record -> [CalendarEntry] in
            var entries: [CalendarEntry] = []
            if let due = record.dueDate { entries.append(CalendarEntry(record: record, date: record.dateOnly ? displayedDay(due, record: record) : due, label: "截止")) }
            if let date = record.scheduledAt { entries.append(CalendarEntry(record: record, date: date, label: "计划")) }
            if let date = record.remindAt { entries.append(CalendarEntry(record: record, date: date, label: "提醒")) }
            if let date = record.startDate { entries.append(CalendarEntry(record: record, date: displayedDay(date, record: record), label: "分组开始")) }
            if let date = record.targetDate { entries.append(CalendarEntry(record: record, date: displayedDay(date, record: record), label: "分组目标")) }
            return entries
        }.sorted { $0.date < $1.date }
    }
}
struct ScheduleDateHeading: View {
    let month: String
    let day: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(month).font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
            Text(day).font(.title2.bold()).monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

struct ScheduleTodayButton: View {
    @Environment(\.workspacePalette) private var palette
    var large = false
    var hint = WorkspaceLocalization.string("回到今天")
    let action: () -> Void
    var body: some View {
        Button(WorkspaceLocalization.string("今天"), systemImage: "arrow.uturn.backward", action: action)
            .font(.subheadline.weight(.semibold))
            .buttonStyle(.bordered)
            .controlSize(large ? .large : .regular)
            .tint(palette.accent)
            .accessibilityHint(hint)
    }
}

struct WorkspaceCalendarView: View {
    @Environment(WorkspaceStore.self) private var store
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var selected = Date()
    @State private var displayedMonth = Date()
    var body: some View {
        let calendar = WorkspaceDates.calendar(store.state.profile.timezone)
        let month = calendar.dateInterval(of: .month, for: displayedMonth)
        let from = month.flatMap { calendar.date(byAdding: .day, value: -7, to: $0.start) }
        let through = month.flatMap { calendar.date(byAdding: .day, value: 7, to: $0.end) }
        let allEntries = CalendarEntries.entries(store.state, from: from, through: through)
        let entries = allEntries.filter { calendar.isDate($0.date, inSameDayAs: selected) }
        calendarContent(calendar: calendar, allEntries: allEntries, entries: entries)
            .navigationTitle(WorkspaceLocalization.string("日历"))
            .workspaceResponsiveTitle()
            .workspaceSelectionFeedback(trigger: selected)
    }
    @ViewBuilder private func calendarContent(calendar: Calendar, allEntries: [CalendarEntry], entries: [CalendarEntry]) -> some View {
        #if os(iOS)
        GeometryReader { geometry in
            if geometry.size.width >= 680 && !typeSize.isAccessibilitySize {
                HStack(spacing: 0) {
                    List {
                        dateHeading(calendar: calendar)
                        monthSection(calendar: calendar, entries: allEntries)
                    }
                        .contentMargins(.horizontal, 16, for: .scrollContent)
                        .contentMargins(.top, 8, for: .scrollContent)
                        .frame(width: geometry.size.width * 0.48)
                    List { agendaSection(calendar: calendar, entries: entries) }
                        .contentMargins(.horizontal, 16, for: .scrollContent)
                        .contentMargins(.top, 8, for: .scrollContent)
                }
                .accessibilityIdentifier("calendar-columns")
            } else {
                List {
                    dateHeading(calendar: calendar)
                    monthSection(calendar: calendar, entries: allEntries)
                    agendaSection(calendar: calendar, entries: entries)
                }
                .contentMargins(.top, 10, for: .scrollContent)
            }
        }
        #else
        GeometryReader { geometry in
            if geometry.size.width >= 720 {
                HSplitView {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 24) {
                            dateHeading(calendar: calendar)
                            WorkspaceMonthCalendar(selected: $selected, displayedMonth: $displayedMonth,
                                calendar: calendar, entries: allEntries)
                                .padding(20)
                                .background(.background, in: RoundedRectangle(cornerRadius: 20))
                        }
                        .padding(24)
                        .frame(maxWidth: 620)
                        .frame(maxWidth: .infinity)
                    }
                    .frame(minWidth: 350, idealWidth: 470)
                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            Label(WorkspaceLocalization.string("当天日程"), systemImage: "list.bullet.rectangle")
                                .font(.headline)
                            Spacer()
                            Text(entries.count, format: .number).foregroundStyle(.secondary)
                        }
                        .padding(20)
                        Divider()
                        List { agendaSection(calendar: calendar, entries: entries) }
                            .listStyle(.inset)
                    }
                    .frame(minWidth: 300, idealWidth: 400, maxWidth: .infinity)
                }
            } else {
                List {
                    dateHeading(calendar: calendar)
                    monthSection(calendar: calendar, entries: allEntries)
                    Section(WorkspaceLocalization.string("当天日程")) {
                        agendaRows(entries)
                    }
                }
                .listStyle(.inset)
            }
        }
        .background(.quaternary.opacity(0.22))
        .accessibilityIdentifier("mac-calendar-workspace")
        #endif
    }
    private func dateHeading(calendar: Calendar) -> some View {
        let style = Date.FormatStyle(date: .omitted, time: .omitted, locale: WorkspaceLocalization.locale, calendar: calendar, timeZone: calendar.timeZone)
        return HStack(spacing: 12) {
            ScheduleDateHeading(
                month: selected.formatted(style.year().month()),
                day: selected.formatted(style.day().weekday(.wide)))
            Spacer(minLength: 8)
            ScheduleTodayButton {
                let today = Date()
                selected = today
                displayedMonth = today
            }
        }
        .listRowInsets(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .accessibilityIdentifier("calendar-date-heading")
    }
    private func monthSection(calendar: Calendar, entries: [CalendarEntry]) -> some View {
        Section {
            WorkspaceMonthCalendar(selected: $selected, displayedMonth: $displayedMonth, calendar: calendar, entries: entries)
                .frame(maxWidth: 560).frame(maxWidth: .infinity)
        }
    }
    @ViewBuilder private func agendaSection(calendar: Calendar, entries: [CalendarEntry]) -> some View {
        #if os(macOS)
        agendaRows(entries)
        #else
        Section(WorkspaceLocalization.string("当天日程")) { agendaRows(entries) }
        #endif
    }
    @ViewBuilder private func agendaRows(_ entries: [CalendarEntry]) -> some View {
        if entries.isEmpty { Text(WorkspaceLocalization.string("这一天没有安排。")).foregroundStyle(.secondary) }
        ForEach(entries) { entry in
            NavigationLink {
                if store.record(entry.record.id) != nil { RecordDetailView(id: entry.record.id) }
                else { ProjectedCalendarOccurrenceView(record: entry.record) }
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(WorkspaceLocalization.string(entry.label)).font(.caption).foregroundStyle(.secondary)
                    RecordRow(record: entry.record)
                }
                #if os(macOS)
                .padding(.vertical, 6)
                #endif
            }
        }
    }
}
private struct WorkspaceMonthCalendar: View {
    @Environment(\.workspacePalette) private var palette
    @Binding var selected: Date
    @Binding var displayedMonth: Date
    let calendar: Calendar
    let entries: [CalendarEntry]
    @State private var choosingDate = false
    @State private var monthStepSequence = 0
    @ScaledMetric(relativeTo: .caption2) private var starSize = 8

    private struct DaySummary {
        var count: Int
        var hasStar: Bool
    }
    private var summaries: [Date: DaySummary] {
        var recordIDs: [Date: Set<UUID>] = [:]
        var result: [Date: DaySummary] = [:]
        for entry in entries where entry.record.kind.isItem || entry.record.kind == .deadline {
            let day = calendar.startOfDay(for: entry.date)
            let inserted = recordIDs[day, default: []].insert(entry.record.id).inserted
            var summary = result[day, default: DaySummary(count: 0, hasStar: false)]
            if inserted { summary.count += 1 }
            summary.hasStar = summary.hasStar || entry.record.isKeyItem
            result[day] = summary
        }
        return result
    }
    private var days: [Date] {
        guard let month = calendar.dateInterval(of: .month, for: displayedMonth),
              let count = calendar.range(of: .day, in: .month, for: displayedMonth)?.count else { return [] }
        let leading = (calendar.component(.weekday, from: month.start) - calendar.firstWeekday + 7) % 7
        let cells = ((leading + count + 6) / 7) * 7
        return (0..<cells).compactMap { calendar.date(byAdding: .day, value: $0 - leading, to: month.start) }
    }
    private var monthStyle: Date.FormatStyle {
        var style = Date.FormatStyle.dateTime.year().month(.wide)
        style.locale = WorkspaceLocalization.locale
        style.timeZone = calendar.timeZone
        return style
    }
    var body: some View {
        let daySummaries = summaries
        VStack(spacing: 16) {
            HStack {
                Button { changeMonth(-1) } label: {
                    Image(systemName: "chevron.left").frame(width: 44, height: 44)
                }.accessibilityLabel(WorkspaceLocalization.string("上个月"))
                Spacer(minLength: 0)
                Button { choosingDate = true } label: {
                    HStack(spacing: 6) {
                        Text(displayedMonth, format: monthStyle).font(.headline)
                        Image(systemName: "chevron.down").font(.caption2.weight(.semibold))
                    }.foregroundStyle(.primary)
                }.accessibilityHint(WorkspaceLocalization.string("选择其他日期或月份"))
                Spacer(minLength: 0)
                Button { changeMonth(1) } label: {
                    Image(systemName: "chevron.right").frame(width: 44, height: 44)
                }.accessibilityLabel(WorkspaceLocalization.string("下个月"))
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 6) {
                ForEach(1...7, id: \.self) { day in
                    Text(WorkspaceDates.weekdayName(day))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(day >= 6 ? Color.red : .secondary)
                        .lineLimit(1).minimumScaleFactor(0.6)
                        .frame(maxWidth: .infinity).padding(.bottom, 4)
                }
                ForEach(days, id: \.self) { day in
                    dayButton(day, summary: daySummaries[calendar.startOfDay(for: day)])
                }
            }
            HStack(spacing: 5) {
                Text(WorkspaceLocalization.string("日程少"))
                ForEach([0.14, 0.26, 0.38, 0.50, 0.62], id: \.self) { opacity in
                    RoundedRectangle(cornerRadius: 3).fill(palette.accent.opacity(opacity)).frame(width: 14, height: 10)
                }
                Text(WorkspaceLocalization.string("多"))
                Spacer(minLength: 4)
                Image(systemName: "star.fill").foregroundStyle(.orange)
            }
            .font(.caption2).foregroundStyle(.secondary)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(WorkspaceLocalization.string("颜色越深，日程越多；星星表示星标"))
        }
        .buttonStyle(.plain)
        .workspaceSelectionFeedback(trigger: monthStepSequence, feedback: .impact(weight: .medium, intensity: 0.8))
        .padding(.vertical, 4)
        .onChange(of: selected) { _, value in displayedMonth = value }
        .onChange(of: calendar.timeZone) { _, _ in displayedMonth = selected }
        .onAppear { displayedMonth = selected }
        .sheet(isPresented: $choosingDate) {
            NavigationStack {
                Form {
                    DatePicker(WorkspaceLocalization.string("查看日期"), selection: $selected, displayedComponents: .date)
                        .datePickerStyle(.graphical)
                        .environment(\.timeZone, calendar.timeZone)
                }
                .navigationTitle(WorkspaceLocalization.string("选择日期"))
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button(WorkspaceLocalization.string("完成")) { choosingDate = false } } }
            }.nativeSheetSize()
        }
    }
    private func changeMonth(_ offset: Int) {
        if let month = calendar.dateInterval(of: .month, for: displayedMonth)?.start,
           let next = calendar.date(byAdding: .month, value: offset, to: month) {
            displayedMonth = next
            monthStepSequence += 1
        }
    }
    private func dayButton(_ day: Date, summary: DaySummary?) -> some View {
        let isSelected = calendar.isDate(day, inSameDayAs: selected)
        let inMonth = calendar.isDate(day, equalTo: displayedMonth, toGranularity: .month)
        let count = summary?.count ?? 0
        let opacity = 0.02 + 0.12 * min(Double(count), 5)
        return Button { selected = day } label: {
            Text(calendar.component(.day, from: day), format: .number)
                .font(.body.weight(isSelected ? .bold : .regular).monospacedDigit())
                .lineLimit(1).minimumScaleFactor(0.6)
                .foregroundStyle(inMonth ? Color.primary : Color.secondary)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(palette.accent.opacity(opacity), in: RoundedRectangle(cornerRadius: 10))
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(isSelected ? palette.accent : calendar.isDateInToday(day) ? palette.accent.opacity(0.5) : .clear,
                                      lineWidth: isSelected ? 2 : 1)
                }
                .overlay(alignment: .topTrailing) {
                    if summary?.hasStar == true {
                        Image(systemName: "star.fill")
                            .font(.system(size: starSize, weight: .semibold))
                            .foregroundStyle(.orange).padding(4)
                    }
                }
                .opacity(inMonth ? 1 : 0.4)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(day.formatted(Date.FormatStyle(date: .complete, time: .omitted, locale: WorkspaceLocalization.locale, calendar: calendar, timeZone: calendar.timeZone)))
        .accessibilityValue(WorkspaceLocalization.format("%@ 项日程", String(describing: count)) + (summary?.hasStar == true ? WorkspaceLocalization.string("，有星标") : ""))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}
struct ProjectTimelineView: View {
    @Environment(\.workspacePalette) private var palette
    @Environment(WorkspaceStore.self) private var store
    var body: some View {
        let projects = store.projectGroupRecords.filter { $0.startDate != nil || $0.targetDate != nil }
        let calendar = WorkspaceDates.calendar(store.state.profile.timezone)
        let today = calendar.startOfDay(for: Date())
        let horizon = calendar.date(byAdding: .year, value: 3, to: today) ?? today.addingTimeInterval(365 * 3 * 86400)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                Text(WorkspaceLocalization.string("项目组时间线")).font(.title2.bold())
                if projects.isEmpty {
                    ContentUnavailableView(WorkspaceLocalization.string("还没有项目组时间线"), systemImage: "chart.bar.xaxis", description: Text(WorkspaceLocalization.string("为项目组设置开始或目标日期，即可在这里查看。")))
                } else {
                    Chart {
                        ForEach(projects) { project in
                            let start = project.startDate ?? today
                            let end = max(start.addingTimeInterval(86400), project.targetDate ?? start.addingTimeInterval(86400 * 14))
                            if start <= horizon { BarMark(xStart: .value(WorkspaceLocalization.string("开始"), start), xEnd: .value(WorkspaceLocalization.string("目标"), min(end, horizon)), y: .value(WorkspaceLocalization.string("项目组"), project.title))
                                .foregroundStyle(project.isFinished ? Color.workspaceCompleted : palette.accent)
                                .cornerRadius(4)
                            }
                        }
                        RuleMark(x: .value(WorkspaceLocalization.string("今天"), today)).foregroundStyle(.secondary).lineStyle(StrokeStyle(dash: [4, 4]))
                    }
                    .chartScrollableAxes(.horizontal)
                    .chartXVisibleDomain(length: 86400 * 60)
                    .frame(height: max(260, CGFloat(projects.count) * 50))
                    .accessibilityLabel(WorkspaceLocalization.string("项目组时间线，可横向滚动查看日期。"))
                    Text(WorkspaceLocalization.string("横向滚动查看日期。展示窗口最长三年，超出范围的目标日期仍保留在项目组详情中。")).font(.caption).foregroundStyle(.secondary)
                    ForEach(projects) { project in
                        NavigationLink { RecordDetailView(id: project.id) } label: { RecordRow(record: project) }
                    }
                }
            }.padding().frame(maxWidth: 1000).frame(maxWidth: .infinity)
        }.navigationTitle(WorkspaceLocalization.string("时间线"))
    }
}

#if os(macOS)
/// The desktop dashboard keeps frequent work visible beside the nearest deadlines.
private struct MacOverviewDashboard: View {
    @Environment(WorkspaceStore.self) private var store
    let nearest: [WorkspaceRecord]
    let pending: [WorkspaceRecord]
    let open: (UUID) -> Void

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: geometry.size.width >= 900 ? 26 : 20) {
                    let headerLayout = geometry.size.width >= 850
                        ? AnyLayout(HStackLayout(alignment: .top, spacing: 20))
                        : AnyLayout(VStackLayout(alignment: .leading, spacing: 16))
                    headerLayout {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(WorkspaceLocalization.string("今天，从这里开始"))
                                .font(geometry.size.width >= 850 ? .largeTitle.bold() : .title.bold())
                            Text(Date(), format: Date.FormatStyle(date: .complete, time: .omitted,
                                calendar: WorkspaceDates.calendar(store.state.profile.timezone),
                                timeZone: WorkspaceDates.calendar(store.state.profile.timezone).timeZone))
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        HStack(spacing: 8) {
                            Button(WorkspaceLocalization.string("新建事项"), systemImage: "plus") { store.createKind = .task }
                                .buttonStyle(.borderedProminent)
                            Button(WorkspaceLocalization.string("新建截止事项"), systemImage: "hourglass.badge.plus") { store.createKind = .deadline }
                                .buttonStyle(.bordered)
                        }
                        .disabled(store.isReadOnlyWorkspace)
                        .controlSize(.large)
                    }
                    if geometry.size.width >= 850 {
                        HStack(alignment: .top, spacing: 24) {
                            pendingPanel.frame(maxWidth: .infinity)
                            deadlinePanel.frame(width: min(410, geometry.size.width * 0.41))
                        }
                    } else {
                        deadlinePanel
                        pendingPanel
                    }
                }
                .padding(geometry.size.width >= 900 ? 28 : 20)
                .frame(maxWidth: 1440)
                .frame(maxWidth: .infinity)
            }
            .background(.quaternary.opacity(0.22))
        }
        .accessibilityIdentifier("mac-overview-dashboard")
    }

    private var pendingPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(WorkspaceLocalization.string("事项"), systemImage: "checklist").font(.title3.bold())
                Text(pending.count, format: .number).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                Spacer()
                Button(WorkspaceLocalization.string("全部事项"), systemImage: "arrow.up.right") { store.navigation = .actions }
                    .buttonStyle(.borderless)
            }
            VStack(spacing: 0) {
                if pending.isEmpty {
                    ContentUnavailableView(WorkspaceLocalization.string("暂时没有事项。"), systemImage: "checkmark.circle",
                        description: Text(WorkspaceLocalization.string("新建一条事项，开始今天的安排。")))
                        .padding(.vertical, 20)
                } else {
                    ForEach(pending.prefix(10)) { record in
                        Button { open(record.id) } label: {
                            HStack(spacing: 12) {
                                HomeSummaryRow(record: record)
                                Spacer(minLength: 8)
                                Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 18).padding(.vertical, 11)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(MacDashboardRowButtonStyle())
                        if record.id != pending.prefix(10).last?.id {
                            Divider().padding(.leading, 52)
                        }
                    }
                }
            }
            .background(.background, in: RoundedRectangle(cornerRadius: 20))
            .overlay { RoundedRectangle(cornerRadius: 20).strokeBorder(.primary.opacity(0.05)) }
        }
    }

    private var deadlinePanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(WorkspaceLocalization.string("最近截止"), systemImage: "hourglass").font(.title3.bold())
                Text(nearest.count, format: .number).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                Spacer()
                Button(WorkspaceLocalization.string("全部"), systemImage: "arrow.up.right") { store.navigation = .deadlines }
                    .buttonStyle(.borderless)
            }
            if nearest.isEmpty {
                ContentUnavailableView(WorkspaceLocalization.string("没有临近的截止事项"), systemImage: "calendar.badge.checkmark")
                    .frame(maxWidth: .infinity).padding(.vertical, 28)
                    .background(.background, in: RoundedRectangle(cornerRadius: 20))
            } else {
                DeadlineCountdownSurface {
                    ForEach(nearest) { record in
                        Button { open(record.id) } label: { HomeDeadlineCard(record: record) }
                            .buttonStyle(MacDashboardRowButtonStyle())
                    }
                }
            }
        }
    }
}

/// A restrained row highlight makes the whole card discoverable to a mouse or trackpad.
private struct MacDashboardRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HighlightedRow(configuration: configuration)
    }

    private struct HighlightedRow: View {
        let configuration: ButtonStyle.Configuration
        @Environment(\.workspacePalette) private var palette
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var hovering = false

        var body: some View {
            configuration.label
                .overlay {
                    palette.accent.opacity(configuration.isPressed ? 0.13 : hovering ? 0.07 : 0)
                        .allowsHitTesting(false)
                }
                .onHover { hovering = $0 }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovering)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: configuration.isPressed)
        }
    }
}

/// Mouse and keyboard selection share the same read-only event projection as iPhone.
struct MacWorkspaceTimelineView: View {
    @Environment(WorkspaceStore.self) private var store
    @State private var showsProjects = false
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker(WorkspaceLocalization.string("时间线内容"), selection: $showsProjects) {
                    Text(WorkspaceLocalization.string("事项")).tag(false)
                    Text(WorkspaceLocalization.string("项目组")).tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
                Spacer()
            }
            .padding(.horizontal, 24).padding(.vertical, 14)
            Divider()
            if showsProjects { ProjectTimelineView() }
            else {
                // Search and selection belong to the child. Typing must not
                // re-sort and format every event in the whole workspace.
                MacTimelineItemsView(presentation: TimelinePresentation(records: store.state.records,
                    timezone: store.state.profile.timezone))
            }
        }
        .navigationTitle(WorkspaceLocalization.string("时间线"))
    }
}

private struct MacTimelineItemsView: View {
    @Environment(WorkspaceStore.self) private var store
    let presentation: TimelinePresentation
    @State private var selection: UUID?
    @State private var query = ""
    @State private var todayRequest = 0
    @State private var detailPresentationActive = false
    @AppStorage("macShowRecordDetails") private var showsDetails = true
    private enum FocusTarget: Hashable { case search, events }
    @FocusState private var focus: FocusTarget?

    var body: some View {
        GeometryReader { geometry in
            let inlineDetails = (showsDetails && geometry.size.width >= 760) || detailPresentationActive
            HSplitView {
                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        TextField(WorkspaceLocalization.string("搜索日程或项目组"), text: $query)
                            .textFieldStyle(.roundedBorder)
                            .focused($focus, equals: .search)
                            .onSubmit {
                                selection = presentation.groups.lazy.flatMap(\.events).first(where: matches)?.id
                                focus = .events
                            }
                            .onExitCommand {
                                query = ""
                                focus = .events
                            }
                            .accessibilityLabel(WorkspaceLocalization.string("搜索时间线"))
                        if !query.isEmpty {
                            Button {
                                query = ""
                                focus = .search
                            } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                            }
                            .buttonStyle(.borderless)
                            .help(WorkspaceLocalization.string("清除搜索"))
                            .accessibilityLabel(WorkspaceLocalization.string("清除搜索"))
                        }
                        ScheduleTodayButton(hint: WorkspaceLocalization.string("选中并滚动到今天附近的日程")) {
                            query = ""
                            selection = currentEvent(presentation)
                            todayRequest += 1
                            focus = .events
                        }
                        .disabled(presentation.groups.isEmpty)
                    }
                    .padding(16)
                    Divider()
                    eventList(presentation)
                }
                .frame(minWidth: min(330, geometry.size.width), idealWidth: 440,
                       maxWidth: inlineDetails ? 650 : .infinity)
                if inlineDetails {
                    NavigationStack {
                        if let selection, store.record(selection) != nil {
                            RecordDetailView(id: selection, embedded: true,
                                presentationChanged: { detailPresentationActive = $0 })
                        } else {
                            ContentUnavailableView(WorkspaceLocalization.string("选择一项日程"), systemImage: "clock",
                                description: Text(WorkspaceLocalization.string("在左侧选择日程，即可在此查看和处理。")))
                        }
                    }
                    .id(selection)
                    .frame(minWidth: 350, maxWidth: .infinity)
                }
            }
        }
        .toolbar {
            ToolbarItem {
                Button(WorkspaceLocalization.string("搜索时间线"), systemImage: "magnifyingglass") { focus = .search }
                    .keyboardShortcut("f")
                    .help(WorkspaceLocalization.string("搜索时间线") + "（⌘F）")
            }
            ToolbarItem {
                Button(WorkspaceLocalization.string("查看详情"), systemImage: "arrow.up.right.square") { openSelection() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(selection == nil)
                    .help(WorkspaceLocalization.string("查看详情") + "（⌘↩）")
            }
        }
        .onAppear {
            if selection == nil { selection = currentEvent(presentation) }
        }
        .onChange(of: presentation) { _, value in
            reconcileSelection(in: value)
        }
        .onChange(of: query) { _, _ in reconcileSelection(in: presentation) }
        .onChange(of: detailPresentationActive) { _, active in
            if !active { reconcileSelection(in: presentation) }
        }
        .accessibilityIdentifier("mac-timeline-workspace")
    }

    private func eventList(_ presentation: TimelinePresentation) -> some View {
        let matchingGroups = presentation.groups.filter { group in group.events.contains(where: matches) }
        return ScrollViewReader { proxy in
            List(selection: $selection) {
                ForEach(matchingGroups) { group in
                    Section {
                        ForEach(group.events.filter(matches)) { event in
                            MacTimelineEventRow(event: event).tag(event.id).id(event.id)
                        }
                    } header: {
                        HStack {
                            Text(group.dayLabel).fontWeight(.semibold)
                            Spacer()
                            Text(group.timeLabel).monospacedDigit()
                        }
                        .padding(.top, 10)
                    }
                }
            }
            .listStyle(.inset)
            .focused($focus, equals: .events)
            .contextMenu(forSelectionType: UUID.self) { ids in
                if let id = ids.first {
                    Button(WorkspaceLocalization.string("查看详情"), systemImage: "arrow.up.right.square") { store.openedRecordID = id }
                }
            } primaryAction: { ids in
                if let id = ids.first, store.record(id) != nil { store.openedRecordID = id }
            }
            .overlay {
                if matchingGroups.isEmpty {
                    ContentUnavailableView(query.isEmpty ? WorkspaceLocalization.string("还没有日程") : WorkspaceLocalization.string("没有匹配的日程"),
                        systemImage: query.isEmpty ? "calendar" : "magnifyingglass",
                        description: Text(query.isEmpty ? WorkspaceLocalization.string("为事项设置时间后，即可在这里查看。") : WorkspaceLocalization.string("试试其他标题或项目组名称。")))
                }
            }
            .onChange(of: selection) { _, value in
                if let value { proxy.scrollTo(value) }
            }
            .task(id: todayRequest) {
                // Wait for the native list to lay out its rows, including after clearing search.
                await Task.yield()
                guard !Task.isCancelled, let id = selection ?? currentEvent(presentation) else { return }
                proxy.scrollTo(id, anchor: .center)
            }
        }
    }

    private func matches(_ event: TimelinePresentation.Event) -> Bool {
        query.isEmpty || event.title.localizedStandardContains(query)
            || event.projectTitle?.localizedStandardContains(query) == true
    }

    private func currentEvent(_ presentation: TimelinePresentation) -> UUID? {
        guard !presentation.groups.isEmpty else { return nil }
        return presentation.groups[presentation.initialIndex()].events.first?.id
    }

    private func reconcileSelection(in presentation: TimelinePresentation) {
        // A sync may change a title while its editor is open. Keep the editor's
        // owner alive and apply the current filter after its sheet has closed.
        guard !detailPresentationActive, let selection else { return }
        let remainsVisible = presentation.groups.contains { group in
            group.events.contains { $0.id == selection && matches($0) }
        }
        if !remainsVisible { self.selection = nil }
    }

    private func openSelection() {
        guard let selection, store.record(selection) != nil else { return }
        store.openedRecordID = selection
    }
}

private struct MacTimelineEventRow: View {
    @Environment(WorkspaceStore.self) private var store
    @Environment(\.workspacePalette) private var palette
    let event: TimelinePresentation.Event
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 6) {
                Circle().fill(event.finished ? Color.workspaceCompleted : event.overdue ? .red : palette.accent)
                    .frame(width: 8, height: 8)
                RoundedRectangle(cornerRadius: 1).fill(.secondary.opacity(0.18))
                    .frame(width: 2, height: 34)
            }
            .padding(.top, 5)
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(event.timeLabel).font(.subheadline.weight(.semibold).monospacedDigit())
                        .foregroundStyle(event.overdue && !event.finished ? Color.red : palette.accent)
                    if event.deadline { Image(systemName: "hourglass").foregroundStyle(.secondary).font(.caption) }
                    Spacer(minLength: 8)
                    if event.pinned {
                        Image(systemName: "star.fill")
                            .foregroundStyle(event.finished ? Color.workspaceCompleted : Color.orange)
                            .accessibilityLabel(WorkspaceLocalization.string("星标"))
                    }
                }
                Text(event.title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(event.finished ? Color.workspaceCompleted : Color.primary)
                    .fixedSize(horizontal: false, vertical: true)
                if let project = event.projectTitle {
                    Text(project).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(event.accessibilityLabel)
        .workspaceRecordDragSource(store.record(event.id))
    }
}
#endif
