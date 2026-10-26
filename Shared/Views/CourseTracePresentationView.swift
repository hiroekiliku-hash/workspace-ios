import SwiftUI

/// One statement and its resulting state. The author supplies the trace; no code executes here.
struct CourseTracePresentationView<FinalActions: View>: View {
    @AppStorage(CourseLearningControlSide.preferenceKey) private var controlSide = CourseLearningControlSide.right.rawValue
    let trace: CourseTraceContent
    var sourceIsPinned = false
    var fitsViewport = false
    var onSourceChange: ((CourseCodeSample) -> Void)? = nil
    var onContinue: (() -> Void)? = nil
    private let hasFinalActions: Bool
    private let finalActions: FinalActions

    @Environment(\.workspacePalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .caption) private var sourceHeaderBudget: CGFloat = 44
    @State private var variantIndex = 0
    @State private var frameIndex = 0
    @State private var primaryContentHeight: CGFloat = 200

    init(trace: CourseTraceContent, sourceIsPinned: Bool = false, fitsViewport: Bool = false,
         onSourceChange: ((CourseCodeSample) -> Void)? = nil, onContinue: (() -> Void)? = nil)
        where FinalActions == EmptyView {
        self.trace = trace
        self.sourceIsPinned = sourceIsPinned
        self.fitsViewport = fitsViewport
        self.onSourceChange = onSourceChange
        self.onContinue = onContinue
        hasFinalActions = false
        finalActions = EmptyView()
    }

    init(trace: CourseTraceContent, sourceIsPinned: Bool = false, fitsViewport: Bool = false,
         onSourceChange: ((CourseCodeSample) -> Void)? = nil, @ViewBuilder finalActions: () -> FinalActions) {
        self.trace = trace
        self.sourceIsPinned = sourceIsPinned
        self.fitsViewport = fitsViewport
        self.onSourceChange = onSourceChange
        hasFinalActions = true
        self.finalActions = finalActions()
    }

    private var variant: CourseTraceVariant? {
        trace.variants.indices.contains(variantIndex) ? trace.variants[variantIndex] : nil
    }

    private var frame: CourseTraceFrame? {
        guard let variant, variant.frames.indices.contains(frameIndex) else { return nil }
        return variant.frames[frameIndex]
    }

    private var position: String { "\(variantIndex):\(frameIndex)" }

