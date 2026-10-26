#if os(iOS)
import SwiftUI

struct WorkspaceTimelineView: View {
    @Environment(WorkspaceStore.self) private var store

    var body: some View {
        let presentation = TimelinePresentation(records: store.state.records, timezone: store.state.profile.timezone)
        Group {
            if presentation.groups.isEmpty {
                ContentUnavailableView {
                    Label(WorkspaceLocalization.string("还没有时间安排"), systemImage: "clock")
                } description: {
                    Text(WorkspaceLocalization.string("为事项设置计划时间，或添加截止事项，就会出现在这里。"))
                } actions: {
                    Button(WorkspaceLocalization.string("新建事项"), systemImage: "plus") { store.createKind = .task }
                }
            } else {
                TimelineWheel(presentation: presentation, hapticsEnabled: store.hapticsEnabled)
            }
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(WorkspaceLocalization.string("时间线"))
        .workspaceResponsiveTitle()
    }
}

private struct TimelineWheel: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .body) private var rowHeight: CGFloat = 64
    @State private var motion = TimelineWheelMotion()
    let presentation: TimelinePresentation
    let hapticsEnabled: Bool

    private struct Configuration: Equatable {
        let presentation: TimelinePresentation
        let layout: TimelineWheelLayout
        let reduceMotion: Bool
    }

    var body: some View {
        let layout = TimelineWheelLayout(presentation: presentation, rowHeight: rowHeight)
        let configuration = Configuration(presentation: presentation, layout: layout, reduceMotion: reduceMotion)
        TimelineWheelSurface(presentation: presentation, layout: layout, motion: motion,
            rowHeight: rowHeight, reduceMotion: reduceMotion, hapticsEnabled: hapticsEnabled)
            .onAppear { motion.configure(presentation, layout: layout, reduceMotion: reduceMotion) }
            .onChange(of: configuration) { _, value in
                motion.configure(value.presentation, layout: value.layout, reduceMotion: value.reduceMotion)
            }
            .onDisappear { motion.stop() }
    }
}

private struct TimelineWheelSurface: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var openedRecord: UUID?
    let presentation: TimelinePresentation
    let layout: TimelineWheelLayout
    let motion: TimelineWheelMotion
    let rowHeight: CGFloat
    let reduceMotion: Bool
    let hapticsEnabled: Bool

    private var focusedGroup: TimelinePresentation.Group {
        presentation.groups[min(motion.focusedIndex, presentation.groups.count - 1)]
    }

    var body: some View {
        GeometryReader { geometry in
            if geometry.size.width >= 680 && !typeSize.isAccessibilitySize {
                HStack(spacing: 16) {
                    TimelineWheelHeader(presentation: presentation, motion: motion, sidePanel: true)
                        .frame(width: 164)
                    wheelTrack(size: CGSize(width: max(1, geometry.size.width - 212), height: geometry.size.height - 16))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .accessibilityIdentifier("timeline-landscape-layout")
            } else {
                VStack(spacing: 0) {
                    TimelineWheelHeader(presentation: presentation, motion: motion)
                    GeometryReader { track in wheelTrack(size: track.size) }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 8)
                }
            }
        }
        .sensoryFeedback(.impact(weight: .light, intensity: 0.8), trigger: motion.selectionTick) { _, _ in hapticsEnabled }
        .sensoryFeedback(.impact(weight: .medium, intensity: 0.9), trigger: motion.dayTick) { _, _ in hapticsEnabled }
        .sensoryFeedback(.impact(weight: .heavy, intensity: 1), trigger: motion.edgeTick) { _, _ in hapticsEnabled }
        .sensoryFeedback(.impact(weight: .medium, intensity: 0.85), trigger: motion.isScrubbing) { _, value in hapticsEnabled && value }
        .navigationDestination(item: $openedRecord) { id in RecordDetailView(id: id) }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { motion.move(to: motion.focusedIndex) }
            else { motion.stop() }
        }
    }

    private func wheelTrack(size: CGSize) -> some View {
        HStack(spacing: 12) {
            TimelineScrubber(motion: motion, height: max(1, size.height),
                value: focusedGroup.dayLabel + " " + focusedGroup.timeLabel)
                .frame(width: 44)
            TimelineWheelCards(presentation: presentation, layout: layout, motion: motion,
                rowHeight: rowHeight, reduceMotion: reduceMotion,
                size: CGSize(width: max(1, size.width - 56), height: max(1, size.height)),
                open: openRecord)
        }
    }

    private func openRecord(_ id: UUID) {
        if motion.prepareToOpen(id) { openedRecord = id }
    }
}

