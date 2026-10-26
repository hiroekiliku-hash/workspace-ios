import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#endif

struct RecordDetailView: View {
    @Environment(\.workspacePalette) private var palette
    @Environment(WorkspaceStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    let id: UUID
    var embedded = false
    var presentationChanged: ((Bool) -> Void)? = nil
    @State private var editing = false
    @State private var recurrence = false
    @State private var preview: DeletionPreview?
    @State private var pickingPDF = false
    @State private var childKind: ItemKind?
    @State private var convertingRecord: WorkspaceRecord?
    @State private var completionArmedFor: UUID?
    @State private var completionRequest: WorkspaceRecord?
    @State private var completedRecordID: UUID?
    #if os(iOS)
    @Environment(\.colorScheme) private var colorScheme
    @State private var completionPresenter = WorkspaceCompletionWindowPresenter()
    #endif
    private var isPresentingDetailModal: Bool {
        editing || recurrence || preview != nil || pickingPDF || childKind != nil || convertingRecord != nil || completionRequest != nil
    }
    var body: some View {
        Group {
            if let record = store.record(id), record.deletedAt == nil {
                titledDetail(record)
                    .sheet(isPresented: $editing) { NavigationStack { RecordEditorView(kind: record.kind, record: record) }.nativeEditorPresentation() }
                    .sheet(item: $convertingRecord) { draft in
                        NavigationStack {
                            RecordEditorView(kind: draft.kind, record: draft, isKindConversion: true)
                        }.nativeEditorPresentation()
                    }
                    .workspaceSelectionFeedback(trigger: editing)
                    .workspaceSelectionFeedback(trigger: recurrence)
                    .workspaceSelectionFeedback(trigger: childKind)
                    .sheet(isPresented: $recurrence) { NavigationStack { RecurrenceEditorView(record: record) }.nativeSheetSize() }
                    .sheet(item: $childKind) { kind in NavigationStack {
                        RecordEditorView(kind: kind, projectID: record.kind == .project ? record.id : nil, areaID: record.kind == .area ? record.id : nil)
                    }.nativeEditorPresentation() }
                    .sheet(item: $preview) { preview in
                        NavigationStack { DeleteReviewView(preview: preview, onDeleted: { if !embedded { dismiss() } }) }.nativeSheetSize()
                    }
                    .fileImporter(isPresented: $pickingPDF, allowedContentTypes: [.pdf]) { result in
                        store.perform { try store.attachPDF(result.get(), to: id) }
                    }
            } else { ContentUnavailableView(WorkspaceLocalization.string("记录已移入回收站"), systemImage: "trash", description: Text(WorkspaceLocalization.string("可在更多或侧栏的回收站中恢复。"))) }
        }
        .disabled(completionRequest != nil || (!embedded && completedRecordID == id))
        .onChange(of: isPresentingDetailModal, initial: true) { _, active in
            presentationChanged?(active)
        }
        .task(id: completionArmedFor) {
            guard completionArmedFor != nil else { return }
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            guard completionRequest == nil else { return }
            withAnimation(.easeOut(duration: 0.25)) { completionArmedFor = nil }
        }
        .onChange(of: id) { _, _ in completionArmedFor = nil }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { completionArmedFor = nil }
        }
        .onDisappear { completionArmedFor = nil }
        #if os(iOS)
        .background(WorkspaceCompletionWindowAnchor(presenter: completionPresenter).allowsHitTesting(false))
        #else
        .sheet(item: $completionRequest) { record in
            completionTransition(for: record).frame(minWidth: 440, minHeight: 360)
        }
        #endif
    }
    @ViewBuilder private func titledDetail(_ record: WorkspaceRecord) -> some View {
        #if os(iOS)
        if embedded {
            VStack(spacing: 0) {
                embeddedActionHeader(record)
                detail(record)
            }
            .background(Color(.systemGroupedBackground))
        } else {
            detail(record)
                .navigationTitle(record.kind.title)
                .workspaceInlineTitle()
                .toolbar { detailToolbar(record) }
        }
        #else
        if embedded {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Label(record.kind.title, systemImage: record.kind.symbol)
                        .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Button(record.pinned ? WorkspaceLocalization.string("取消标星") : WorkspaceLocalization.string("标星"), systemImage: record.pinned ? "star.fill" : "star") {
                        store.perform { try store.toggleKeyItem(record.id) }
                    }
                    .labelStyle(.iconOnly).tint(record.pinned ? .orange : palette.accent)
                    .disabled(record.archivedAt != nil || store.isReadOnlyWorkspace)
                    .help(record.pinned ? WorkspaceLocalization.string("取消标星") : WorkspaceLocalization.string("标星"))
                    actions(record)
                    Button(WorkspaceLocalization.string("编辑"), systemImage: "pencil") { editing = true }
                        .disabled(record.archivedAt != nil).help(WorkspaceLocalization.string("编辑当前记录"))
                }
                .buttonStyle(.borderless).controlSize(.regular)
                .padding(.horizontal, 18).padding(.vertical, 12)
                Divider()
                detail(record)
            }
        } else {
            detail(record)
                .navigationTitle(record.kind.title)
                .toolbar { detailToolbar(record) }
        }
        #endif
    }
    @ToolbarContentBuilder private func detailToolbar(_ record: WorkspaceRecord) -> some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button(WorkspaceLocalization.string("编辑"), systemImage: "pencil") { editing = true }
                .disabled(record.archivedAt != nil)
        }
        ToolbarItem {
            Button(record.pinned ? WorkspaceLocalization.string("取消标星") : WorkspaceLocalization.string("标星"), systemImage: record.pinned ? "star.fill" : "star") {
                store.perform { try store.toggleKeyItem(record.id) }
            }.tint(record.pinned ? .orange : palette.accent)
                .disabled(record.archivedAt != nil || store.isReadOnlyWorkspace)
        }
        ToolbarItem { actions(record) }
    }
    #if os(iOS)
    private func embeddedActionHeader(_ record: WorkspaceRecord) -> some View {
        HStack(spacing: 4) {
            Text(record.kind.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                store.perform { try store.toggleKeyItem(record.id) }
            } label: {
                Image(systemName: record.pinned ? "star.fill" : "star")
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .foregroundStyle(record.pinned ? Color.orange : palette.accent)
            .disabled(record.archivedAt != nil || store.isReadOnlyWorkspace)
            .accessibilityLabel(record.pinned ? WorkspaceLocalization.string("取消标星") : WorkspaceLocalization.string("标星"))
            actions(record, local: true)
                .labelStyle(.iconOnly)
            Button { editing = true } label: {
                Label(WorkspaceLocalization.string("编辑"), systemImage: "pencil")
                    .labelStyle(.titleAndIcon)
                    .font(.subheadline.weight(.semibold))
                    .frame(minWidth: 64, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .disabled(record.archivedAt != nil)
        }
        .font(.body.weight(.medium))
        .buttonStyle(.plain)
        .tint(palette.accent)
        .foregroundStyle(palette.accent)
        .padding(.horizontal, 16)
        .padding(.vertical, 2)
        .accessibilityIdentifier("record-detail-local-actions")
    }
    #endif
    private func requestCompletion(_ record: WorkspaceRecord) {
        guard completionRequest == nil, completedRecordID != record.id else { return }
        #if os(iOS)
        WorkspaceHaptics.play(completionArmedFor == record.id ? .confirmation : .tap,
                              enabled: store.hapticsEnabled)
        #endif
        guard completionArmedFor == record.id else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { completionArmedFor = record.id }
            return
        }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { completionRequest = record }
        #if os(iOS)
        let presented = completionPresenter.present(title: record.title, colorScheme: colorScheme, fillColor: UIColor(palette.action),
            returnToPrevious: finishCompletionPresentation,
            close: { completionRequest = nil; completionArmedFor = nil },
            complete: { try completeRecord(record) })
        if !presented {
            completionRequest = nil
            completionArmedFor = nil
            store.errorMessage = WorkspaceLocalization.string("暂时无法显示完成反馈，请再次尝试。")
        }
        #endif
    }
    private func completeRecord(_ record: WorkspaceRecord) throws {
        // Capture this record's ID; never resolve a newly displayed item on a later tap.
        guard let current = store.record(record.id), current.isLive, !current.isFinished else {
            throw WorkspaceFailure.invalid(WorkspaceLocalization.string("此事项状态已改变，请返回查看最新内容。"))
        }
        // The root emits one gentle confirmation when the completion is saved.
        // Do not add another generator in the curtain controller.
        try store.setStatus(record.id, "DONE")
        completedRecordID = record.id
    }
    #if os(macOS)
    private func completionTransition(for record: WorkspaceRecord) -> some View {
        WorkspaceCompletionTransition(title: record.title,
            returnToPrevious: {},
            close: {
                completionRequest = nil
                finishCompletionPresentation()
            },
            complete: { try completeRecord(record) })
        .interactiveDismissDisabled()
    }
    #endif
    private func finishCompletionPresentation() {
        guard completedRecordID == id else { return }
        if !embedded { dismiss() }
    }
    private func detail(_ record: WorkspaceRecord) -> some View {
        RecordDetailContent {
            primarySections(record)
        } secondary: {
            supportingSections(record)
        }
    }
    @ViewBuilder private func primarySections(_ record: WorkspaceRecord) -> some View {
        identitySections(record)
        #if os(iOS)
        if embedded && record.kind.isProjectGroup { projectSections(record) }
        #endif
        if !record.isFinished && (record.kind.isItem || record.kind == .deadline) && record.archivedAt == nil {
            Section {
                Button { requestCompletion(record) } label: {
                    Label(completionArmedFor == record.id ? WorkspaceLocalization.string("再点一次，确认完成") : WorkspaceLocalization.string("标记完成"),
                          systemImage: completionArmedFor == record.id ? "checkmark.circle.fill" : "checkmark")
                }
                .buttonStyle(WorkspacePrimaryButtonStyle(tint: completionArmedFor == record.id ? palette.confirmation : palette.action, hapticOnPress: false))
                .accessibilityHint(completionArmedFor == record.id ? WorkspaceLocalization.string("再次轻点以确认完成当前事项") : WorkspaceLocalization.string("连续轻点两次确认完成"))
                .workspaceActionRow()
            }
        }
    }
    @ViewBuilder private func identitySections(_ record: WorkspaceRecord) -> some View {
        #if os(iOS)
        if embedded, record.kind == .deadline, let due = record.dueDate, !record.isFinished {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    titleContent(record)
                    DeadlineCountdownView(target: record.effectiveDueDate(due), isInline: true)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.background, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
        } else {
            standardIdentitySections(record)
        }
        #else
        standardIdentitySections(record)
        #endif
    }
    @ViewBuilder private func standardIdentitySections(_ record: WorkspaceRecord) -> some View {
        titleSection(record)
        if record.kind == .deadline, let due = record.dueDate, !record.isFinished {
            Section {
                DeadlineCountdownView(target: record.effectiveDueDate(due))
            }.listRowBackground(Color.clear).listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
        }
    }
    @ViewBuilder private func titleSection(_ record: WorkspaceRecord) -> some View {
        #if os(iOS)
        Section {
            titleContent(record)
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.background, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
        #else
        Section { titleContent(record).padding(.vertical, 6) }
        #endif
    }
    private func titleContent(_ record: WorkspaceRecord) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if record.isFinished {
                Label(WorkspaceLocalization.string("已完成"), systemImage: "checkmark")
                    .font(.caption.weight(.semibold)).foregroundStyle(Color.workspaceCompleted)
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if record.pinned {
                    Image(systemName: "star.fill").font(.title3).foregroundStyle(.orange)
                        .accessibilityLabel(WorkspaceLocalization.string("星标"))
                }
                Text(record.title).font(.title2.bold())
                    .foregroundStyle(record.isFinished ? Color.workspaceCompleted : Color.primary)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    @ViewBuilder private func supportingSections(_ record: WorkspaceRecord) -> some View {
        Section {
            if let due = record.dueDate { LabeledContent(WorkspaceLocalization.string("截止"), value: formatted(due, record: record)) }
            if let scheduled = record.scheduledAt { LabeledContent(WorkspaceLocalization.string("计划时间"), value: formatted(scheduled, record: record, time: true)) }
            if let reminder = record.notificationDate { LabeledContent(WorkspaceLocalization.string("通知时间"), value: formatted(reminder, record: record, time: true)) }
            if let project = record.projectID.flatMap(store.record) {
                NavigationLink { RecordDetailView(id: project.id, presentationChanged: presentationChanged) } label: { LabeledContent(WorkspaceLocalization.string("项目组"), value: project.title) }
            }
            if record.projectID == nil, let area = record.areaID.flatMap(store.record) {
                NavigationLink { RecordDetailView(id: area.id, presentationChanged: presentationChanged) } label: { LabeledContent(WorkspaceLocalization.string("项目组"), value: area.title) }
            }
            if let milestone = record.milestoneID.flatMap(store.record) { LabeledContent(WorkspaceLocalization.string("关联事项"), value: milestone.title) }
            if record.kind.isProjectGroup {
                LabeledContent(WorkspaceLocalization.string("类型"), value: projectKindLabel(record.projectKind))
                if let date = record.startDate { LabeledContent(WorkspaceLocalization.string("开始"), value: formatted(date, record: record)) }
                if let date = record.targetDate { LabeledContent(WorkspaceLocalization.string("目标"), value: formatted(date, record: record)) }
            }
            if record.archivedAt != nil { Label(WorkspaceLocalization.string("已归档"), systemImage: "archivebox").foregroundStyle(.secondary) }
        }
        #if os(iOS)
        if record.kind.isItem || record.kind == .deadline { DeadlineLiveActivitySection(record: record) }
        #endif
        if !record.summary.isEmpty { Section(WorkspaceLocalization.string("说明")) { Text(record.summary).textSelection(.enabled) } }
        if !record.body.isEmpty { Section(record.kind == .knowledge ? WorkspaceLocalization.string("正文") : WorkspaceLocalization.string("备注")) { MarkdownDocumentView(source: record.body) } }
        if record.kind == .knowledge { knowledgeSections(record) }
        if record.kind.isProjectGroup {
            #if os(iOS)
            if !embedded { projectSections(record) }
            #else
            projectSections(record)
            #endif
        }
        if let seriesID = record.recurrenceSeriesID,
           let series = store.state.series.first(where: { $0.id == seriesID }) {
            Section(WorkspaceLocalization.string("重复")) {
                NavigationLink {
                    RecurringSeriesManagementView(seriesID: seriesID, occurrenceID: record.id)
                } label: {
                    Label(series.rule.label, systemImage: "repeat")
                }
                if record.isException { Label(WorkspaceLocalization.string("已单独修改的实例"), systemImage: "pencil.circle") }
                if series.stoppedAt != nil { Text(WorkspaceLocalization.string("后续重复已停止")).foregroundStyle(.secondary) }
            }
        }
        Section(WorkspaceLocalization.string("历史记录")) {
            ForEach(recordHistory(record).prefix(100)) { activity in
                VStack(alignment: .leading, spacing: 4) {
                    Text(activity.message)
                    Text(activity.date, format: .dateTime.month().day().hour().minute()).font(.caption).foregroundStyle(.secondary)
                }
            }
            LabeledContent(WorkspaceLocalization.string("版本"), value: "\(record.version)")
        }
    }
    private func recordHistory(_ record: WorkspaceRecord) -> [ActivityEntry] {
        let memberIDs: Set<UUID> = record.kind.isProjectGroup ? Set(store.state.records.filter {
            $0.projectID == id || $0.areaID == id
        }.map(\.id)) : []
        return store.state.activities.filter {
            $0.entityID == id || (record.kind.isProjectGroup && ($0.projectID == id || memberIDs.contains($0.entityID)))
        }.sorted { $0.date > $1.date }
    }
    @ViewBuilder private func knowledgeSections(_ record: WorkspaceRecord) -> some View {
        Section(WorkspaceLocalization.string("分类与标签")) {
            LabeledContent(WorkspaceLocalization.string("分类"), value: record.category)
            if !record.tags.isEmpty { Text(record.tags.map { "#" + $0 }.joined(separator: "  ")) }
        }
        Section(WorkspaceLocalization.string("PDF 附件")) {
            ForEach(store.state.assets.filter { $0.ownerID == id }) { asset in
                NavigationLink { PDFDocumentView(asset: asset) } label: {
                    Label(asset.name, systemImage: "doc.richtext")
                }
            }
            Button(WorkspaceLocalization.string("添加 PDF"), systemImage: "paperclip") { pickingPDF = true }.disabled(record.archivedAt != nil)
        }
        Section(WorkspaceLocalization.string("笔记版本")) {
            ForEach(store.state.revisions.filter { $0.record.id == id }.sorted { $0.date > $1.date }.prefix(100)) { revision in
                NavigationLink {
                    RevisionDetailView(revision: revision)
                } label: { LabeledContent(WorkspaceLocalization.format("版本 %@", String(describing: revision.record.version)), value: revision.date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, locale: WorkspaceLocalization.locale))) }
            }
        }
    }
    @ViewBuilder private func projectSections(_ record: WorkspaceRecord) -> some View {
        let members = RecurringRecordPresentation.representatives(in: store.members(of: record))
        Section {
            Menu {
                RecordCreationActions(withinGroup: true) { childKind = $0 }
            } label: { Label(WorkspaceLocalization.string("添加内容"), systemImage: "plus") }
            .disabled(record.archivedAt != nil || store.isReadOnlyWorkspace)
            if members.isEmpty { Text(WorkspaceLocalization.string("还没有内容")).foregroundStyle(.secondary) }
        }
        if members.contains(where: { $0.kind.isProjectGroup }) {
            Section(WorkspaceLocalization.string("下属项目组")) {
                ForEach(members.filter { $0.kind.isProjectGroup }) { group in
                    NavigationLink { RecordDetailView(id: group.id, presentationChanged: presentationChanged) } label: { RecordRow(record: group) }
                }
            }
        }
        if members.contains(where: { $0.kind.isItem }) { Section(WorkspaceLocalization.string("事项")) {
            ForEach(members.filter { $0.kind.isItem }) { task in
                NavigationLink { RecordDetailView(id: task.id, presentationChanged: presentationChanged) } label: { RecordRow(record: task) }
            }
        } }
        if members.contains(where: { $0.kind == .deadline }) { Section(WorkspaceLocalization.string("截止事项")) {
            ForEach(members.filter { $0.kind == .deadline }.prefix(30)) { deadline in
                NavigationLink { RecordDetailView(id: deadline.id, presentationChanged: presentationChanged) } label: { RecordRow(record: deadline) }
            }
        } }
    }
    private func requestKindConversion(_ record: WorkspaceRecord) {
        store.perform {
            let draft = try WorkspaceLogic.conversionDraft(record, to: record.kindConversionTarget, in: store.state)
            if draft.kind == .deadline && draft.dueDate == nil { convertingRecord = draft }
            else { try store.save(draft, expectedVersion: record.version) }
        }
    }
    private func actions(_ record: WorkspaceRecord, local: Bool = false) -> some View {
        Menu {
            if record.isFinished && record.kind.completedStatus != nil {
                Button(WorkspaceLocalization.string("标为未完成"), systemImage: "arrow.counterclockwise") { store.perform { try store.setStatus(id, record.kind.incompleteStatus) } }
            }
            if (record.kind.isItem || record.kind == .deadline), record.isLive {
                if record.recurrenceSeriesID == nil && !record.isFinished {
                    Button(WorkspaceLocalization.string("设置重复"), systemImage: "repeat") { recurrence = true }
                }
            }
            if (record.kind.isItem || record.kind == .deadline), record.isLive {
                Button(record.kindConversionTitle, systemImage: record.kindConversionTarget.symbol) {
                    requestKindConversion(record)
                }.disabled(store.isReadOnlyWorkspace)
            }
            if record.dueDate != nil || record.scheduledAt != nil || record.targetDate != nil {
                Button(WorkspaceLocalization.string("加入系统日历"), systemImage: "calendar.badge.plus") {
                    Task {
                        do {
                            guard !store.isDemoMode else {
                                store.information = WorkspaceLocalization.string("演示模式不会写入系统日历。")
                                return
                            }
                            _ = try await SystemCalendarService.add(record)
                            store.information = WorkspaceLocalization.string("已保存到系统日历。")
                        } catch { store.errorMessage = error.localizedDescription }
                    }
                }
            }
            Button(record.archivedAt == nil ? WorkspaceLocalization.string("归档") : WorkspaceLocalization.string("恢复归档"), systemImage: "archivebox") {
                store.perform { try store.archive(id, restore: record.archivedAt != nil) }
            }
            Divider()
            Button(WorkspaceLocalization.string("移入回收站"), systemImage: "trash", role: .destructive) { store.perform { preview = try store.deletionPreview(id) } }
        } label: {
            if local {
                Label(WorkspaceLocalization.string("更多操作"), systemImage: "ellipsis.circle")
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            } else {
                Label(WorkspaceLocalization.string("更多操作"), systemImage: "ellipsis.circle")
            }
        }
    }
    private func formatted(_ date: Date, record: WorkspaceRecord, time: Bool = false) -> String {
        let formatter = DateFormatter(); formatter.locale = WorkspaceLocalization.locale; formatter.timeZone = record.calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate(time || !record.dateOnly ? "yMMMdHHmm" : "yMMMd")
        return formatter.string(from: date)
    }
    private func countdown(to target: Date, now: Date) -> String {
        let duration = Int(abs(target.timeIntervalSince(now)))
        return (target < now ? WorkspaceLocalization.string("已逾期 ") : WorkspaceLocalization.string("还剩 ")) + WorkspaceLocalization.format("%@ 天 %@ 时 %@ 分 %@ 秒", String(describing: duration / 86400), String(describing: duration / 3600 % 24), String(describing: duration / 60 % 60), String(describing: duration % 60))
    }
}
/// Keep the main action in view while the surrounding information scrolls separately.
private struct RecordDetailContent<Primary: View, Secondary: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    #if os(iOS)
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    #endif
    @ViewBuilder let primary: Primary
    @ViewBuilder let secondary: Secondary

    var body: some View {
        #if os(iOS)
        GeometryReader { geometry in
            if geometry.size.width >= 680 && !dynamicTypeSize.isAccessibilitySize {
                HStack(alignment: .top, spacing: 0) {
                    List { primary }
                        .listStyle(.insetGrouped)
                        .listSectionSpacing(12)
                        .contentMargins(.leading, 16, for: .scrollContent)
                        .contentMargins(.trailing, 8, for: .scrollContent)
                        .contentMargins(.top, 12, for: .scrollContent)
                        .frame(width: geometry.size.width * 0.43)
                        .accessibilityIdentifier("record-detail-primary-pane")
                    List { secondary }
                        .listStyle(.insetGrouped)
                        .listSectionSpacing(16)
                        .contentMargins(.leading, 8, for: .scrollContent)
                        .contentMargins(.trailing, 16, for: .scrollContent)
                        .contentMargins(.top, 12, for: .scrollContent)
                        .accessibilityIdentifier("record-detail-information-pane")
                }
                .background(Color(.systemGroupedBackground))
            } else {
                List { primary; secondary }
                    .listSectionSpacing(verticalSizeClass == .compact ? 10 : 16)
                    .contentMargins(.top, verticalSizeClass == .compact ? 8 : nil, for: .scrollContent)
            }
        }
        #else
        GeometryReader { geometry in
            if geometry.size.width >= 920 {
                HSplitView {
                    List { primary }.listStyle(.inset)
                        .frame(minWidth: 320, idealWidth: 400)
                    List { secondary }.listStyle(.inset)
                        .frame(minWidth: 340, maxWidth: .infinity)
                }
            } else {
                List { primary; secondary }.listStyle(.inset)
            }
        }
        #endif
    }
}

