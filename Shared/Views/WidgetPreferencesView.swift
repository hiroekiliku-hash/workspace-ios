#if os(iOS)
import SwiftUI

struct WidgetPreferencesView: View {
    @Environment(WorkspaceStore.self) private var store
    @Environment(\.workspacePalette) private var palette

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Image(systemName: "rectangle.on.rectangle")
                        .font(.largeTitle.weight(.medium))
                        .foregroundStyle(palette.action)
                    Text(WorkspaceLocalization.string("把下一步，放在桌面上"))
                        .font(.title2.bold())
                    Text(WorkspaceLocalization.string("看清今天的安排、留意临近的截止，或只关注一件事。不同组件可以拥有各自的偏好。"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 10)
            }

            Section {
                WidgetStylePreview(kind: .today)
                WidgetStylePreview(kind: .deadline)
                WidgetStylePreview(kind: .focus)
            } header: {
                Text(WorkspaceLocalization.string("三种桌面视角"))
            } footer: {
                Text(WorkspaceLocalization.string("以上为样式示意。桌面组件会显示你自己的安排。"))
            }

            Section {
                Toggle(isOn: Binding(get: { store.widgetSharingEnabled }, set: { enabled in
                    store.widgetSharingEnabled = enabled
                    store.publishWidgetSnapshot()
                })) {
                    Label(WorkspaceLocalization.string("分享待办到桌面"), systemImage: "square.grid.2x2")
                }
                .accessibilityIdentifier("widget-sharing-toggle")

                Button {
                    store.publishWidgetSnapshot(forceReload: true)
                } label: {
                    Label(WorkspaceLocalization.string("刷新桌面组件"), systemImage: "arrow.clockwise")
                }
                .disabled(!store.widgetSharingEnabled)
            } header: {
                Text(WorkspaceLocalization.string("桌面内容"))
            } footer: {
                Text(WorkspaceLocalization.string("仅共享标题、时间、项目名等日程摘要，不包含笔记、API 凭据或课程正文。关闭后，桌面组件不再显示内容。刷新时间由系统安排。"))
            }

            Section {
                WidgetPreferenceDescription(symbol: "line.3.horizontal.decrease", title: WorkspaceLocalization.string("想看什么"), detail: WorkspaceLocalization.string("选择内容、项目组、时间范围和排序，让每块组件各司其职。"))
                WidgetPreferenceDescription(symbol: "paintpalette", title: WorkspaceLocalization.string("喜欢的样子"), detail: WorkspaceLocalization.string("调整配色和信息密度，配合你的壁纸与桌面布局。"))
                WidgetPreferenceDescription(symbol: "eye.slash", title: WorkspaceLocalization.string("留一点隐私"), detail: WorkspaceLocalization.string("隐藏具体标题，让桌面只保留时间与数量等提示。"))
                WidgetPreferenceDescription(symbol: "hand.tap", title: WorkspaceLocalization.string("留在桌面翻看"), detail: WorkspaceLocalization.string("支持翻页的组件可直接切换条目；需要处理时，点内容进入 App。"))
            } header: {
                Text(WorkspaceLocalization.string("每块组件，自由定制"))
            } footer: {
                Text(WorkspaceLocalization.string("长按桌面上的组件，选择“编辑小组件”调整。可用选项随组件样式而变化，翻页不会完成或修改事项。"))
            }

            Section(WorkspaceLocalization.string("添加到桌面")) {
                WidgetSetupStep(number: "1", title: WorkspaceLocalization.string("长按桌面空白处"), detail: WorkspaceLocalization.string("进入桌面编辑模式。"))
                WidgetSetupStep(number: "2", title: WorkspaceLocalization.string("编辑 → 添加小组件"), detail: WorkspaceLocalization.string("搜索“工作坊”，选择样式和尺寸。"))
                WidgetSetupStep(number: "3", title: WorkspaceLocalization.string("长按组件，编辑偏好"), detail: WorkspaceLocalization.string("可以添加多块组件，分别关注不同的安排。"))
            }
        }
        .formStyle(.grouped)
        .navigationTitle(WorkspaceLocalization.string("桌面小组件"))
        .workspaceResponsiveTitle()
    }
}

