import SwiftUI

struct RecordEditorView: View {
    @Environment(WorkspaceStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var draft: WorkspaceRecord
    private enum Field: Hashable { case title, summary, body, category, tags }
    @FocusState private var focusedField: Field?
    @State private var previewing = false
    @State private var confirmed = false
    @State private var localError: String?
    @State private var repeats = false
    @State private var creationPreferencesApplied = false
    @State private var addingCategory = false
    @State private var customCategory = ""
    @State private var moreOptionsExpanded = false
    @State private var recurrenceRule = RecurrenceRule(frequency: .daily)
    private let expectedVersion: Int?
    private let originalStatus: String?
    private let isProjectedOccurrence: Bool
    private let isKindConversion: Bool
    init(kind: ItemKind, record: WorkspaceRecord? = nil, projectID: UUID? = nil, areaID: UUID? = nil,
         isProjectedOccurrence: Bool = false, isKindConversion: Bool = false) {
        var value = record ?? WorkspaceRecord(kind: kind.creationKind)
        if record == nil { value.projectID = projectID; value.areaID = areaID }
        if record == nil && kind == .deadline { value.dueDate = Date().addingTimeInterval(86400) }
        if isKindConversion && value.kind == .deadline && value.dueDate == nil {
            value.dueDate = value.scheduledAt ?? Date().addingTimeInterval(86400)
            if value.scheduledAt != nil { value.dateOnly = false }
        }
        self.isKindConversion = isKindConversion
        _draft = State(initialValue: value); expectedVersion = isProjectedOccurrence ? nil : record?.version
        originalStatus = record?.status; self.isProjectedOccurrence = isProjectedOccurrence
    }
    var body: some View {
        editorContent
        .navigationTitle((isKindConversion ? WorkspaceLocalization.string("转为") : expectedVersion == nil && !isProjectedOccurrence ? WorkspaceLocalization.string("新建") : WorkspaceLocalization.string("编辑")) + draft.kind.title)
        .toolbar {
            #if os(iOS)
            ToolbarItemGroup(placement: .keyboard) { Spacer(); Button(WorkspaceLocalization.string("完成")) { focusedField = nil } }
            #endif
            ToolbarItem(placement: .cancellationAction) { Button(WorkspaceLocalization.string("取消")) { dismiss() }.keyboardShortcut(.cancelAction) }
            ToolbarItem(placement: .confirmationAction) {
                Button(isKindConversion ? WorkspaceLocalization.string("转换") : WorkspaceLocalization.string("保存")) {
                    do { try store.save(draft, expectedVersion: expectedVersion, confirmRemaining: confirmed,
                        recurrenceRule: repeats ? recurrenceRule : nil); dismiss() }
                    catch { localError = error.localizedDescription }
                }.disabled(draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                    (draft.kind == .deadline && draft.dueDate == nil) ||
                    (repeats && RecurrenceEngine.validationError(record: draft, rule: recurrenceRule) != nil)).keyboardShortcut("s")
            }
        }
        .nativeEditorPresentation()
        .workspaceInlineTitle()
        .workspaceSelectionFeedback(trigger: draft.status)
        .workspaceSelectionFeedback(trigger: draft.projectID)
        .workspaceSelectionFeedback(trigger: draft.areaID)
        .workspaceSelectionFeedback(trigger: draft.pinned, feedback: .impact(weight: .medium, intensity: 1))
        .workspaceSelectionFeedback(trigger: draft.dateOnly)
        .workspaceSelectionFeedback(trigger: draft.notificationsEnabled)
        .workspaceSelectionFeedback(trigger: draft.notificationLeadMinutes)
        .workspaceSelectionFeedback(trigger: previewing)
        .workspaceSelectionFeedback(trigger: repeats)
        .workspaceSelectionFeedback(trigger: moreOptionsExpanded)
        .sensoryFeedback(.error, trigger: localError) { _, value in store.hapticsEnabled && value != nil }
        .scrollDismissesKeyboard(.interactively)
        .alert(WorkspaceLocalization.string("新建分类"), isPresented: $addingCategory) {
            TextField(WorkspaceLocalization.string("分类名称"), text: $customCategory)
            Button(WorkspaceLocalization.string("取消"), role: .cancel) { }
            Button(WorkspaceLocalization.string("添加")) { addCustomCategory() }
                .disabled(customCategory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || customCategory.utf16.count > 240)
        }
        .task {
            if expectedVersion == nil && !isProjectedOccurrence && !isKindConversion && !creationPreferencesApplied {
                store.applyCreationPreferences(to: &draft)
                draft.timezone = store.state.profile.timezone
                creationPreferencesApplied = true
            }
            if expectedVersion == nil && !isProjectedOccurrence {
                // Wait until the sheet's navigation and keyboard toolbar are installed.
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled else { return }
                focusedField = .title
            }
        }
    }
    @ViewBuilder private var editorContent: some View {
        #if os(iOS)
        GeometryReader { geometry in
            if geometry.size.width >= 680 && !dynamicTypeSize.isAccessibilitySize {
                HStack(alignment: .top, spacing: 0) {
                    Form {
                        identitySection
                        relationshipSection
                        if draft.kind == .knowledge { knowledgeInfoSection }
                        else { contentSection }
                        confirmationAndErrorSections
                    }
                    .formStyle(.grouped)
                    .contentMargins(.leading, 16, for: .scrollContent)
                    .contentMargins(.trailing, 8, for: .scrollContent)
                    .contentMargins(.top, 12, for: .scrollContent)
                    .scrollDismissesKeyboard(.interactively)
                    .frame(width: geometry.size.width * 0.48)
                    .accessibilityIdentifier("record-editor-content-pane")
                    Form {
                        if draft.kind == .knowledge { knowledgeBodySection }
                        else {
                            dateSection
                            notificationSection
                            recurrenceSection
                        }
                    }
                    .formStyle(.grouped)
                    .contentMargins(.leading, 8, for: .scrollContent)
                    .contentMargins(.trailing, 16, for: .scrollContent)
                    .contentMargins(.top, 12, for: .scrollContent)
                    .scrollDismissesKeyboard(.interactively)
                    .accessibilityIdentifier("record-editor-arrangement-pane")
                }
                .background(Color(.systemGroupedBackground))
            } else {
                compactForm
            }
        }
        #else
        compactForm
        #endif
    }
    private var compactForm: some View {
        Form {
            identitySection
            relationshipSection
            dateSection
            notificationSection
            recurrenceSection
            contentSection
            confirmationAndErrorSections
        }
        .formStyle(.grouped)
    }
    @ViewBuilder private var confirmationAndErrorSections: some View {
        if draft.kind == .project && draft.status == "COMPLETED" && originalStatus != "COMPLETED" {
            Section { Toggle(WorkspaceLocalization.string("确认完成项目组（保留未完成事项）"), isOn: $confirmed) }
        }
        if let localError { Section { Text(localError).foregroundStyle(.red) } }
    }
    private var identitySection: some View {
        Section {
            TextField(WorkspaceLocalization.string("标题"), text: $draft.title, axis: .vertical).focused($focusedField, equals: .title)
            starToggle
        }
    }
    @ViewBuilder private var additionalFields: some View {
        if expectedVersion != nil || isProjectedOccurrence, let completedStatus = draft.kind.completedStatus {
            Toggle(WorkspaceLocalization.string("已完成"), isOn: Binding(get: { draft.isFinished }, set: { completed in
                draft.status = completed ? completedStatus : draft.kind.incompleteStatus
            })).tint(.workspaceCompleted)
        }
        if draft.kind.isProjectGroup {
            Picker(WorkspaceLocalization.string("分类"), selection: $draft.projectKind) {
                Text(WorkspaceLocalization.string("无分类")).tag("")
                ForEach(Array(Set(store.projectCategoryKeys + [draft.projectKind])).filter { !$0.isEmpty }.sorted(), id: \.self) { key in
                    Text(projectKindLabel(key)).tag(key)
                }
            }
            Button(WorkspaceLocalization.string("添加分类…"), systemImage: "plus") { customCategory = ""; addingCategory = true }
                .disabled(store.preferences.customProjectCategories.count >= 50)
            optionalDate(WorkspaceLocalization.string("开始日期"), date: $draft.startDate, time: false)
            optionalDate(WorkspaceLocalization.string("目标日期"), date: $draft.targetDate, time: false)
        }
        timezoneField
        TextField(WorkspaceLocalization.string("简短说明"), text: $draft.summary, axis: .vertical).focused($focusedField, equals: .summary)
        TextField(WorkspaceLocalization.string("详细备注"), text: $draft.body, axis: .vertical)
            .focused($focusedField, equals: .body).lineLimit(3...8)
    }
    private var starToggle: some View {
        Toggle(isOn: $draft.pinned) {
            Label {
                Text(WorkspaceLocalization.string("星标"))
            } icon: {
                Image(systemName: "star.fill").foregroundStyle(.orange)
            }
        }
    }
    @ViewBuilder private var relationshipSection: some View {
        if draft.kind.isItem || draft.kind == .deadline || draft.kind.isProjectGroup {
            Section {
                RecordGroupSelectionFields(recordID: draft.id, isProjectGroup: draft.kind.isProjectGroup,
                    projectID: $draft.projectID, areaID: $draft.areaID, milestoneID: $draft.milestoneID)
            }
        }
    }
    @ViewBuilder private var dateSection: some View {
        if draft.kind.isItem || draft.kind == .deadline {
            Section {
                if draft.kind.isItem {
                    optionalDate(WorkspaceLocalization.string("计划时间"), date: $draft.scheduledAt, time: true)
                }
                if draft.kind != .deadline { Toggle(WorkspaceLocalization.string("有完成期限"), isOn: presence($draft.dueDate)) }
                if draft.dueDate != nil || draft.kind == .deadline {
                    Toggle(WorkspaceLocalization.string("全天"), isOn: $draft.dateOnly)
                    DatePicker(WorkspaceLocalization.string("截止"), selection: date($draft.dueDate), displayedComponents: draft.dateOnly ? .date : [.date, .hourAndMinute])
                        .environment(\.timeZone, draft.calendar.timeZone)
                }
            } header: {
                Text(WorkspaceLocalization.string("时间"))
            }
        }
    }
    private var timezoneField: some View {
        DisclosureGroup {
            Picker(WorkspaceLocalization.string("选择时区"), selection: $draft.timezone) {
                ForEach(timezoneChoices, id: \.self) { Text($0).tag($0) }
            }
        } label: {
            LabeledContent(WorkspaceLocalization.string("时区"), value: draft.timezone)
        }
    }
    @ViewBuilder private var notificationSection: some View {
        if draft.kind.isItem || draft.kind == .deadline {
            Section {
                Toggle(WorkspaceLocalization.string("提醒"), isOn: $draft.notificationsEnabled)
                if draft.notificationsEnabled {
                    Picker(draft.remindAt != nil ? WorkspaceLocalization.string("提醒时间") : draft.dueDate != nil ? WorkspaceLocalization.string("截止前提醒") : draft.scheduledAt != nil ? WorkspaceLocalization.string("计划前提醒") : WorkspaceLocalization.string("提醒时间"), selection: notificationTiming) {
                        Text(WorkspaceLocalization.string("准时")).tag(0); Text(WorkspaceLocalization.string("提前 5 分钟")).tag(5); Text(WorkspaceLocalization.string("提前 15 分钟")).tag(15)
                        Text(WorkspaceLocalization.string("提前 30 分钟")).tag(30); Text(WorkspaceLocalization.string("提前 1 小时")).tag(60); Text(WorkspaceLocalization.string("提前 1 天")).tag(1440)
                        if ![0, 5, 15, 30, 60, 1440].contains(draft.notificationLeadMinutes) {
                            Text(WorkspaceLocalization.format("提前 %@ 分钟", String(describing: draft.notificationLeadMinutes))).tag(draft.notificationLeadMinutes)
                        }
                        Text(WorkspaceLocalization.string("指定时间…")).tag(-1)
                    }
                    if draft.remindAt != nil {
                        DatePicker(WorkspaceLocalization.string("通知时间"), selection: date($draft.remindAt), displayedComponents: [.date, .hourAndMinute])
                            .environment(\.timeZone, draft.calendar.timeZone)
                    }
                    if let at = draft.notificationDate {
                        LabeledContent(WorkspaceLocalization.string("将于")) { Text(at, format: notificationDateStyle) }
                    } else {
                        Text(WorkspaceLocalization.string("设置计划或截止时间，或选择指定时间。"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let snooze = draft.snoozedUntil {
                        LabeledContent(WorkspaceLocalization.string("稍后提醒"), value: snooze.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, locale: WorkspaceLocalization.locale)))
                        Button(WorkspaceLocalization.string("清除稍后提醒")) { draft.snoozedUntil = nil }
                    }
                }
            }
        }
    }
    private var notificationTiming: Binding<Int> {
        Binding(get: { draft.remindAt == nil ? draft.notificationLeadMinutes : -1 }, set: { minutes in
            if minutes == -1 {
                draft.remindAt = draft.remindAt ?? draft.notificationDate ?? Date()
            } else {
                draft.remindAt = nil
                draft.notificationLeadMinutes = minutes
            }
        })
    }
    private var notificationDateStyle: Date.FormatStyle {
        var style = Date.FormatStyle.dateTime.month().day().hour().minute()
        style.locale = WorkspaceLocalization.locale
        style.timeZone = draft.calendar.timeZone
        return style
    }
    @ViewBuilder private var recurrenceSection: some View {
        if draft.kind.isItem || draft.kind == .deadline {
            if draft.recurrenceSeriesID != nil {
                Section {
                    DisclosureGroup(WorkspaceLocalization.string("重复事项")) {
                        Text(WorkspaceLocalization.string("当前修改只影响这一次。可在详情中管理重复规则。"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else if !draft.isFinished {
                Section { Toggle(WorkspaceLocalization.string("重复"), isOn: $repeats) }
                if repeats { RecurrenceRuleFields(rule: $recurrenceRule, record: draft) }
            }
        }
    }
    @ViewBuilder private var contentSection: some View {
        if draft.kind == .knowledge {
            knowledgeInfoSection
            knowledgeBodySection
        } else {
            Section {
                Button {
                    withAnimation(reduceMotion ? nil : .snappy(duration: 0.22)) {
                        moreOptionsExpanded.toggle()
                    }
                } label: {
                    HStack {
                        Text(WorkspaceLocalization.string("更多选项"))
                        Spacer(minLength: 12)
                        Image(systemName: "chevron.down")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(moreOptionsExpanded ? 180 : 0))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("record-editor-more-options")
                .accessibilityValue(moreOptionsExpanded ? WorkspaceLocalization.string("已展开") : WorkspaceLocalization.string("已收起"))
                if moreOptionsExpanded { additionalFields }
            }
        }
    }
    private var knowledgeInfoSection: some View {
        Section(WorkspaceLocalization.string("笔记信息")) {
            TextField(WorkspaceLocalization.string("摘要"), text: $draft.summary, axis: .vertical).focused($focusedField, equals: .summary)
            TextField(WorkspaceLocalization.string("分类"), text: $draft.category).focused($focusedField, equals: .category)
            TextField(WorkspaceLocalization.string("标签（逗号分隔）"), text: Binding(get: { draft.tags.joined(separator: ", ") }, set: {
                draft.tags = Array(Set($0.replacingOccurrences(of: "，", with: ",").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })).sorted()
            })).focused($focusedField, equals: .tags)
        }
    }
    private var knowledgeBodySection: some View {
        Section(WorkspaceLocalization.string("Markdown 正文")) {
            Picker(WorkspaceLocalization.string("正文模式"), selection: $previewing) { Text(WorkspaceLocalization.string("编辑")).tag(false); Text(WorkspaceLocalization.string("预览")).tag(true) }.pickerStyle(.segmented)
            if previewing { MarkdownDocumentView(source: draft.body) }
            else { TextEditor(text: $draft.body).focused($focusedField, equals: .body).font(.body.monospaced()).frame(minHeight: 280) }
        }
    }
    @ViewBuilder private func optionalDate(_ title: String, date value: Binding<Date?>, time: Bool) -> some View {
        Toggle(title, isOn: presence(value))
        if value.wrappedValue != nil {
            DatePicker(title, selection: date(value), displayedComponents: time ? [.date, .hourAndMinute] : .date)
                .environment(\.timeZone, draft.calendar.timeZone)
        }
    }
    private func presence(_ value: Binding<Date?>) -> Binding<Bool> {
        Binding(get: { value.wrappedValue != nil }, set: { value.wrappedValue = $0 ? value.wrappedValue ?? Date() : nil })
    }
    private func date(_ value: Binding<Date?>) -> Binding<Date> {
        Binding(get: { value.wrappedValue ?? Date() }, set: { value.wrappedValue = $0 })
    }
    private func addCustomCategory() {
        let value = customCategory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf16.count <= 240,
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            localError = WorkspaceLocalization.string("请使用有效的分类名称。"); return
        }
        if let existing = store.projectCategoryKeys.first(where: { $0 == value || projectKindLabel($0) == value }) {
            draft.projectKind = existing
        } else {
            guard store.preferences.customProjectCategories.count < 50 else { return }
            store.preferences.customProjectCategories.append(value)
            draft.projectKind = value
        }
    }
    private var timezoneChoices: [String] { Array(Set([draft.timezone, "Asia/Shanghai", "Asia/Tokyo", "Europe/London", "America/New_York", TimeZone.current.identifier])).sorted() }
}

/// Parent choices observe the workspace and relationship fields, not every keystroke in the editor.
private struct RecordGroupSelectionFields: View {
    @Environment(WorkspaceStore.self) private var store
    let recordID: UUID
    let isProjectGroup: Bool
    @Binding var projectID: UUID?
    @Binding var areaID: UUID?
    @Binding var milestoneID: UUID?

    var body: some View {
        Picker(WorkspaceLocalization.string("所属项目组"), selection: groupSelection) {
            Text(isProjectGroup ? WorkspaceLocalization.string("无（顶层项目组）") : WorkspaceLocalization.string("无（独立事项）")).tag(UUID?.none)
            ForEach(parentGroupChoices) { Text($0.title).tag(Optional($0.id)) }
        }
        if let related = milestoneID.flatMap(store.record) {
            DisclosureGroup(WorkspaceLocalization.string("关联事项：") + related.title) {
                Button(WorkspaceLocalization.string("解除事项关联")) { milestoneID = nil }
            }
        }
    }

    private var parentGroupChoices: [WorkspaceRecord] {
        guard isProjectGroup else { return store.projectGroupRecords }
        var children: [UUID: [UUID]] = [:]
        for record in store.state.records {
            for parent in [record.projectID, record.areaID].compactMap({ $0 }) {
                children[parent, default: []].append(record.id)
            }
        }
        var excluded: Set<UUID> = [recordID]
        var pending = [recordID]
        while let parent = pending.popLast() {
            for child in children[parent] ?? [] where excluded.insert(child).inserted {
                pending.append(child)
            }
        }
        return store.projectGroupRecords.filter { !excluded.contains($0.id) }
    }

    private var groupSelection: Binding<UUID?> {
        Binding(get: { projectID ?? areaID }, set: { id in
            let group = id.flatMap(store.record)
            let selectedProjectID = group?.kind == .project ? id : nil
            if projectID != selectedProjectID { milestoneID = nil }
            projectID = selectedProjectID
            areaID = group?.kind == .area ? id : nil
        })
    }
}

func projectKindLabel(_ key: String) -> String {
    ["": WorkspaceLocalization.string("无分类"), "RESEARCH": WorkspaceLocalization.string("科研"), "PAPER": WorkspaceLocalization.string("论文"), "VERTICAL_PROJECT": WorkspaceLocalization.string("纵向项目"), "INDUSTRY_PROJECT": WorkspaceLocalization.string("横向项目"),
     "LEARNING": WorkspaceLocalization.string("学习"), "ADMINISTRATIVE": WorkspaceLocalization.string("日常事务"), "PERSONAL": WorkspaceLocalization.string("个人"), "LIFE": WorkspaceLocalization.string("生活")][key] ?? key
}