/// Browsing a future repeat does not insert it into the workspace. A user
/// change is saved as one occurrence, while untouched dates stay in the rule.
struct ProjectedCalendarOccurrenceView: View {
    @Environment(\.workspacePalette) private var palette
    @Environment(WorkspaceStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let record: WorkspaceRecord
    @State private var editing = false
    @State private var convertingRecord: WorkspaceRecord?
    @State private var completionArmed = false
    @State private var preview: DeletionPreview?
    @State private var localError: String?

    var body: some View {
        Group {
            if let stored = store.record(record.id) {
                RecordDetailView(id: stored.id)
            } else if let series = store.state.series.first(where: {
                $0.id == record.recurrenceSeriesID && $0.deletedAt == nil && $0.stoppedAt == nil
            }) {
                occurrence(series)
                    .navigationTitle(record.kind.title)
                    .workspaceInlineTitle()
                    .toolbar {
                        ToolbarItem(placement: .primaryAction) {
                            Button(WorkspaceLocalization.string("编辑"), systemImage: "pencil") { editing = true }
                        }
                        ToolbarItem {
                            Menu {
                                Button(record.kindConversionTitle, systemImage: record.kindConversionTarget.symbol) {
                                    store.perform {
                                        let draft = try WorkspaceLogic.conversionDraft(record, to: record.kindConversionTarget, in: store.state)
                                        if draft.kind == .deadline && draft.dueDate == nil { convertingRecord = draft }
                                        else { try store.save(draft, expectedVersion: nil) }
                                    }
                                }.disabled(store.isReadOnlyWorkspace)
                                Button(WorkspaceLocalization.string("删除"), systemImage: "trash", role: .destructive) {
                                    store.perform { preview = try store.deletionPreview(record) }
                                }
                            } label: { Label(WorkspaceLocalization.string("更多操作"), systemImage: "ellipsis.circle") }
                        }
                    }
            } else {
                ContentUnavailableView(WorkspaceLocalization.string("此重复日程已结束"), systemImage: "repeat.circle",
                                       description: Text(WorkspaceLocalization.string("返回日历查看最新日程。")))
            }
        }
        .sheet(isPresented: $editing) {
            NavigationStack {
                RecordEditorView(kind: record.kind, record: record, isProjectedOccurrence: true)
            }.nativeEditorPresentation()
        }
        .sheet(item: $convertingRecord) { draft in
            NavigationStack {
                RecordEditorView(kind: draft.kind, record: draft, isProjectedOccurrence: true, isKindConversion: true)
            }.nativeEditorPresentation()
        }
        .sheet(item: $preview) { value in
            NavigationStack { DeleteReviewView(preview: value, onDeleted: { dismiss() }) }.nativeSheetSize()
        }
        .task(id: completionArmed) {
            guard completionArmed else { return }
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            completionArmed = false
        }
        .onDisappear { completionArmed = false }
    }
    private func occurrence(_ series: DeadlineSeries) -> some View {
        List {
            Section {
                Text(record.title).font(.title2.bold()).fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled).padding(.vertical, 6)
            }
            Section {
                if let scheduled = record.scheduledAt {
                    LabeledContent(WorkspaceLocalization.string("计划时间")) { Text(scheduled, format: dateStyle(time: true)) }
                }
                if let due = record.dueDate {
                    LabeledContent(WorkspaceLocalization.string("截止")) { Text(due, format: dateStyle(time: !record.dateOnly)) }
                }
                if let reminder = record.notificationDate {
                    LabeledContent(WorkspaceLocalization.string("通知时间")) { Text(reminder, format: dateStyle(time: true)) }
                }
            }
            if !record.summary.isEmpty { Section(WorkspaceLocalization.string("说明")) { Text(record.summary).textSelection(.enabled) } }
            if !record.body.isEmpty { Section(WorkspaceLocalization.string("备注")) { MarkdownDocumentView(source: record.body) } }
            Section {
                let existingID = store.state.records.first { $0.recurrenceSeriesID == series.id && $0.isLive }?.id
                    ?? series.template.id
                NavigationLink {
                    RecurringSeriesManagementView(seriesID: series.id, occurrenceID: existingID)
                } label: { LabeledContent(WorkspaceLocalization.string("重复"), value: series.rule.label) }
            } footer: { Text(WorkspaceLocalization.string("编辑只影响这一次。")) }
            Section {
                Button {
                    guard completionArmed else { completionArmed = true; return }
                    do {
                        var completed = record
                        completed.status = record.kind.completedStatus ?? "DONE"
                        completed.isException = true
                        try store.save(completed, expectedVersion: nil)
                        dismiss()
                    } catch { localError = error.localizedDescription; completionArmed = false }
                } label: {
                    Label(completionArmed ? WorkspaceLocalization.string("再点一次，确认完成") : WorkspaceLocalization.string("标记完成"),
                          systemImage: completionArmed ? "checkmark.circle.fill" : "checkmark")
                }
                .buttonStyle(WorkspacePrimaryButtonStyle(tint: completionArmed ? palette.confirmation : palette.action))
                .accessibilityHint(WorkspaceLocalization.string("连续轻点两次确认完成"))
                .workspaceActionRow()
                if let localError { Text(localError).foregroundStyle(.red) }
            }
        }
    }
    private func dateStyle(time: Bool) -> Date.FormatStyle {
        var style = Date.FormatStyle.dateTime.year().month().day()
        if time { style = style.hour().minute() }
        style.locale = WorkspaceLocalization.locale
        style.timeZone = record.calendar.timeZone
        return style
    }
}