    var body: some View {
        Group {
            if let variant, let frame {
                if fitsViewport {
                    viewport(variant: variant, frame: frame)
                } else {
                    VStack(alignment: .leading, spacing: 24) {
                        header(variant: variant)
                        if !sourceIsPinned {
                            CourseProgramReferenceView(code: highlightedSource(variant: variant, frame: frame))
                        }
                        Text(verbatim: frame.title)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("course.trace.statement")
                        if let output = frame.output {
                            outputResult(output)
                        } else {
                            objects(frame.objects)
                        }
                        Text(verbatim: frame.note)
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .accessibilityIdentifier("course.trace.note")
                        controls(variant: variant)
                    }
                    .frame(maxWidth: 620, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
            } else {
                ContentUnavailableView("暂无推演步骤", systemImage: "curlybraces")
            }
        }
        .onChange(of: position, initial: true) { _, _ in
            if let variant, let frame {
                onSourceChange?(highlightedSource(variant: variant, frame: frame))
            }
        }
        .workspaceSelectionFeedback(trigger: position)
    }

    private func viewport(variant: CourseTraceVariant, frame: CourseTraceFrame) -> some View {
        GeometryReader { geometry in
            #if os(iOS)
            let columns = geometry.size.width >= 520 && geometry.size.width > geometry.size.height
            #else
            let columns = geometry.size.width >= 620
            #endif
            if columns && !typeSize.isAccessibilitySize {
                landscapeViewport(variant: variant, frame: frame, size: geometry.size)
            } else {
                portraitViewport(variant: variant, frame: frame)
            }
        }
        #if os(iOS)
        .overlay(alignment: CourseLearningControlSide(rawValue: controlSide)?.alignment ?? .bottomTrailing) {
            controls(variant: variant).padding(.horizontal, 20).padding(.vertical, 6)
        }
        #else
        .safeAreaInset(edge: .bottom, spacing: 0) {
            controls(variant: variant).padding(.horizontal, 20).padding(.vertical, 6)
        }
        #endif
        .accessibilityIdentifier("course.trace.viewport")
    }

    /// Source and state scroll independently; iPhone actions float over content.
    private func landscapeViewport(variant: CourseTraceVariant, frame: CourseTraceFrame, size: CGSize) -> some View {
        let columnWidth = max(0, (size.width - 44) / 2)
        return HStack(alignment: .top, spacing: 12) {
            CourseProgramReferenceView(
                code: highlightedSource(variant: variant, frame: frame),
                maximumHeight: max(36, size.height - 24 - sourceHeaderBudget))
                .frame(width: columnWidth, alignment: .topLeading)
                .frame(maxHeight: .infinity, alignment: .top)
            VStack(spacing: 6) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        viewportHeading(variant: variant, frame: frame)
                        if let output = frame.output {
                            outputResult(output)
                        } else {
                            objects(frame.objects, availableWidth: columnWidth)
                        }
                        Text(verbatim: frame.note)
                            .font(.subheadline).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier("course.trace.note")
                    }
                    .padding(.bottom, 6)
                }
                .id(position)
                .accessibilityIdentifier("course.trace.primary")
                #if os(iOS)
                .contentMargins(.bottom, 136, for: .scrollContent)
                #endif
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .frame(width: size.width, height: size.height, alignment: .top)
        .accessibilityIdentifier("course.trace.landscape")
    }

    /// Share the available height between source and state, including the heading
    /// in the scrollable section so small windows and large type remain usable.
    private func portraitViewport(variant: CourseTraceVariant, frame: CourseTraceFrame) -> some View {
        GeometryReader { geometry in
            let reservedPrimary = min(primaryContentHeight, max(120, geometry.size.height * 0.45))
            let sourceLimit = max(36, geometry.size.height - reservedPrimary - sourceHeaderBudget - 24)
            VStack(spacing: 8) {
                CourseProgramReferenceView(code: highlightedSource(variant: variant, frame: frame), maximumHeight: sourceLimit)
                    .frame(maxWidth: 620)
                    .padding(.horizontal, 20).padding(.top, 8)
                    .frame(maxWidth: .infinity)
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        viewportHeading(variant: variant, frame: frame)
                        if let output = frame.output {
                            outputResult(output)
                        } else {
                            objects(frame.objects, availableWidth: geometry.size.width - 40)
                        }
                        Text(verbatim: frame.note)
                            .font(.subheadline).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier("course.trace.note")
                    }
                    .frame(maxWidth: 620)
                    .padding(.bottom, 8)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                        if abs(primaryContentHeight - height) > 0.5 {
                            var transaction = Transaction()
                            transaction.animation = nil
                            withTransaction(transaction) { primaryContentHeight = height }
                        }
                    }
                    .padding(.horizontal, 20).frame(maxWidth: .infinity)
                }
                .id(position)
                .accessibilityIdentifier("course.trace.primary")
                #if os(iOS)
                .contentMargins(.bottom, 136, for: .scrollContent)
                #endif
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
        }
    }

    private func viewportHeading(variant: CourseTraceVariant, frame: CourseTraceFrame) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Text(verbatim: frame.title)
                .font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("course.trace.statement")
            Text("\(frameIndex + 1) / \(variant.frames.count)")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                .fixedSize()
            traceMenu
        }
    }

    private func header(variant: CourseTraceVariant) -> some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: variant.title).font(.headline)
                Text("\(frameIndex + 1) / \(variant.frames.count)")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("第 \(frameIndex + 1) 步，共 \(variant.frames.count) 步")
            }
            Spacer(minLength: 0)
            traceMenu
        }
    }

    private var traceMenu: some View {
        Menu {
            ForEach(trace.variants.indices, id: \.self) { index in
                Button {
                    move(toVariant: index, frame: 0)
                } label: {
                    if index == variantIndex {
                        Label(trace.variants[index].title, systemImage: "checkmark")
                    } else {
                        Text(verbatim: trace.variants[index].title)
                    }
                }
            }
            Divider()
            Button("从这段代码重新开始", systemImage: "arrow.counterclockwise") {
                move(toVariant: variantIndex, frame: 0)
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.body.weight(.semibold))
                .frame(width: 32, height: 44)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .foregroundStyle(.secondary)
        .accessibilityLabel("推演选项")
    }

    private func highlightedSource(variant: CourseTraceVariant, frame: CourseTraceFrame) -> CourseCodeSample {
        var code = variant.code
        code.highlightLines = (frame.focusSpans ?? []).isEmpty ? [frame.line] : []
        code.highlightSpans = frame.focusSpans
        return code
    }

    private func objects(_ objects: [CourseTraceObject], availableWidth: CGFloat = .infinity) -> some View {
        let columns = Array(
            repeating: GridItem(.flexible(), spacing: 12, alignment: .top),
            count: typeSize.isAccessibilitySize || objects.count == 1 || availableWidth < 300 ? 1 : 2
        )
        return LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
            ForEach(objects, id: \.id) { object in
                CourseTraceObjectView(object: object, compact: fitsViewport)
            }
        }
    }

    private func outputResult(_ output: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("输出").font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
            Text(verbatim: output.isEmpty ? WorkspaceLocalization.string("（无输出）") : output)
                .font(.system(.largeTitle, design: .monospaced, weight: .bold))
                .foregroundStyle(palette.accent)
                .contentTransition(.numericText())
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("course.trace.output")
    }

    private func controls(variant: CourseTraceVariant) -> some View {
        let back = Button(action: goBack) {
                Label("上一步", systemImage: "arrow.left")
            }
            .modifier(CourseLearningActionStyle(prominent: false))
            .disabled(variantIndex == 0 && frameIndex == 0)
            .accessibilityLabel("上一步")
            #if os(macOS)
            .keyboardShortcut(.leftArrow, modifiers: [.command, .shift])
            .help(WorkspaceLocalization.string("推演上一步（⇧⌘←）"))
            #endif
        let next = Button(action: advance) {
                Label(nextTitle(variant: variant), systemImage: "arrow.right")
            }
            .modifier(CourseLearningActionStyle())
            .accessibilityLabel(nextTitle(variant: variant))
            .help(nextTitle(variant: variant))
            .accessibilityIdentifier("course.trace.next")
            #if os(macOS)
            .keyboardShortcut(.rightArrow, modifiers: [.command, .shift])
            .help(nextTitle(variant: variant) + "（⇧⌘→）")
            #endif
        #if os(iOS)
        return VStack(spacing: 12) { next; back }
            .modifier(CourseLearningGlassGroup())
        #else
        return HStack(alignment: .bottom, spacing: 12) {
            back
            if hasFinalActions && isLastFrame(variant) && variantIndex == trace.variants.count - 1 {
                // A lesson ending in a trace has one action row: after the last
                // state is visible, its usual completion controls take over.
                finalActions
            } else {
                Spacer(minLength: 12)
                next
            }
        }
            .modifier(CourseLearningGlassGroup())
        #endif
    }

    private func isLastFrame(_ variant: CourseTraceVariant) -> Bool {
        frameIndex == variant.frames.count - 1
    }

    private func nextTitle(variant: CourseTraceVariant) -> String {
        guard isLastFrame(variant) else { return WorkspaceLocalization.string("执行下一步") }
        if trace.variants.indices.contains(variantIndex + 1) {
            return WorkspaceLocalization.format("试试%@", trace.variants[variantIndex + 1].title)
        }
        return onContinue == nil ? WorkspaceLocalization.string("重新观察") : WorkspaceLocalization.string("继续课程")
    }

    private func advance() {
        guard let variant else { return }
        if !isLastFrame(variant) {
            move(toVariant: variantIndex, frame: frameIndex + 1)
        } else if trace.variants.indices.contains(variantIndex + 1) {
            move(toVariant: variantIndex + 1, frame: 0)
        } else if let onContinue {
            onContinue()
        } else {
            move(toVariant: 0, frame: 0)
        }
    }

    private func goBack() {
        if frameIndex > 0 {
            move(toVariant: variantIndex, frame: frameIndex - 1)
        } else if variantIndex > 0 {
            move(toVariant: variantIndex - 1, frame: max(0, trace.variants[variantIndex - 1].frames.count - 1))
        }
    }

    private func move(toVariant index: Int, frame nextFrame: Int) {
        withAnimation(reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.86)) {
            variantIndex = index
            frameIndex = nextFrame
        }
    }
}