private enum WidgetPreviewKind {
    case today, deadline, focus

    var title: String {
        switch self {
        case .today: WorkspaceLocalization.string("今日工作台")
        case .deadline: WorkspaceLocalization.string("截止倒计时")
        case .focus: WorkspaceLocalization.string("专注事项")
        }
    }

    var detail: String {
        switch self {
        case .today: WorkspaceLocalization.string("今天的节奏，一眼掌握")
        case .deadline: WorkspaceLocalization.string("让重要的时间有分量")
        case .focus: WorkspaceLocalization.string("给下一件事，留一块空间")
        }
    }

    var symbol: String {
        switch self {
        case .today: "sun.max"
        case .deadline: "hourglass"
        case .focus: "scope"
        }
    }
}

private struct WidgetStylePreview: View {
    @Environment(\.workspacePalette) private var palette
    let kind: WidgetPreviewKind

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 9) {
                Image(systemName: kind.symbol).foregroundStyle(palette.action)
                Text(kind.title).font(.headline)
            }
            preview
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(palette.action.opacity(0.08), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(WorkspaceLocalization.format("%@样式示意", String(describing: kind.title)))
            Text(kind.detail).font(.subheadline).foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder private var preview: some View {
        switch kind {
        case .today:
            VStack(alignment: .leading, spacing: 13) {
                HStack {
                    Text(WorkspaceLocalization.string("今天")).font(.caption.weight(.semibold)).foregroundStyle(palette.action)
                    Spacer()
                    Text(WorkspaceLocalization.string("周一")).font(.caption).foregroundStyle(.secondary)
                }
                sampleRow(time: "09:00", title: WorkspaceLocalization.string("整理这一周的计划"), starred: false)
                sampleRow(time: "14:30", title: WorkspaceLocalization.string("完成课程练习"), starred: true)
            }
        case .deadline:
            VStack(alignment: .leading, spacing: 8) {
                Text(WorkspaceLocalization.string("课程报告")).font(.subheadline.weight(.semibold))
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text("02").font(.system(size: 40, weight: .bold, design: .monospaced))
                    Text(WorkspaceLocalization.string("天")).font(.caption.weight(.medium))
                    Text("06").font(.system(size: 40, weight: .bold, design: .monospaced))
                    Text(WorkspaceLocalization.string("时")).font(.caption.weight(.medium))
                }
                .foregroundStyle(palette.action)
                Text(WorkspaceLocalization.string("周三 · 18:00 截止")).font(.caption).foregroundStyle(.secondary)
            }
        case .focus:
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: "star.fill").foregroundStyle(.orange)
                    Text(WorkspaceLocalization.string("下一件事")).foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(palette.action)
                }
                .font(.caption.weight(.semibold))
                Text(WorkspaceLocalization.string("为今天留一点\n专注的时间"))
                    .font(.title3.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(WorkspaceLocalization.string("个人安排 · 今天")).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func sampleRow(time: String, title: String, starred: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(time).font(.caption.monospacedDigit()).foregroundStyle(palette.action)
            Text(title).font(.subheadline.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if starred { Image(systemName: "star.fill").font(.caption).foregroundStyle(.orange) }
        }
    }
}

private struct WidgetPreferenceDescription: View {
    @Environment(\.workspacePalette) private var palette
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.body.weight(.medium))
                .foregroundStyle(palette.action)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.body.weight(.medium))
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct WidgetSetupStep: View {
    @Environment(\.workspacePalette) private var palette
    let number: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number)
                .font(.caption.weight(.bold).monospacedDigit())
                .foregroundStyle(palette.action)
                .frame(width: 26, height: 26)
                .background(palette.action.opacity(0.10), in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.body.weight(.medium))
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
    }
}
#endif