struct DeleteReviewView: View {
    @Environment(WorkspaceStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    private let selectedIDs: Set<UUID>
    @State private var preview: DeletionPreview
    @State private var scope: RecurrenceDeletionScope
    @State private var localError: String?
    var onDeleted: () -> Void
    init(preview: DeletionPreview, onDeleted: @escaping () -> Void) {
        selectedIDs = Set(preview.selectedIDs.isEmpty ? [preview.root.id] : preview.selectedIDs)
        _preview = State(initialValue: preview)
        _scope = State(initialValue: preview.recurrenceScope)
        self.onDeleted = onDeleted
    }
    private var hasRecurringSelection: Bool {
        preview.records.contains { selectedIDs.contains($0.id) && $0.recurrenceSeriesID != nil }
    }
    private var scopeDescription: String {
        switch scope {
        case .occurrence: WorkspaceLocalization.string("仅删除选中的次数，其他日期继续重复。")
        case .following: WorkspaceLocalization.string("删除所选日期及之后的重复，并结束相应的重复规则。")
        case .series: WorkspaceLocalization.string("删除整个重复系列，之后也不会继续生成。")
        }
    }
    var body: some View {
        List {
            if hasRecurringSelection {
                Section {
                    Picker(WorkspaceLocalization.string("删除范围"), selection: $scope) {
                        ForEach(RecurrenceDeletionScope.allCases) { Text($0.title).tag($0) }
                    }.pickerStyle(.inline)
                } header: { Text(WorkspaceLocalization.string("重复日程")) } footer: { Text(scopeDescription) }
            }
            Section {
                LabeledContent(WorkspaceLocalization.string("移入回收站"), value: WorkspaceLocalization.format("%@ 项", String(describing: preview.records.count)))
                if !preview.affectedSeries.isEmpty {
                    LabeledContent(WorkspaceLocalization.string("涉及重复系列"), value: WorkspaceLocalization.format("%@ 组", String(describing: preview.affectedSeries.count)))
                }
                if let localError { Text(localError).foregroundStyle(.red) }
            } footer: {
                Text(preview.records.allSatisfy { $0.kind == .knowledge }
                     ? WorkspaceLocalization.string("知识笔记可随时从回收站恢复。")
                     : WorkspaceLocalization.string("删除后可在 30 天内从回收站恢复。"))
            }
            Section(WorkspaceLocalization.string("删除预览")) {
                ForEach(preview.records.prefix(30)) { RecordRow(record: $0, showsCountdown: false) }
                if preview.records.count > 30 {
                    Text(WorkspaceLocalization.format("还有 %@ 项，将一并移入回收站。", String(describing: preview.records.count - 30)))
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
        }.navigationTitle(WorkspaceLocalization.string("确认删除"))
            .workspaceInlineTitle()
            .onChange(of: scope) { _, value in
                do {
                    preview = try store.deletionPreview(selectedIDs, scope: value, projectedRecords: preview.projectedRecords)
                    localError = nil
                }
                catch { localError = error.localizedDescription }
            }
            .workspaceSelectionFeedback(trigger: scope)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(WorkspaceLocalization.string("取消")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(WorkspaceLocalization.format("删除 %@ 项", String(describing: preview.records.count)), role: .destructive) {
                        do { try store.delete(preview); dismiss(); onDeleted() }
                        catch { localError = error.localizedDescription }
                    }.disabled(localError != nil || preview.records.isEmpty)
                }
            }
    }
}

/// One rule owns its upcoming occurrences and retained completion history.
struct RecurringSeriesManagementView: View {
    @Environment(WorkspaceStore.self) private var store
    let seriesID: UUID
    let occurrenceID: UUID
    @State private var stopping = false
    @State private var preview: DeletionPreview?

    var body: some View {
        Group {
            if let series = store.state.series.first(where: { $0.id == seriesID && $0.deletedAt == nil }) {
                management(series)
            } else {
                ContentUnavailableView(WorkspaceLocalization.string("重复日程已移入回收站"), systemImage: "trash",
                                       description: Text(WorkspaceLocalization.string("可在回收站中恢复整个系列。")))
            }
        }
        .navigationTitle(WorkspaceLocalization.string("重复日程"))
        .workspaceInlineTitle()
        .sheet(item: $preview) { value in
            NavigationStack { DeleteReviewView(preview: value, onDeleted: {}) }.nativeSheetSize()
        }
        .confirmationDialog(WorkspaceLocalization.string("停止后续重复？"), isPresented: $stopping, titleVisibility: .visible) {
            Button(WorkspaceLocalization.string("停止后续重复"), role: .destructive) { store.perform { try store.stopRecurrence(seriesID) } }
        } message: {
            Text(WorkspaceLocalization.string("之后不再重复，未来未完成的次数将关闭。过去的事项和完成记录会保留。"))
        }
    }
    private func management(_ series: DeadlineSeries) -> some View {
        let occurrences = store.state.records.filter { $0.recurrenceSeriesID == seriesID && $0.isLive }
        let today = series.template.calendar.startOfDay(for: Date())
        let upcoming = occurrences.filter { !$0.isFinished && ($0.recurrenceAnchor ?? .distantPast) >= today }
            .sorted { ($0.recurrenceAnchor ?? .distantFuture) < ($1.recurrenceAnchor ?? .distantFuture) }
        let previous = occurrences.filter { !$0.isFinished && ($0.recurrenceAnchor ?? .distantPast) < today }
            .sorted { ($0.recurrenceAnchor ?? .distantPast) > ($1.recurrenceAnchor ?? .distantPast) }
        let completed = occurrences.filter(\.isFinished)
            .sorted { ($0.completedAt ?? $0.recurrenceAnchor ?? .distantPast) > ($1.completedAt ?? $1.recurrenceAnchor ?? .distantPast) }
        return List {
            Section {
                Text(series.template.title).font(.title3.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                LabeledContent(WorkspaceLocalization.string("重复"), value: series.rule.label)
                if let anchor = series.template.recurrenceAnchor {
                    LabeledContent(WorkspaceLocalization.string("开始")) { Text(anchor, format: dateStyle(series)) }
                }
                if let until = series.rule.until {
                    LabeledContent(WorkspaceLocalization.string("结束")) { Text(until, format: dateStyle(series)) }
                } else { LabeledContent(WorkspaceLocalization.string("结束"), value: WorkspaceLocalization.string("不设结束日期")) }
                if series.rule.frequency.usesWeekParity, let first = series.rule.weekOneStart {
                    LabeledContent(WorkspaceLocalization.string("第 1 周起始日")) { Text(first, format: dateStyle(series)) }
                }
                if series.stoppedAt != nil { Text(WorkspaceLocalization.string("后续重复已停止")).foregroundStyle(.secondary) }
            }
            if !upcoming.isEmpty {
                occurrenceSection(WorkspaceLocalization.string("本次与接下来"), records: upcoming)
            }
            if !previous.isEmpty {
                occurrenceSection(WorkspaceLocalization.string("过去未完成"), records: previous)
            }
            if !completed.isEmpty {
                occurrenceSection(WorkspaceLocalization.string("已完成"), records: completed)
            }
            Section {
                if series.stoppedAt == nil {
                    Button(WorkspaceLocalization.string("停止后续重复"), systemImage: "repeat.circle") { stopping = true }
                }
                Button(WorkspaceLocalization.string("删除整个重复系列"), systemImage: "trash", role: .destructive) {
                    let recordID = occurrences.first(where: { $0.id == occurrenceID })?.id
                        ?? upcoming.first?.id ?? previous.first?.id ?? completed.first?.id ?? occurrenceID
                    store.perform { preview = try store.deletionPreview(recordID, scope: .series) }
                }
            } footer: {
                Text(WorkspaceLocalization.string("这里列出近期日程。后续日期可在日历中查看。"))
            }
        }
    }
    private func occurrenceSection(_ title: String, records: [WorkspaceRecord]) -> some View {
        Section {
            ForEach(records.prefix(30)) { record in
                NavigationLink { RecordDetailView(id: record.id) } label: { RecordRow(record: record, showsCountdown: false) }
            }
            if records.count > 30 {
                Text(WorkspaceLocalization.format("另有 %@ 项；可在事项列表取消“每组重复显示一条”后批量管理。", String(describing: records.count - 30)))
                    .font(.caption).foregroundStyle(.secondary)
            }
        } header: { Text(title) }
    }
    private func dateStyle(_ series: DeadlineSeries) -> Date.FormatStyle {
        var style = Date.FormatStyle.dateTime.year().month().day()
        style.locale = WorkspaceLocalization.locale
        style.timeZone = series.template.calendar.timeZone
        return style
    }
}
struct RevisionDetailView: View {
    @Environment(WorkspaceStore.self) private var store
    let revision: KnowledgeRevision
    @State private var confirming = false
    var body: some View {
        ScrollView { MarkdownDocumentView(source: revision.record.body).padding().frame(maxWidth: .infinity, alignment: .leading) }
            .navigationTitle(WorkspaceLocalization.format("版本 %@", String(describing: revision.record.version)))
            .toolbar { Button(WorkspaceLocalization.string("恢复此版本"), systemImage: "arrow.counterclockwise") { confirming = true } }
            .confirmationDialog(WorkspaceLocalization.string("恢复后将生成新版本，当前内容仍保留在历史记录中。"), isPresented: $confirming, titleVisibility: .visible) {
                Button(WorkspaceLocalization.string("恢复此版本")) { store.perform { try store.restoreRevision(revision) } }
            }
    }
}
struct RecurrenceEditorView: View {
    @Environment(WorkspaceStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let record: WorkspaceRecord
    @State private var rule = RecurrenceRule()
    @State private var localError: String?
    var body: some View {
        Form {
            RecurrenceRuleFields(rule: $rule, record: record)
            if let localError { Section { Text(localError).foregroundStyle(.red) } }
        }.formStyle(.grouped).navigationTitle(WorkspaceLocalization.string("设置重复"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(WorkspaceLocalization.string("取消")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button(WorkspaceLocalization.string("保存")) {
                    do { try store.createRecurrence(record.id, rule: rule); dismiss() }
                    catch { localError = error.localizedDescription }
                }.disabled(RecurrenceEngine.validationError(record: record, rule: rule) != nil) }
            }
            .nativeEditorPresentation()
    }
}

struct RecurrenceRuleFields: View {
    @Binding var rule: RecurrenceRule
    let record: WorkspaceRecord
    private var anchor: Date { record.recurrenceAnchor ?? Date() }
    private var firstMonday: Date { RecurrenceEngine.monday(containing: anchor, calendar: record.calendar) }
    private var previewDayStyle: Date.FormatStyle {
        var style = Date.FormatStyle.dateTime.year().month().day().weekday()
        style.locale = WorkspaceLocalization.locale
        style.timeZone = record.calendar.timeZone
        return style
    }
    private var previewTimeStyle: Date.FormatStyle {
        var style = Date.FormatStyle.dateTime.year().month().day().hour().minute()
        style.locale = WorkspaceLocalization.locale
        style.timeZone = record.calendar.timeZone
        return style
    }
    private var nextDates: [Date] {
        let from = max(record.calendar.startOfDay(for: anchor), record.calendar.startOfDay(for: Date()))
        let through = record.calendar.date(byAdding: .year, value: 3, to: from) ?? from
        return RecurrenceEngine.dates(anchor: anchor, rule: rule, from: from, through: through, timezone: record.timezone, limit: 5)
    }
    var body: some View {
        Group {
            Section(WorkspaceLocalization.string("重复规则")) {
                if let first = record.recurrenceAnchor {
                    LabeledContent(WorkspaceLocalization.string("重复依据"), value: record.kind.isItem && record.scheduledAt != nil ? WorkspaceLocalization.string("计划时间") : record.dueDate != nil ? WorkspaceLocalization.string("截止日期") : WorkspaceLocalization.string("自定义提醒时间"))
                    LabeledContent(WorkspaceLocalization.string("首次时间")) {
                        Text(first, format: previewTimeStyle)
                    }
                }
                Picker(WorkspaceLocalization.string("频率"), selection: $rule.frequency) {
                    ForEach(RecurrenceRule.Frequency.allCases) { Text($0.title).tag($0) }
                }
                if rule.frequency.supportsInterval {
                    Stepper(WorkspaceLocalization.format("每 %@ %@", String(describing: rule.interval), String(describing: rule.frequency.intervalUnit)), value: $rule.interval, in: 1...365)
                    if rule.frequency == .weekly && rule.interval == 2 {
                        Text(WorkspaceLocalization.string("隔周重复，以首次日期所在周为起点。")).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if rule.frequency.usesWeekdays {
                    ForEach(1...7, id: \.self) { day in
                        Toggle(WorkspaceDates.weekdayName(day), isOn: Binding(get: { rule.weekdays.contains(day) }, set: { enabled in
                            rule.weekdays.removeAll { $0 == day }; if enabled { rule.weekdays.append(day) }
                        }))
                    }
                    if rule.weekdays.isEmpty {
                        Text(WorkspaceLocalization.string("未选择星期时，沿用首次日期的星期。")).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if rule.frequency.usesWeekParity {
                Section(WorkspaceLocalization.string("单双周基准")) {
                    DatePicker(WorkspaceLocalization.string("第1周起始日"), selection: Binding(
                        get: { rule.weekOneStart ?? firstMonday },
                        set: { rule.weekOneStart = RecurrenceEngine.monday(containing: $0, calendar: record.calendar) }),
                        in: ...anchor, displayedComponents: .date)
                        .environment(\.timeZone, record.calendar.timeZone)
                    Text(WorkspaceLocalization.string("以所选日期所在周的周一为第1周，连续计算，不在跨年时重置。按教学周使用时，请选择学期第1周。"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section(WorkspaceLocalization.string("结束")) {
                Toggle(WorkspaceLocalization.string("设置结束日期"), isOn: Binding(get: { rule.until != nil }, set: { enabled in
                    rule.until = enabled ? record.calendar.date(byAdding: .month, value: 3, to: anchor) : nil
                }))
                if rule.until != nil {
                    DatePicker(WorkspaceLocalization.string("最后一天"), selection: Binding(get: { rule.until ?? anchor }, set: { rule.until = $0 }),
                        in: record.calendar.startOfDay(for: anchor)..., displayedComponents: .date)
                        .environment(\.timeZone, record.calendar.timeZone)
                }
            }
            if let message = RecurrenceEngine.validationError(record: record, rule: rule) {
                Section { Text(message).foregroundStyle(.red) }
            } else {
                Section(WorkspaceLocalization.string("接下来的重复日期")) {
                    if nextDates.isEmpty { Text(WorkspaceLocalization.string("所选范围内暂无重复日期。")).foregroundStyle(.secondary) }
                    ForEach(nextDates, id: \.self) { day in
                        Text(day, format: previewDayStyle)
                    }
                }
            }
            Section {
                Text(WorkspaceLocalization.string("当前事项保留。每次重复沿用原有时刻，计划、截止和自定义提醒会随日期一起移动；每次可以单独完成、改期或取消。"))
                    .font(.caption).foregroundStyle(.secondary)
                if rule.frequency == .workdays {
                    Text(WorkspaceLocalization.string("按中国大陆法定放假和调休，包含补班周末。内置日历覆盖2025—2026年；未覆盖年份暂停生成，更新调休日历后继续。学校另行调整的安排可单独修改实例。"))
                        .font(.caption).foregroundStyle(.secondary)
                    Link(WorkspaceLocalization.string("查看2026年官方调休安排"), destination: URL(string: ChinaWorkCalendar.source2026)!)
                } else if rule.frequency == .weekdays {
                    Text(WorkspaceLocalization.string("仅周一至周五，不调整法定节假日和周末补班。")).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .onAppear { prepareWeekSelection() }
        .onChange(of: rule.frequency) { _, _ in
            if !rule.frequency.supportsInterval { rule.interval = 1 }
            prepareWeekSelection()
        }
        .workspaceSelectionFeedback(trigger: rule.frequency)
        .workspaceSelectionFeedback(trigger: rule.weekdays)
    }
    private func prepareWeekSelection() {
        if rule.frequency.usesWeekdays && rule.weekdays.isEmpty {
            rule.weekdays = [(record.calendar.component(.weekday, from: anchor) + 5) % 7 + 1]
        }
        if rule.frequency.usesWeekParity && rule.weekOneStart == nil { rule.weekOneStart = firstMonday }
    }
}

/// The cover blocks input and survives the underlying detail's navigation change.
private struct WorkspaceCompletionTransition: View {
    @Environment(\.workspacePalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let title: String
    let returnToPrevious: @MainActor () -> Void
    let close: @MainActor () -> Void
    let complete: @MainActor () throws -> Void
    @State private var filled = false
    @State private var showingResult = false
    @State private var revealing = false
    @State private var failure: String?

    var body: some View {
        ZStack {
            Rectangle().fill(palette.action)
                .scaleEffect(x: 1, y: reduceMotion ? 1 : (filled ? 1 : 0), anchor: .top)
                .opacity(reduceMotion && !filled ? 0 : 1)
            VStack(spacing: 18) {
                Image(systemName: failure == nil ? "checkmark.circle.fill" : "exclamationmark.circle")
                    .font(.system(size: 64, weight: .medium))
                    .accessibilityHidden(true)
                Text(failure == nil ? WorkspaceLocalization.string("已完成") : WorkspaceLocalization.string("未能完成"))
                    .font(.largeTitle.bold())
                Text(failure ?? title)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                if failure != nil {
                    Button(WorkspaceLocalization.string("返回事项")) { Task { await revealAndClose() } }
                        .buttonStyle(.bordered)
                        .tint(.white)
                        .padding(.top, 8)
                }
            }
            .foregroundStyle(.white)
            .padding(32)
            .frame(maxWidth: 560)
            .opacity(showingResult ? 1 : 0)
            .scaleEffect(reduceMotion || showingResult ? 1 : 0.92)
        }
        .ignoresSafeArea()
        .mask {
            Rectangle().scaleEffect(x: 1, y: reduceMotion || !revealing ? 1 : 0, anchor: .bottom)
        }
        .opacity(reduceMotion && revealing ? 0 : 1)
        .task {
            withAnimation(reduceMotion ? .easeOut(duration: 0.18) : .timingCurve(0.72, 0, 0.16, 1, duration: 0.28)) { filled = true }
            do { try await Task.sleep(for: .milliseconds(reduceMotion ? 200 : 320)) }
            catch { return }
            guard !Task.isCancelled else { return }
            do { try complete() }
            catch { failure = error.localizedDescription }
            withAnimation(reduceMotion ? .easeOut(duration: 0.18) : .spring(duration: 0.3, bounce: 0.18)) {
                showingResult = true
            }
            guard failure == nil else { return }
            // The scene-level cover stays in place while navigation finishes below it.
            returnToPrevious()
            do { try await Task.sleep(for: .milliseconds(900)) } catch { return }
            await revealAndClose()
        }
    }
    @MainActor private func revealAndClose() async {
        guard !revealing else { return }
        withAnimation(reduceMotion ? .easeOut(duration: 0.18) : .timingCurve(0.72, 0, 0.16, 1, duration: 0.28)) {
            revealing = true
        }
        do { try await Task.sleep(for: .milliseconds(reduceMotion ? 200 : 320)) } catch { return }
        close()
    }
}

#if os(iOS)
/// The scene-level window survives navigation; its curtain animates outside SwiftUI layout.
@MainActor private final class WorkspaceCompletionWindowPresenter {
    weak var sourceView: UIView?
    private var window: UIWindow?

    func present(title: String, colorScheme: ColorScheme, fillColor: UIColor,
                 returnToPrevious: @escaping @MainActor () -> Void,
                 close: @escaping @MainActor () -> Void,
                 complete: @escaping @MainActor () throws -> Void) -> Bool {
        guard window == nil, let scene = sourceView?.window?.windowScene else { return false }
        let cover = UIWindow(windowScene: scene)
        cover.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.normal.rawValue + 1)
        cover.backgroundColor = .clear
        cover.overrideUserInterfaceStyle = colorScheme == .dark ? .dark : .light
        cover.rootViewController = WorkspaceCompletionCurtainController(title: title, fillColor: fillColor,
            returnToPrevious: returnToPrevious,
            // Retain the presenter until reveal finishes, even after its detail is popped.
            // close() clears the controller/window and breaks this temporary ownership cycle.
            close: { [self] in
                self.close()
                close()
            }, complete: complete)
        window = cover
        cover.isHidden = false
        return true
    }
    func close() {
        window?.isHidden = true
        window?.rootViewController = nil
        window = nil
    }
}

/// Animation completion callbacks sequence cover → save/return → result → reveal.
/// Saving occurs only while the curtain is stationary and fully opaque.
@MainActor private final class WorkspaceCompletionCurtainController: UIViewController {
    private let recordTitle: String
    private let fillColor: UIColor
    private let returnToPrevious: @MainActor () -> Void
    private let close: @MainActor () -> Void
    private let complete: @MainActor () throws -> Void
    private let curtain = UIView()
    private let result = UIStackView()
    private let symbol = UIImageView()
    private let heading = UILabel()
    private let message = UILabel()
    private let back = UIButton(type: .system)
    private var started = false
    private var exiting = false

    init(title: String, fillColor: UIColor, returnToPrevious: @escaping @MainActor () -> Void,
         close: @escaping @MainActor () -> Void, complete: @escaping @MainActor () throws -> Void) {
        recordTitle = title
        self.fillColor = fillColor
        self.returnToPrevious = returnToPrevious
        self.close = close
        self.complete = complete
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        view.clipsToBounds = true
        view.accessibilityViewIsModal = true
        curtain.isHidden = true
        curtain.backgroundColor = fillColor
        curtain.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(curtain)
        NSLayoutConstraint.activate([
            curtain.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            curtain.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            curtain.topAnchor.constraint(equalTo: view.topAnchor),
            curtain.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        result.axis = .vertical
        result.alignment = .center
        result.spacing = 16
        result.alpha = 0
        result.translatesAutoresizingMaskIntoConstraints = false
        curtain.addSubview(result)
        symbol.image = UIImage(systemName: "checkmark.circle.fill",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 64, weight: .medium))
        symbol.tintColor = .white
        symbol.contentMode = .scaleAspectFit
        symbol.isAccessibilityElement = false
        heading.text = WorkspaceLocalization.string("已完成")
        heading.font = .preferredFont(forTextStyle: .largeTitle)
        message.text = recordTitle
        message.font = .preferredFont(forTextStyle: .headline)
        for label in [heading, message] {
            label.textColor = .white
            label.textAlignment = .center
            label.numberOfLines = 0
            label.adjustsFontForContentSizeCategory = true
        }
        back.setTitle(WorkspaceLocalization.string("返回事项"), for: .normal)
        back.setTitleColor(.white, for: .normal)
        back.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        back.addTarget(self, action: #selector(reveal), for: .touchUpInside)
        back.isHidden = true
        for item in [symbol, heading, message, back] { result.addArrangedSubview(item) }
        NSLayoutConstraint.activate([
            result.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            result.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
            result.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 32),
            result.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -32),
            result.widthAnchor.constraint(lessThanOrEqualToConstant: 500),
            back.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
        ])
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !started else { return }
        started = true
        view.layoutIfNeeded()
        let reducedMotion = UIAccessibility.isReduceMotionEnabled
        curtain.transform = reducedMotion ? .identity : CGAffineTransform(translationX: 0, y: -view.bounds.height)
        curtain.alpha = reducedMotion ? 0 : 1
        curtain.isHidden = false
        // Commit the offscreen starting position before moving the fixed-size curtain.
        DispatchQueue.main.async { [weak self] in self?.cover() }
    }
    private func cover() {
        UIView.animate(withDuration: UIAccessibility.isReduceMotionEnabled ? 0.2 : 0.38,
                       delay: 0, options: [.curveEaseInOut, .beginFromCurrentState], animations: {
            self.curtain.alpha = 1
            self.curtain.transform = .identity
        }) { finished in
            if finished { self.covered() }
        }
    }
    private func covered() {
        do {
            try complete()
            returnToPrevious()
        } catch {
            heading.text = WorkspaceLocalization.string("未能完成")
            message.text = error.localizedDescription
            symbol.image = UIImage(systemName: "exclamationmark.circle",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 64, weight: .medium))
            back.isHidden = false
        }
        UIView.animate(withDuration: 0.16, animations: { self.result.alpha = 1 }) { _ in
            UIAccessibility.post(notification: .announcement, argument: self.heading.text)
            guard self.back.isHidden else { return }
            UIView.animate(withDuration: 0.12, delay: 0.35, options: [.beginFromCurrentState], animations: {
                self.result.alpha = 0
            }) { _ in self.reveal() }
        }
    }
    @objc private func reveal() {
        guard !exiting else { return }
        exiting = true
        UIView.animate(withDuration: UIAccessibility.isReduceMotionEnabled ? 0.2 : 0.38,
                       delay: 0, options: [.curveEaseInOut, .beginFromCurrentState], animations: {
            if UIAccessibility.isReduceMotionEnabled { self.curtain.alpha = 0 }
            else { self.curtain.transform = CGAffineTransform(translationX: 0, y: self.view.bounds.height) }
        }) { _ in self.close() }
    }
}

private struct WorkspaceCompletionWindowAnchor: UIViewRepresentable {
    let presenter: WorkspaceCompletionWindowPresenter
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        presenter.sourceView = view
        return view
    }
    func updateUIView(_ uiView: UIView, context: Context) {}
}
#endif