private struct CourseTraceObjectView: View {
    @Environment(\.workspacePalette) private var palette
    @ScaledMetric(relativeTo: .largeTitle) private var valueSize = 48
    let object: CourseTraceObject
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 12) {
            Text(verbatim: object.names.joined(separator: " · "))
                .font(.system(.body, design: .monospaced, weight: .semibold))
                .foregroundStyle(compact ? Color.primary : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if compact {
                ViewThatFits(in: .horizontal) {
                    valueText(size: valueSize).fixedSize(horizontal: true, vertical: true)
                    valueText(size: valueSize * 0.8).fixedSize(horizontal: true, vertical: true)
                    valueText(size: valueSize * 0.65).fixedSize(horizontal: true, vertical: true)
                    valueText(size: valueSize * 0.65).fixedSize(horizontal: false, vertical: true)
                }
            } else {
                valueText(size: valueSize).fixedSize(horizontal: false, vertical: true)
            }
            if let scope = object.scope, !scope.isEmpty {
                Text(verbatim: scope).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(compact ? 14 : 16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .combine)
    }

    private func valueText(size: CGFloat) -> some View {
        Text(verbatim: object.value)
            .font(.system(size: size, weight: .bold, design: .monospaced))
            .foregroundStyle(object.changed == true ? palette.accent : Color.primary)
            .contentTransition(.numericText())
    }
}

/// Adjacent highlighted lines read as one inset band, with rounded ends only
/// at the beginning and end of the run. No separate pill around each statement.
struct CourseCodeLineHighlight: View {
    @Environment(\.workspacePalette) private var palette
    let isHighlighted: Bool
    var joinsPrevious = false
    var joinsNext = false

    var body: some View {
        if isHighlighted {
            UnevenRoundedRectangle(
                topLeadingRadius: joinsPrevious ? 0 : 7,
                bottomLeadingRadius: joinsNext ? 0 : 7,
                bottomTrailingRadius: joinsNext ? 0 : 7,
                topTrailingRadius: joinsPrevious ? 0 : 7,
                style: .continuous)
                .fill(palette.surface)
                .overlay(alignment: .leading) {
                    UnevenRoundedRectangle(
                        topLeadingRadius: joinsPrevious ? 0 : 1.5,
                        bottomLeadingRadius: joinsNext ? 0 : 1.5,
                        bottomTrailingRadius: joinsNext ? 0 : 1.5,
                        topTrailingRadius: joinsPrevious ? 0 : 1.5,
                        style: .continuous)
                        .fill(palette.accent)
                        .frame(width: 3)
                        .padding(.top, joinsPrevious ? 0 : 6)
                        .padding(.bottom, joinsNext ? 0 : 6)
                        .padding(.leading, 5)
                }
                .accessibilityHidden(true)
        }
    }
}

/// Literal source fragments stay native text, including code that contains angle
/// brackets or emoji. Segment targets let a long line reveal its marked word.
struct CourseMarkedCodeText: View {
    @Environment(\.workspacePalette) private var palette
    let source: String
    let lineNumber: Int
    private let segments: [CourseCodeSegment]

    init(source: String, lineNumber: Int, spans: [CourseCodeSpan]) {
        self.source = source
        self.lineNumber = lineNumber
        segments = CourseCodeMarking.segments(line: source.isEmpty ? " " : source, spans: spans)
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            ForEach(segments.indices, id: \.self) { index in
                Text(styled(segments[index]))
                    .id(CourseCodeSpanTarget(line: lineNumber, segment: index))
            }
        }
        .textSelection(.enabled)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(source)
    }

    private func styled(_ segment: CourseCodeSegment) -> AttributedString {
        var text = AttributedString(segment.text)
        if segment.highlighted {
            text.foregroundColor = palette.accent
            text.backgroundColor = palette.accent.opacity(0.2)
            text.inlinePresentationIntent = .stronglyEmphasized
        }
        return text
    }
}