/// Date navigation observes the focused group, not the per-frame scroll position.
private struct TimelineWheelHeader: View {
    let presentation: TimelinePresentation
    let motion: TimelineWheelMotion
    var sidePanel = false

    var body: some View {
        let index = min(motion.focusedIndex, presentation.groups.count - 1)
        let group = presentation.groups[index]
        let layout = sidePanel
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 16))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 12))
        layout {
            ScheduleDateHeading(month: group.monthLabel, day: group.dateLabel)
            Spacer(minLength: 8)
            if sidePanel {
                HStack(spacing: 8) {
                    Button(WorkspaceLocalization.string("上一时间段"), systemImage: "chevron.up") { motion.move(to: index - 1) }
                        .disabled(index == 0)
                    Button(WorkspaceLocalization.string("下一时间段"), systemImage: "chevron.down") { motion.move(to: index + 1) }
                        .disabled(index == presentation.groups.count - 1)
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
            ScheduleTodayButton(large: sidePanel, hint: WorkspaceLocalization.string("回到今天最近的时间段")) {
                motion.move(to: presentation.initialIndex())
            }
        }
        .padding(.horizontal, sidePanel ? 4 : 20)
        .padding(.top, 10)
        .padding(.bottom, sidePanel ? 10 : 14)
    }
}

/// Only this small positioning surface observes the display-link position.
private struct TimelineWheelCards: View {
    @Environment(\.workspaceRecordDragSession) private var recordDragSession
    let presentation: TimelinePresentation
    let layout: TimelineWheelLayout
    let motion: TimelineWheelMotion
    let rowHeight: CGFloat
    let reduceMotion: Bool
    let size: CGSize
    let open: (UUID) -> Void

