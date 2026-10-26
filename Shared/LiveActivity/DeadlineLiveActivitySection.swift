#if os(iOS)
import SwiftUI

struct LiveActivityPreferencesSection: View {
    @Environment(WorkspaceStore.self) private var store

    var body: some View {
        let coordinator = store.liveActivity
        Section {
            Toggle(WorkspaceLocalization.string("自动追踪截止事项"), isOn: Binding(get: { coordinator.automaticTracking }, set: {
                coordinator.setAutomaticTracking($0, in: store.state)
            }))
            .disabled(coordinator.working)
            Picker(WorkspaceLocalization.string("锁屏卡片外观"), selection: Binding(get: { coordinator.lockScreenAppearance }, set: {
                coordinator.setLockScreenAppearance($0, in: store.state)
            })) {
                Text(WorkspaceLocalization.string("跟随系统")).tag("system")
                Text(WorkspaceLocalization.string("半透明浅色")).tag("light")
                Text(WorkspaceLocalization.string("半透明深色")).tag("dark")
            }
            .disabled(coordinator.working)
            if !coordinator.enabled {
                Label(WorkspaceLocalization.string("请在 iPhone 设置中允许实时活动"), systemImage: "info.circle")
                    .foregroundStyle(.secondary)
            } else if !coordinator.activeRecordIDs.isEmpty {
                LabeledContent(WorkspaceLocalization.string("正在追踪"), value: WorkspaceLocalization.format("%@ 项", String(describing: coordinator.activeRecordIDs.count)))
                    .foregroundStyle(.secondary)
            }
            if let message = coordinator.message {
                Text(message).font(.caption).foregroundStyle(.red)
            }
        } header: {
            Text(WorkspaceLocalization.string("锁屏与灵动岛"))
        } footer: {
            Text(WorkspaceLocalization.string("自动显示截止前 8 小时内最近的最多三项，共用一张实时活动卡片。关闭后，可在事项详情中手动开始追踪。"))
        }
        .workspaceSelectionFeedback(trigger: coordinator.automaticTracking)
        .workspaceSelectionFeedback(trigger: coordinator.lockScreenAppearance)
        .sensoryFeedback(.error, trigger: coordinator.message) { _, value in store.hapticsEnabled && value != nil }
    }
}

struct DeadlineLiveActivitySection: View {
    @Environment(\.workspacePalette) private var palette
    @Environment(WorkspaceStore.self) private var store
    let record: WorkspaceRecord

    var body: some View {
        Section(WorkspaceLocalization.string("锁屏与灵动岛")) {
            let coordinator = store.liveActivity
            if coordinator.automaticTracking {
                Label(coordinator.activeRecordIDs.contains(record.id) ? WorkspaceLocalization.string("已加入实时活动") : WorkspaceLocalization.string("由自动追踪选择"), systemImage: "waveform.path")
                    .font(.subheadline)
                    .foregroundStyle(coordinator.activeRecordIDs.contains(record.id) ? palette.accent : Color.secondary)
            } else {
                TimelineView(.periodic(from: .now, by: 15)) { context in
                    let tracking = coordinator.activeRecordIDs.contains(record.id)
                    let eligible = coordinator.enabled && DeadlineTrackingPolicy.dueDate(for: record, in: store.state, now: context.date) != nil
                    VStack(alignment: .leading, spacing: 14) {
                        if tracking {
                            Label(WorkspaceLocalization.string("正在实时追踪"), systemImage: "waveform.path")
                                .font(.subheadline.weight(.medium)).foregroundStyle(palette.accent)
                            Button(WorkspaceLocalization.string("结束追踪"), systemImage: "stop.fill") { coordinator.end() }
                                .buttonStyle(WorkspacePrimaryButtonStyle(tint: .secondary, prominent: false))
                                .disabled(coordinator.working)
                        } else if eligible {
                            Button(coordinator.activeRecordID == nil ? WorkspaceLocalization.string("开始实时追踪") : WorkspaceLocalization.string("追踪此事项"), systemImage: "waveform.path") {
                                coordinator.start(record.id, in: store.state)
                            }
                            .buttonStyle(WorkspacePrimaryButtonStyle(prominent: false))
                            .disabled(coordinator.working)
                        }
                        Text(coordinator.enabled ? DeadlineTrackingPolicy.explanation(for: record, in: store.state, now: context.date) : WorkspaceLocalization.string("系统未允许实时活动，可在 iPhone 设置中开启。"))
                            .font(.caption).foregroundStyle(.secondary)
                        if let message = coordinator.message { Text(message).font(.caption).foregroundStyle(.red) }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .sensoryFeedback(.success, trigger: store.liveActivity.activeRecordIDs) { _, _ in store.hapticsEnabled }
        .sensoryFeedback(.error, trigger: store.liveActivity.message) { _, value in store.hapticsEnabled && value != nil }
    }
}
#endif