private struct CourseCodeSpanTarget: Hashable {
    let line: Int
    let segment: Int
}

private struct CourseProgramFocus: Equatable {
    let lines: [Int]
    let spans: [CourseCodeSpan]
}

/// A bounded, always-visible source area. Long programs scroll inside it; the
/// lesson and its answer controls retain their own independent space.
struct CourseProgramReferenceView: View {
    @Environment(\.workspacePalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .subheadline) private var fontSize = 14.0
    let code: CourseCodeSample
    var maximumHeight: CGFloat = 220
    var allowsExpansion = true
    @State private var expandedSource: CourseProgramSourceSelection?
    private let lines: [String]
    private let spansByLine: [Int: [CourseCodeSpan]]

    init(code: CourseCodeSample, maximumHeight: CGFloat = 220, allowsExpansion: Bool = true) {
        self.code = code
        self.maximumHeight = maximumHeight
        self.allowsExpansion = allowsExpansion
        lines = code.source.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
        spansByLine = Dictionary(grouping: code.highlightSpans ?? [], by: \.line)
    }

    private var highlights: [Int] { code.highlightLines ?? [] }
    private var sourceHeight: CGFloat {
        min(maximumHeight, CGFloat(max(lines.count, 1)) * (fontSize * 1.25 + 10) + 16)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .foregroundStyle(palette.accent)
                Text(verbatim: code.filename ?? WorkspaceLocalization.string("本节程序"))
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(verbatim: code.language.uppercased())
                    .font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
                if allowsExpansion {
                    Button {
                        expandedSource = CourseProgramSourceSelection(code: code)
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.caption.weight(.semibold))
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).foregroundStyle(palette.accent)
                    .accessibilityLabel("放大完整程序")
                }
            }
            .padding(.leading, 12).padding(.trailing, allowsExpansion ? 0 : 12)
            .frame(minHeight: allowsExpansion ? 44 : 34)
            Divider().padding(.horizontal, 12)
            ScrollViewReader { proxy in
                ScrollView([.horizontal, .vertical]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(1...lines.count, id: \.self) { number in
                            sourceLine(number - 1)
                        }
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 6).padding(.vertical, 8)
                }
                .frame(height: sourceHeight)
                .onChange(of: CourseProgramFocus(lines: highlights, spans: code.highlightSpans ?? []), initial: true) { _, focus in
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                        if let span = focus.spans.first, lines.indices.contains(span.line - 1),
                           let segment = CourseCodeMarking.segments(line: lines[span.line - 1],
                               spans: spansByLine[span.line] ?? []).firstIndex(where: \.highlighted) {
                            proxy.scrollTo(CourseCodeSpanTarget(line: span.line, segment: segment), anchor: .center)
                        } else if let line = focus.lines.first, lines.indices.contains(line - 1) {
                            proxy.scrollTo(line, anchor: UnitPoint(x: 0, y: 0.5))
                        }
                    }
                }
            }
        }
        .background(.background, in: RoundedRectangle(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(palette.accent.opacity(0.14), lineWidth: 1) }
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .accessibilityIdentifier("course.reference-source")
        .sheet(item: $expandedSource) { selection in
            CourseProgramSourceSheet(code: selection.code)
        }
    }

    private func sourceLine(_ index: Int) -> some View {
        let number = index + 1
        let highlighted = highlights.contains(number)
        let spans = spansByLine[number] ?? []
        let focused = highlighted || !spans.isEmpty
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)")
                .font(.system(size: fontSize - 2, weight: focused ? .bold : .regular, design: .monospaced))
                .foregroundStyle(focused ? palette.accent : Color.secondary)
                .frame(minWidth: 26, alignment: .trailing)
                .accessibilityHidden(true)
            CourseMarkedCodeText(source: lines[index], lineNumber: number, spans: spans)
                .font(.system(size: fontSize, weight: highlighted ? .semibold : .regular, design: .monospaced))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: true, vertical: true)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 12).padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            CourseCodeLineHighlight(isHighlighted: highlighted,
                joinsPrevious: highlights.contains(number - 1),
                joinsNext: highlights.contains(number + 1))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("第 \(number) 行，\(lines[index])")
        .accessibilityValue(!spans.isEmpty ? WorkspaceLocalization.format("当前讲解片段：%@", spans.map(\.text).joined(separator: ", ")) : highlighted ? WorkspaceLocalization.string("当前讲解行") : "")
        .accessibilityIdentifier("course.reference-line.\(number)\(focused ? ".focused" : "")")
    }
}

private struct CourseProgramSourceSelection: Identifiable {
    let id = UUID()
    let code: CourseCodeSample
}

private struct CourseProgramSourceSheet: View {
    @Environment(\.dismiss) private var dismiss
    let code: CourseCodeSample

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                CourseProgramReferenceView(code: code, maximumHeight: max(100, geometry.size.height - 64), allowsExpansion: false)
                    .padding(16)
            }
            .navigationTitle("完整程序")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成", systemImage: "checkmark") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 400, idealWidth: 720, minHeight: 360, idealHeight: 600)
        #endif
    }
}