    var body: some View {
        // Only neighbors enter the render tree; sorting and grouping stay outside the frame loop.
        let focus = min(motion.focusedIndex, presentation.groups.count - 1)
        let lower = max(0, focus - 6)
        let upper = min(presentation.groups.count, focus + 7)
        // Position stays continuous; text only re-renders at distinct emphasis levels.
        let reading = (motion.readingEmphasis * 20).rounded() / 20
        return ZStack(alignment: .topLeading) {
            Color.clear
            ForEach(lower..<upper, id: \.self) { index in
                let distance = layout.anchors[index] - motion.position
                let offset = TimelineWheelLayout.projected(distance, height: size.height)
                let progress = min(1, abs(offset) / max(1, size.height * 0.6))
                let scale = reduceMotion ? 1 : 1 - 0.36 * pow(progress, 1.15)
                let height = layout.heights[index]
                let centered = motion.isCentered(at: layout.anchors[index])
                // Softness uses a few levels; fast browsing favors readable, inexpensive compositing.
                let blur: CGFloat = reduceMotion ? 0 :
                    (pow(progress, 2.5) * 3.5 * (1 - 0.72 * reading) * 2).rounded() / 2
                if abs(offset) < size.height / 2 + height / 2 {
                    TimelineEventCard(group: presentation.groups[index],
                        rowHeight: rowHeight, headerHeight: layout.headerHeight,
                        focused: index == motion.focusedIndex,
                        readingEmphasis: reading, reduceMotion: reduceMotion,
                        peripheralBlur: blur,
                        peripheralOpacity: reduceMotion ? 1 : 1 - 0.67 * Double(pow(progress, 1.5)),
                        open: open)
                    .accessibilityHidden(!centered)
                    .overlay {
                        if !centered {
                            // The whole peripheral card is a focus target, including its padding.
                            Button {
                                guard motion.acceptsTap else { return }
                                motion.move(to: index)
                            } label: {
                                RoundedRectangle(cornerRadius: 22, style: .continuous)
                                    .fill(Color.clear)
                                    .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(presentation.groups[index].focusLabel)
                            .accessibilityHint(WorkspaceLocalization.string("移到中央后，再点事项可打开详情"))
                        }
                    }
                    .frame(width: size.width, height: height)
                    .scaleEffect(scale, anchor: .leading)
                    .offset(y: size.height / 2 + offset - height / 2)
                    .zIndex(1 - Double(progress))
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .contentShape(Rectangle())
        .highPriorityGesture(DragGesture(minimumDistance: 8)
            .onChanged {
                guard recordDragSession?.recordID == nil else { return }
                motion.drag(translation: $0.translation.height)
            }
            .onEnded {
                guard recordDragSession?.recordID == nil else { return }
                motion.releaseDrag(velocity: $0.velocity.height)
            }, including: recordDragSession?.recordID == nil ? .all : .none)
        .onChange(of: recordDragSession?.recordID) { _, id in
            if id != nil { motion.stop() }
        }
        .clipped()
        .mask {
            LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.07),
                .init(color: .black, location: 0.93), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom)
        }
        .accessibilityScrollAction { direction in
            switch direction {
            case .top: motion.move(to: motion.focusedIndex + 1)
            case .bottom: motion.move(to: motion.focusedIndex - 1)
            default: break
            }
        }
    }
}

private struct TimelineScrubber: View {
    @Environment(\.workspacePalette) private var palette
    let motion: TimelineWheelMotion
    let height: CGFloat
    let value: String

    var body: some View {
        ZStack {
            Capsule()
                .fill(palette.accent.opacity(0.16))
                .frame(width: 8, height: max(1, height - 40))
            VStack(spacing: 0) {
                Image(systemName: "chevron.up")
                Spacer()
                Image(systemName: "chevron.down")
            }
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(palette.accent.opacity(0.6))
            .padding(.vertical, 8)
            VStack(spacing: 4) {
                ForEach(0..<3) { _ in Capsule().fill(.white.opacity(0.9)).frame(width: 10, height: 2) }
            }
            .frame(width: motion.isScrubbing ? 24 : 20, height: motion.isScrubbing ? 70 : 62)
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: motion.isScrubbing)
            .background(LinearGradient(colors: [palette.action, palette.action.opacity(0.8)],
                startPoint: .top, endPoint: .bottom), in: Capsule())
            .shadow(color: palette.accent.opacity(0.22), radius: 8, y: 3)
            .offset(y: motion.thumbOffset)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { motion.scrub(translation: $0.translation.height, travel: max(1, height / 2 - 62)) }
            .onEnded { _ in motion.releaseScrubber() })
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(WorkspaceLocalization.string("时间轴"))
        .accessibilityValue(value)
        .accessibilityHint(WorkspaceLocalization.string("上下拖动滑块，越靠近两端滚动越快，松手回中"))
        .accessibilityAdjustableAction { direction in
            motion.move(to: motion.focusedIndex + (direction == .increment ? 1 : -1))
        }
    }
}

private struct TimelineEventCard: View {
    @Environment(\.workspacePalette) private var palette
    @Environment(\.colorScheme) private var colorScheme
    let group: TimelinePresentation.Group
    let rowHeight: CGFloat
    let headerHeight: CGFloat
    let focused: Bool
    let readingEmphasis: CGFloat
    let reduceMotion: Bool
    let peripheralBlur: CGFloat
    let peripheralOpacity: Double
    let open: (UUID) -> Void

    private var textScale: CGFloat { reduceMotion ? 1 : 1 + 0.07 * readingEmphasis }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TimelineCardHeader(day: group.dayLabel, time: group.timeLabel,
                readingEmphasis: readingEmphasis, textScale: textScale)
            .equatable()
            .blur(radius: peripheralBlur * (1 - readingEmphasis))
            .opacity(peripheralOpacity + (1 - peripheralOpacity) * Double(readingEmphasis))
            .frame(height: headerHeight, alignment: .top)

            TimelineEventRows(events: group.events, rowHeight: rowHeight,
                showsTime: !group.allDay && group.events.count > 1,
                readingEmphasis: readingEmphasis, textScale: textScale, open: open)
            .equatable()
            .blur(radius: peripheralBlur)
            .opacity(peripheralOpacity)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 18)
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
                .overlay {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(LinearGradient(colors: [palette.accent.opacity(colorScheme == .dark ? 0.13 : 0.07), .clear],
                            startPoint: .topLeading, endPoint: .bottomTrailing))
                }
                .opacity(peripheralOpacity)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(palette.accent.opacity(focused ? 0.18 : 0.04), lineWidth: 1)
                .opacity(peripheralOpacity)
        }
    }
}

/// These text subtrees stay unchanged while only the card's outer transform moves.
private struct TimelineCardHeader: View, Equatable {
    let day: String
    let time: String
    let readingEmphasis: CGFloat
    let textScale: CGFloat

    var body: some View {
        HStack(spacing: 8) {
            Text(day).scaleEffect(textScale, anchor: .leading)
            Spacer(minLength: 0)
            Text(time).monospacedDigit().scaleEffect(textScale, anchor: .trailing)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(Color.primary.opacity(0.48 + 0.52 * Double(readingEmphasis)))
    }
}

private struct TimelineEventRows: View, Equatable {
    let events: [TimelinePresentation.Event]
    let rowHeight: CGFloat
    let showsTime: Bool
    let readingEmphasis: CGFloat
    let textScale: CGFloat
    let open: (UUID) -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        // The action always resolves IDs through the live motion model; no index is captured.
        lhs.events == rhs.events && lhs.rowHeight == rhs.rowHeight && lhs.showsTime == rhs.showsTime
            && lhs.readingEmphasis == rhs.readingEmphasis && lhs.textScale == rhs.textScale
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(events) { event in
                TimelineEventRow(event: event, rowHeight: rowHeight, showsTime: showsTime,
                    readingEmphasis: readingEmphasis, textScale: textScale) { open(event.id) }
            }
        }
    }
}

private struct TimelineEventRow: View {
    @Environment(WorkspaceStore.self) private var store
    @Environment(\.workspacePalette) private var palette
    let event: TimelinePresentation.Event
    let rowHeight: CGFloat
    let showsTime: Bool
    let readingEmphasis: CGFloat
    let textScale: CGFloat
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(alignment: .center, spacing: 10) {
                status
                VStack(alignment: .leading, spacing: 4) {
                    Text(event.title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(event.finished ? Color.workspaceCompleted : Color.primary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .scaleEffect(textScale, anchor: .leading)
                    HStack(spacing: 5) {
                        if event.deadline { Text(WorkspaceLocalization.string("截止")) }
                        if showsTime { Text(event.timeLabel).monospacedDigit() }
                        if let project = event.projectTitle { Text(project).lineLimit(1) }
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(event.finished ? Color.workspaceCompleted : event.overdue ? Color.red : Color.secondary)
                    .opacity(1 - Double(readingEmphasis))
                }
            }
            .frame(maxWidth: .infinity, minHeight: rowHeight, maxHeight: rowHeight, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(event.accessibilityLabel)
        .accessibilityHint(WorkspaceLocalization.string("打开事项详情"))
        .workspaceRecordDragSource(store.record(event.id))
    }

    @ViewBuilder private var status: some View {
        if event.finished {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.workspaceCompleted)
                .font(.system(size: 13, weight: .medium)).frame(width: 16)
        } else if event.pinned {
            Image(systemName: "star.fill").foregroundStyle(.orange)
                .font(.system(size: 13, weight: .semibold)).frame(width: 16)
        } else if event.overdue {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
                .font(.system(size: 13, weight: .medium)).frame(width: 16)
        } else {
            Circle().fill(palette.accent).frame(width: 6, height: 6).frame(width: 16)
        }
    }
}

#endif
