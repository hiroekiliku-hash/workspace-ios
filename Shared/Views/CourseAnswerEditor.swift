import SwiftUI

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Keeps keystrokes, selection and marked text inside a native editor. Only the
/// plain answer is shared with the reader; syntax colours are presentation only.
struct CourseAnswerEditor: View {
    @Environment(\.workspacePalette) private var palette
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.courseStudyViewport) private var studyViewport
    @ScaledMetric(relativeTo: .body) private var fontSize = 16.0
    @Binding var text: String
    let input: CourseQuestionInput
    let limit: Int
    @Binding var isFocused: Bool
    var hapticsEnabled = true
    @State private var contentHeight: CGFloat = 0
    #if os(iOS)
    @State private var numberInput = CourseNumberInputTarget()
    @ScaledMetric(relativeTo: .body) private var keypadRowHeight = 44.0
    private var usesNumberKeyboard: Bool { input.kind == .integer || input.kind == .decimal }
    #endif

    private var isNumeric: Bool { input.kind == .integer || input.kind == .decimal }
    private var defaultCodeMinimumLines: Int {
        #if os(macOS)
        4
        #else
        2
        #endif
    }
    private var defaultCodeMaximumLines: Int {
        #if os(macOS)
        18
        #else
        12
        #endif
    }
    private var minimumLines: Int { max(1, min(24, input.minLines ?? (input.kind == .code ? defaultCodeMinimumLines : 1))) }
    private var maximumLines: Int { max(minimumLines, min(24, input.maxLines ?? (input.kind == .code ? defaultCodeMaximumLines : isNumeric ? 3 : 6))) }
    private var viewportHeightLimit: CGFloat {
        guard studyViewport.height > 0 else { return .greatestFiniteMagnitude }
        #if os(iOS)
        let keypadHeight = usesNumberKeyboard ? max(44, keypadRowHeight) * 2 + 14 : 0
        #else
        let keypadHeight: CGFloat = 0
        #endif
        // Leave room for the question and controls when a keyboard or rotation
        // reduces the viewport. Longer responses scroll inside the editor.
        return max(fontSize * 1.4 + 24, studyViewport.height * 0.62 - keypadHeight)
    }
    private var minimumHeight: CGFloat { min(CGFloat(minimumLines) * fontSize * 1.4 + 24, viewportHeightLimit) }
    private var maximumHeight: CGFloat { min(CGFloat(maximumLines) * fontSize * 1.4 + 24, viewportHeightLimit) }
    private var placeholder: String {
        if let value = input.placeholder, !value.isEmpty { return value }
        switch input.kind {
        case .text: return WorkspaceLocalization.string("输入你的答案")
        case .integer: return WorkspaceLocalization.string("输入整数")
        case .decimal: return WorkspaceLocalization.string("输入数字")
        case .code: return WorkspaceLocalization.string("在这里编写代码")
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            editor
            #if os(iOS)
            if usesNumberKeyboard {
                CourseInlineNumberKeyboard(target: numberInput, accent: palette.accent, hapticsEnabled: hapticsEnabled, rowHeight: max(44, keypadRowHeight))
                    .fixedSize(horizontal: false, vertical: true)
                    .clipped()
                    .accessibilityIdentifier("course-inline-number-keyboard")
            }
            #endif
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var editor: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text(verbatim: placeholder)
                    .font(input.kind == .code ? .system(size: fontSize, design: .monospaced) : .system(size: fontSize))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 12)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            nativeEditor
            .accessibilityLabel(placeholder)
            .accessibilityIdentifier(input.kind == .code ? "course-code-answer" : "course-text-answer")
        }
        .frame(height: min(max(contentHeight, minimumHeight), maximumHeight))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(isFocused ? palette.accent.opacity(0.7) : Color.primary.opacity(0.1), lineWidth: 1)
        }
    }

    @ViewBuilder private var nativeEditor: some View {
        #if os(iOS)
        CourseNativeAnswerEditor(text: $text, input: input, limit: limit, isFocused: $isFocused,
            fontSize: fontSize, accent: palette.accent, numberInput: numberInput, heightChanged: updateHeight, colorScheme: colorScheme)
        #else
        CourseNativeAnswerEditor(text: $text, input: input, limit: limit, isFocused: $isFocused,
            fontSize: fontSize, accent: palette.accent, heightChanged: updateHeight, colorScheme: colorScheme)
        #endif
    }

    private func updateHeight(_ height: CGFloat) {
        if abs(contentHeight - height) > 0.5 { contentHeight = height }
    }

    /// Finish an IME candidate synchronously before the reader decides whether
    /// Continue should submit or turn a page. Only this editor owns the commit.
    @MainActor static func commitCurrentEditing() {
        #if os(macOS)
        (NSApp.keyWindow?.firstResponder as? CourseAnswerTextView)?.commitPendingInput()
        #endif
    }
}

private enum CourseAnswerEditing {
    static func accepts(_ candidate: String, input: CourseQuestionInput) -> Bool {
        switch input.kind {
        // Both numeric editors offer a decimal key. The question's declared
        // integer/decimal requirement is still enforced when submitting.
        case .integer, .decimal: return candidate.range(of: #"^[+-]?[0-9]*(?:\.[0-9]*)?$"#, options: .regularExpression) != nil
        case .text, .code: return true
        }
    }

    struct IndentationChange {
        let range: NSRange
        let replacement: String
        let selection: NSRange
    }

    static func indentation(in source: String, selection: NSRange, outdent: Bool) -> IndentationChange? {
        let text = source as NSString
        let location = min(selection.location == NSNotFound ? text.length : selection.location, text.length)
        let selected = NSRange(location: location, length: min(selection.length, text.length - location))
        if selected.length == 0 && !outdent {
            return IndentationChange(range: selected, replacement: "    ", selection: NSRange(location: location + 4, length: 0))
        }
        let lines = text.lineRange(for: selected)
        struct Edit { let range: NSRange; let replacement: String }
        var edits: [Edit] = []
        var cursor = lines.location
        while cursor < NSMaxRange(lines) {
            let line = text.lineRange(for: NSRange(location: cursor, length: 0))
            if outdent {
                let contents = text.substring(with: line)
                let removed = contents.hasPrefix("\t") ? 1 : contents.prefix(while: { $0 == " " }).prefix(4).count
                if removed > 0 { edits.append(Edit(range: NSRange(location: cursor, length: removed), replacement: "")) }
            } else {
                edits.append(Edit(range: NSRange(location: cursor, length: 0), replacement: "    "))
            }
            cursor = NSMaxRange(line)
        }
        guard !edits.isEmpty else { return nil }
        let replacement = NSMutableString(string: text.substring(with: lines))
        for edit in edits.reversed() {
            replacement.replaceCharacters(in: NSRange(location: edit.range.location - lines.location, length: edit.range.length), with: edit.replacement)
        }
        func adjusted(_ offset: Int, includeInsertionAtBoundary: Bool) -> Int {
            var change = 0
            for edit in edits {
                if offset < edit.range.location { break }
                if edit.range.length == 0 {
                    if offset > edit.range.location || includeInsertionAtBoundary { change += edit.replacement.utf16.count }
                } else if offset < NSMaxRange(edit.range) {
                    return edit.range.location + change
                } else { change -= edit.range.length }
            }
            return offset + change
        }
        let start = adjusted(selected.location, includeInsertionAtBoundary: false)
        let end = adjusted(NSMaxRange(selected), includeInsertionAtBoundary: true)
        return IndentationChange(range: lines, replacement: replacement as String, selection: NSRange(location: start, length: max(0, end - start)))
    }

    static func newline(in source: String, at location: Int) -> String {
        let prefix = (source as NSString).substring(to: min(location, (source as NSString).length))
        let line = prefix.components(separatedBy: "\n").last ?? ""
        let indent = String(line.prefix(while: { $0 == " " || $0 == "\t" }))
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return "\n" + indent + (trimmed.hasSuffix("{") || trimmed.hasSuffix(":") ? "    " : "")
    }
}

/// A small lexical pass, not a compiler. Ranges are calculated off the main
/// thread and applied without replacing the text storage or the current caret.
private enum CourseAnswerSyntax {
    enum Kind: Sendable { case keyword, string, comment, number, function, type }
    struct Token: Sendable { let range: NSRange; let kind: Kind }

    private static let cFamily = try! NSRegularExpression(pattern:
        #"(//[^\n]*|/\*[\s\S]*?(?:\*/|\z))|("(?:\\.|[^"\\])*"?|'(?:\\.|[^'\\])*'?)|\b(0[xX][0-9a-fA-F]+|[0-9]+(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?)\b|\b([A-Za-z_$][\w$]*)(?=\s*\()|\b([A-Za-z_$][\w$]*)\b"#)
    private static let python = try! NSRegularExpression(pattern:
        ##"(\#[^\n]*)|("""[\s\S]*?(?:"""|\z)|'''[\s\S]*?(?:'''|\z)|"(?:\\.|[^"\\])*"?|'(?:\\.|[^'\\])*'?)|\b(0[xX][0-9a-fA-F]+|[0-9]+(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?)\b|\b([A-Za-z_][\w]*)(?=\s*\()|\b([A-Za-z_][\w]*)\b"##)
    private static let commonKeywords = Set("if else for while do return break continue switch case default true false null new class public private protected static const void int float double bool char long short unsigned signed auto struct enum namespace using include template typename virtual override try catch throw this sizeof async await function let var export import from extends super undefined typeof instanceof delete yield def lambda in is not and or None True False pass with as except finally raise global nonlocal assert del elif print range len".split(separator: " ").map(String.init))

    static func tokens(in source: String, language: String?) -> [Token] {
        // Large course uploads stay editable without spending time colouring a megabyte of JSON.
        guard source.utf8.count <= 80_000 else { return [] }
        let pattern = language?.lowercased() == "python" ? python : cFamily
        let text = source as NSString
        return pattern.matches(in: source, range: NSRange(location: 0, length: text.length)).compactMap { match in
            if match.range(at: 1).location != NSNotFound { return Token(range: match.range, kind: .comment) }
            if match.range(at: 2).location != NSNotFound { return Token(range: match.range, kind: .string) }
            if match.range(at: 3).location != NSNotFound { return Token(range: match.range, kind: .number) }
            let identifier = text.substring(with: match.range)
            if commonKeywords.contains(identifier) { return Token(range: match.range, kind: .keyword) }
            if match.range(at: 4).location != NSNotFound { return Token(range: match.range, kind: .function) }
            if identifier.first?.isUppercase == true { return Token(range: match.range, kind: .type) }
            return nil
        }
    }
}

#if os(iOS)
@MainActor private final class CourseNumberInputTarget {
    weak var textView: UITextView?
}

private struct CourseInlineNumberKeyboard: UIViewRepresentable {
    let target: CourseNumberInputTarget
    let accent: Color
    let hapticsEnabled: Bool
    let rowHeight: CGFloat

    func makeUIView(context: Context) -> CourseNumberKeyboard {
        CourseNumberKeyboard(editor: { [weak target] in target?.textView })
    }
    func updateUIView(_ view: CourseNumberKeyboard, context: Context) {
        view.tintColor = UIColor(accent)
        view.hapticsEnabled = hapticsEnabled
        view.rowHeight = rowHeight
    }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: CourseNumberKeyboard, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? uiView.bounds.width, height: uiView.preferredHeight)
    }
}

private struct CourseNativeAnswerEditor: UIViewRepresentable {
    @Binding var text: String
    let input: CourseQuestionInput
    let limit: Int
    @Binding var isFocused: Bool
    let fontSize: CGFloat
    let accent: Color
    let numberInput: CourseNumberInputTarget
    let heightChanged: (CGFloat) -> Void
    var colorScheme: ColorScheme = .light

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> CourseAnswerTextView {
        let view = CourseAnswerTextView()
        view.backgroundColor = .clear
        view.textColor = .label
        view.textContainerInset = UIEdgeInsets(top: 12, left: 8, bottom: 12, right: 8)
        view.textContainer.lineFragmentPadding = 5
        view.delegate = context.coordinator
        view.adjustsFontForContentSizeCategory = true
        view.keyboardDismissMode = .interactive
        view.inputAssistantItem.leadingBarButtonGroups = []
        view.inputAssistantItem.trailingBarButtonGroups = []
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.heightChanged = heightChanged
        numberInput.textView = view
        return view
    }

    func updateUIView(_ view: CourseAnswerTextView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        view.heightChanged = heightChanged
        let appearanceChanged = view.codeMode != (input.kind == .code) || view.editorFontSize != fontSize
            || view.tintColor != UIColor(accent) || coordinator.language != input.language || coordinator.colorScheme != colorScheme
        view.codeMode = input.kind == .code
        view.editorFontSize = fontSize
        view.tintColor = UIColor(accent)
        let font = view.codeMode ? UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular) : UIFont.systemFont(ofSize: fontSize)
        if view.font != font { view.font = font; view.invalidateContentHeight() }
        view.autocorrectionType = view.codeMode ? .no : .default
        view.autocapitalizationType = view.codeMode ? .none : .sentences
        view.smartQuotesType = view.codeMode ? .no : .default
        view.smartDashesType = view.codeMode ? .no : .default
        view.smartInsertDeleteType = view.codeMode ? .no : .default
        coordinator.language = input.language

        if coordinator.keyboardKind != input.kind {
            coordinator.keyboardKind = input.kind
            if input.kind == .integer || input.kind == .decimal {
                // The keypad lives below the answer, not in the keyboard window.
                view.inputView = UIView(frame: .zero)
                view.inputAccessoryView = nil
            } else {
                view.inputView = nil
                view.inputAccessoryView = view.codeMode ? CourseCodeAccessory(textView: view) : nil
            }
            if view.isFirstResponder { view.reloadInputViews() }
        }
        (view.inputAccessoryView as? CourseCodeAccessory)?.updateAppearance(colorScheme: colorScheme, accent: UIColor(accent))
        if !coordinator.synchronizeText(in: view), appearanceChanged { coordinator.scheduleHighlight(in: view) }
        coordinator.applyTextAppearance(in: view)
        view.wantsFocus = isFocused
        if isFocused && !view.isFirstResponder && view.window != nil { view.becomeFirstResponder() }
        if !isFocused && view.isFirstResponder { view.resignFirstResponder() }
        view.reportHeight()
    }

    static func dismantleUIView(_ view: CourseAnswerTextView, coordinator: Coordinator) {
        coordinator.highlightTask?.cancel()
        view.delegate = nil
        view.heightChanged = nil
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: CourseNativeAnswerEditor
        var highlightTask: Task<Void, Never>?
        var keyboardKind: CourseQuestionInputKind?
        var language: String?
        private(set) var colorScheme: ColorScheme?
        private var appearanceCodeMode: Bool?
        private var appearanceFont: UIFont?
        private var initializedText = false
        private var highlighting = false
        init(_ parent: CourseNativeAnswerEditor) { self.parent = parent }

        private func textTraits(in view: UITextView) -> UITraitCollection {
            UITraitCollection(traitsFrom: [view.traitCollection,
                UITraitCollection(userInterfaceStyle: parent.colorScheme == .dark ? .dark : .light)])
        }

        func applyTextAppearance(in view: UITextView) {
            view.overrideUserInterfaceStyle = parent.colorScheme == .dark ? .dark : .light
            guard view.markedTextRange == nil else { return }
            let font = view.font ?? UIFont.systemFont(ofSize: parent.fontSize)
            // SwiftUI may update an editor before it is attached to a window.
            let color = UIColor.label.resolvedColor(with: textTraits(in: view))
            let codeMode = parent.input.kind == .code
            let changed = colorScheme != parent.colorScheme || appearanceCodeMode != codeMode || appearanceFont != font
            if changed {
                let selection = view.selectedRange
                view.textColor = color
                view.selectedRange = selection
                colorScheme = parent.colorScheme; appearanceCodeMode = codeMode; appearanceFont = font
            }
            // Plain inline insertion cannot rely on UITextView's default (black) attributes.
            var attributes = view.typingAttributes
            attributes[.foregroundColor] = color; attributes[.font] = font
            view.typingAttributes = attributes
        }

        @discardableResult func synchronizeText(in view: UITextView) -> Bool {
            guard view.markedTextRange == nil else { return false }
            defer { initializedText = true }
            guard view.text != parent.text else { return false }
            let selection = view.selectedRange
            let numeric = parent.input.kind == .integer || parent.input.kind == .decimal
            let restoreAtEnd = numeric && (!initializedText || !view.isFirstResponder)
            view.text = parent.text
            (view as? CourseAnswerTextView)?.invalidateContentHeight()
            let length = (parent.text as NSString).length
            let location = restoreAtEnd || selection.location == NSNotFound ? length : min(selection.location, length)
            view.selectedRange = NSRange(location: location, length: 0)
            scheduleHighlight(in: view)
            return true
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            if !parent.isFocused { parent.isFocused = true }
        }
        func textViewDidEndEditing(_ textView: UITextView) {
            if parent.isFocused { parent.isFocused = false }
        }
        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            guard textView.markedTextRange == nil else { return true }
            let candidate = (textView.text as NSString).replacingCharacters(in: range, with: text)
            return candidate.count <= parent.limit && CourseAnswerEditing.accepts(candidate, input: parent.input)
        }
        func textViewDidChange(_ textView: UITextView) {
            guard !highlighting, textView.markedTextRange == nil else { return }
            if textView.text.count > parent.limit {
                textView.text = String(textView.text.prefix(parent.limit))
            }
            if parent.text != textView.text { parent.text = textView.text }
            applyTextAppearance(in: textView)
            scheduleHighlight(in: textView)
            (textView as? CourseAnswerTextView)?.invalidateContentHeight()
            (textView as? CourseAnswerTextView)?.reportHeight()
        }

        func scheduleHighlight(in view: UITextView) {
            highlightTask?.cancel()
            // Plain answers need no asynchronous syntax pass or text-storage rewrite.
            guard parent.input.kind == .code else { return }
            guard view.markedTextRange == nil else { return }
            let source = view.text ?? ""
            let language = parent.input.language
            let isCode = parent.input.kind == .code
            highlightTask = Task { @MainActor [weak self, weak view] in
                try? await Task.sleep(for: .milliseconds(70))
                guard !Task.isCancelled else { return }
                let tokens = isCode ? await Task.detached(priority: .utility) {
                    CourseAnswerSyntax.tokens(in: source, language: language)
                }.value : []
                guard let self, let view, !Task.isCancelled, view.text == source, view.markedTextRange == nil else { return }
                self.highlighting = true
                let undoEnabled = view.undoManager?.isUndoRegistrationEnabled == true
                if undoEnabled { view.undoManager?.disableUndoRegistration() }
                view.textStorage.beginEditing()
                let font = view.font ?? UIFont.systemFont(ofSize: self.parent.fontSize)
                let traits = self.textTraits(in: view)
                let baseColor = UIColor.label.resolvedColor(with: traits)
                view.textStorage.addAttributes([.foregroundColor: baseColor, .font: font], range: NSRange(location: 0, length: view.textStorage.length))
                for token in tokens {
                    let color: UIColor
                    switch token.kind {
                    case .keyword: color = .systemPurple
                    case .string: color = .systemRed
                    case .comment: color = .secondaryLabel
                    case .number: color = .systemOrange
                    case .function: color = UIColor(self.parent.accent)
                    case .type: color = .systemTeal
                    }
                    view.textStorage.addAttribute(.foregroundColor, value: color.resolvedColor(with: traits), range: token.range)
                }
                view.textStorage.endEditing()
                view.typingAttributes = [.font: font, .foregroundColor: baseColor]
                if undoEnabled { view.undoManager?.enableUndoRegistration() }
                self.highlighting = false
            }
        }
    }
}

private final class CourseAnswerTextView: UITextView {
    var codeMode = false
    var editorFontSize: CGFloat = 16
    var wantsFocus = false
    var heightChanged: ((CGFloat) -> Void)?
    private var reportedHeight: CGFloat = 0
    private var measuredWidth: CGFloat = 0
    private var needsHeightMeasurement = true

    func invalidateContentHeight() {
        needsHeightMeasurement = true
        setNeedsLayout()
    }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if wantsFocus && window != nil && !isFirstResponder { becomeFirstResponder() }
    }
    override func layoutSubviews() { super.layoutSubviews(); reportHeight() }
    func reportHeight() {
        guard bounds.width > 0 else { return }
        if needsHeightMeasurement || abs(bounds.width - measuredWidth) > 0.5 {
            needsHeightMeasurement = false
            measuredWidth = bounds.width
            let height = sizeThatFits(CGSize(width: bounds.width, height: CGFloat.greatestFiniteMagnitude)).height
            if abs(height - reportedHeight) > 0.5 {
                reportedHeight = height
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.heightChanged?(self.reportedHeight)
                }
            }
        }
        let needsScrolling = reportedHeight > bounds.height + 0.5
        if isScrollEnabled != needsScrolling { isScrollEnabled = needsScrolling }
    }
    override func insertText(_ text: String) {
        if codeMode && markedTextRange == nil {
            if text == "\t" { changeIndentation(outdent: false); return }
            if text == "\n" {
                super.insertText(CourseAnswerEditing.newline(in: self.text, at: selectedRange.location)); return
            }
        }
        super.insertText(text)
    }
    override var keyCommands: [UIKeyCommand]? {
        var commands = super.keyCommands ?? []
        if codeMode {
            commands.append(UIKeyCommand(input: "\t", modifierFlags: [], action: #selector(indent)))
            commands.append(UIKeyCommand(input: "\t", modifierFlags: .shift, action: #selector(outdent)))
            commands.append(UIKeyCommand(input: "]", modifierFlags: .command, action: #selector(indent)))
            commands.append(UIKeyCommand(input: "[", modifierFlags: .command, action: #selector(outdent)))
        }
        return commands
    }
    private func changeIndentation(outdent: Bool) {
        guard markedTextRange == nil,
              let change = CourseAnswerEditing.indentation(in: text, selection: selectedRange, outdent: outdent),
              delegate?.textView?(self, shouldChangeTextIn: change.range, replacementText: change.replacement) != false else { return }
        selectedRange = change.range
        super.insertText(change.replacement)
        selectedRange = change.selection
    }
    @objc private func indent() { changeIndentation(outdent: false) }
    @objc private func outdent() { changeIndentation(outdent: true) }
}

/// Inline keys retain the editor's caret and selection without requiring focus.
private final class CourseNumberKeyboard: UIView {
    private let editor: () -> UITextView?
    var hapticsEnabled = false
    var rowHeight: CGFloat = 44 {
        didSet { if abs(oldValue - rowHeight) > 0.5 { invalidateIntrinsicContentSize() } }
    }
    var preferredHeight: CGFloat { max(44, rowHeight) * 2 + 6 }
    override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: preferredHeight) }
    init(editor: @escaping () -> UITextView?) {
        self.editor = editor
        super.init(frame: .zero)
        clipsToBounds = true
        setContentCompressionResistancePriority(.required, for: .vertical)
        setContentHuggingPriority(.required, for: .vertical)
        let rows = UIStackView()
        rows.axis = .vertical
        rows.spacing = 6
        rows.distribution = .fillEqually
        rows.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rows)
        NSLayoutConstraint.activate([
            rows.leadingAnchor.constraint(equalTo: leadingAnchor),
            rows.trailingAnchor.constraint(equalTo: trailingAnchor),
            rows.topAnchor.constraint(equalTo: topAnchor),
            rows.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        let keys = [["1", "2", "3", "4", "5", "−", "⌫"],
                    ["6", "7", "8", "9", "0", ".", "清空"]]
        for labels in keys {
            let row = UIStackView()
            row.spacing = 6
            row.distribution = .fillEqually
            for label in labels {
                let button = UIButton(type: .system)
                button.setTitle(WorkspaceLocalization.string(label), for: .normal)
                button.titleLabel?.font = .systemFont(ofSize: label == "清空" ? 15 : 23, weight: .medium)
                button.titleLabel?.adjustsFontSizeToFitWidth = true
                button.titleLabel?.minimumScaleFactor = 0.65
                button.backgroundColor = label.isEmpty ? .clear : .secondarySystemGroupedBackground
                button.layer.cornerRadius = 10
                button.isEnabled = !label.isEmpty
                button.accessibilityLabel = label == "⌫" ? WorkspaceLocalization.string("删除一位") : label == "−" ? WorkspaceLocalization.string("切换负号") : label == "." ? WorkspaceLocalization.string("小数点") : WorkspaceLocalization.string(label)
                button.accessibilityIdentifier = "course-number-key-" + label
                button.addAction(UIAction { [weak self] _ in self?.press(label) }, for: .touchUpInside)
                row.addArrangedSubview(button)
            }
            rows.addArrangedSubview(row)
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private func press(_ label: String) {
        guard let textView = editor() else { return }
        let source = textView.text ?? ""
        let oldLength = (source as NSString).length
        let oldSelection = textView.selectedRange
        let location = oldSelection.location == NSNotFound ? oldLength : min(oldSelection.location, oldLength)
        let selection = NSRange(location: location, length: min(oldSelection.length, oldLength - location))
        let range: NSRange
        let replacement: String
        var caret: Int?
        switch label {
        case "⌫":
            guard selection.length > 0 || selection.location > 0 else { return }
            range = selection.length > 0 ? selection : NSRange(location: selection.location - 1, length: 1)
            replacement = ""
        case "清空":
            range = NSRange(location: 0, length: oldLength)
            replacement = ""
        case "−":
            let removing = source.hasPrefix("-")
            range = NSRange(location: 0, length: removing || source.hasPrefix("+") ? 1 : 0)
            replacement = removing ? "" : "-"
            caret = max(0, selection.location + replacement.utf16.count - range.length)
        default:
            range = selection
            replacement = label
        }
        guard range.location <= oldLength, NSMaxRange(range) <= oldLength,
              textView.delegate?.textView?(textView, shouldChangeTextIn: range, replacementText: replacement) != false else { return }
        // Inline key presses must update the bound answer even when the editor
        // has never become first responder. Keep its existing validation path.
        let inserted = NSAttributedString(string: replacement, attributes: textView.typingAttributes)
        textView.textStorage.replaceCharacters(in: range, with: inserted)
        let length = (textView.text as NSString).length
        textView.selectedRange = NSRange(location: min(length, caret ?? (range.location + replacement.utf16.count)), length: 0)
        textView.delegate?.textViewDidChange?(textView)
        if textView.text != source {
            WorkspaceHaptics.play(.key, enabled: hapticsEnabled)
        }
    }
}

#if DEBUG
/// Exercises actual UITextView updates and inline UIButton actions without a keyboard window or account.
@MainActor enum CourseNumberKeyboardRegression {
    static func run() throws {
        var answer = "123", focused = false
        let input = CourseQuestionInput(kind: .decimal)
        func makeEditor() -> (UITextView, CourseNativeAnswerEditor.Coordinator, CourseNumberKeyboard) {
            let target = CourseNumberInputTarget()
            let parent = CourseNativeAnswerEditor(text: Binding(get: { answer }, set: { answer = $0 }), input: input,
                limit: 100, isFocused: Binding(get: { focused }, set: { focused = $0 }), fontSize: 16,
                accent: .blue, numberInput: target, heightChanged: { _ in }, colorScheme: .dark)
            let coordinator = CourseNativeAnswerEditor.Coordinator(parent)
            let view = CourseAnswerTextView()
            view.font = .systemFont(ofSize: 16)
            view.delegate = coordinator
            coordinator.synchronizeText(in: view)
            coordinator.applyTextAppearance(in: view)
            let keyboard = CourseNumberKeyboard(editor: { [weak view] in view })
            return (view, coordinator, keyboard)
        }
        func press(_ key: String, on keyboard: CourseNumberKeyboard) throws {
            let buttons = keyboard.subviews.compactMap { $0 as? UIStackView }
                .flatMap(\.arrangedSubviews).compactMap { $0 as? UIStackView }
                .flatMap(\.arrangedSubviews).compactMap { $0 as? UIButton }
            guard let button = buttons.first(where: { $0.title(for: .normal) == key }) else {
                throw WorkspaceFailure.invalid("数字键盘缺少按键。")
            }
            button.sendActions(for: .touchUpInside)
        }
        func check(_ value: Bool, line: UInt = #line) throws {
            if !value { throw WorkspaceFailure.invalid("数字键盘回归检查失败：第 \(line) 行。") }
        }
        func checkVisibleText(_ view: UITextView) throws {
            let traits = UITraitCollection(traitsFrom: [view.traitCollection,
                UITraitCollection(userInterfaceStyle: view.overrideUserInterfaceStyle)])
            let expected = UIColor.label.resolvedColor(with: traits)
            guard let typing = view.typingAttributes[.foregroundColor] as? UIColor else { return try check(false) }
            try check(typing.resolvedColor(with: traits).isEqual(expected))
            for index in 0..<view.textStorage.length {
                guard let color = view.textStorage.attribute(.foregroundColor, at: index, effectiveRange: nil) as? UIColor else {
                    return try check(false)
                }
                try check(color.resolvedColor(with: traits).isEqual(expected))
            }
        }
        let (first, firstCoordinator, firstKeyboard) = makeEditor()
        try check(first.overrideUserInterfaceStyle == .dark)
        try check(!first.isFirstResponder && first.selectedRange.location == 3)
        try checkVisibleText(first)
        try press("⌫", on: firstKeyboard)
        try check(answer == "12")
        first.delegate = nil
        firstCoordinator.highlightTask?.cancel()
        let (restored, coordinator, keyboard) = makeEditor()
        defer { restored.delegate = nil; coordinator.highlightTask?.cancel() }
        try check(!restored.isFirstResponder && restored.selectedRange.location == 2)
        try press("⌫", on: keyboard)
        try check(answer == "1")
        try press("8", on: keyboard)
        try check(answer == "18")
        restored.selectedRange = NSRange(location: 0, length: 1)
        try press("⌫", on: keyboard)
        try check(answer == "8")
        try press("−", on: keyboard)
        try check(answer == "-8")
        // Selection deletion intentionally left the caret at the start. Move it
        // to the end to exercise a separate decimal-append action.
        restored.selectedRange = NSRange(location: (answer as NSString).length, length: 0)
        try press(".", on: keyboard)
        try press("2", on: keyboard)
        try check(answer == "-8.2")
        try press(".", on: keyboard)
        try check(answer == "-8.2")
        try press("清空", on: keyboard)
        try press("⌫", on: keyboard)
        try check(answer.isEmpty && !focused && keyboard.preferredHeight >= 94)
        try press("9", on: keyboard)
        try checkVisibleText(restored)
        let selection = restored.selectedRange, saved = answer
        for scheme in [ColorScheme.light, .dark] {
            coordinator.parent.colorScheme = scheme
            coordinator.applyTextAppearance(in: restored)
            try check(restored.overrideUserInterfaceStyle == (scheme == .dark ? .dark : .light))
            try checkVisibleText(restored)
            try check(restored.selectedRange == selection && answer == saved)
        }
        print("COURSE_ANSWER_DARK_MODE_PASS")
    }
}
#endif

private final class CourseCodeAccessory: UIInputView {
    init(textView: UITextView) {
        // This is an editing surface, so page content must never show through
        // the accessory when the keyboard floats above the lesson.
        super.init(frame: CGRect(x: 0, y: 0, width: 0, height: 44), inputViewStyle: .default)
        backgroundColor = .secondarySystemBackground
        isOpaque = true
        clipsToBounds = true
        let separator = UIView()
        separator.backgroundColor = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separator)
        let row = UIStackView()
        row.distribution = .fillEqually
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            separator.topAnchor.constraint(equalTo: topAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1 / max(1, textView.traitCollection.displayScale)),
            row.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 4),
            row.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -4),
            row.topAnchor.constraint(equalTo: topAnchor), row.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        for label in ["缩进", "(", ")", "{", "}", ";", "完成"] {
            let button = UIButton(type: .system)
            button.setTitle(WorkspaceLocalization.string(label), for: .normal)
            button.titleLabel?.font = .monospacedSystemFont(ofSize: label.count > 1 ? 14 : 18, weight: .medium)
            button.addAction(UIAction { [weak textView] _ in
                if label == "完成" { textView?.resignFirstResponder() }
                else { textView?.insertText(label == "缩进" ? "    " : label) }
            }, for: .touchUpInside)
            row.addArrangedSubview(button)
        }
    }
    func updateAppearance(colorScheme: ColorScheme, accent: UIColor) {
        // The keyboard hosts this view in a different window from the editor.
        overrideUserInterfaceStyle = colorScheme == .dark ? .dark : .light
        tintColor = accent
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

#elseif os(macOS)
private struct CourseNativeAnswerEditor: NSViewRepresentable {
    @Binding var text: String
    let input: CourseQuestionInput
    let limit: Int
    @Binding var isFocused: Bool
    let fontSize: CGFloat
    let accent: Color
    let heightChanged: (CGFloat) -> Void
    var colorScheme: ColorScheme = .light

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> CourseAnswerScrollView {
        let scroll = CourseAnswerScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let view = CourseAnswerTextView(frame: .zero)
        view.delegate = context.coordinator
        view.drawsBackground = false
        view.isRichText = false
        view.importsGraphics = false
        view.allowsUndo = true
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainerInset = NSSize(width: 8, height: 12)
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.heightTracksTextView = false
        view.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        view.minSize = .zero
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        scroll.documentView = view
        scroll.heightChanged = heightChanged
        view.focusChanged = { [weak coordinator = context.coordinator] focused in
            guard let coordinator, coordinator.parent.isFocused != focused else { return }
            coordinator.parent.isFocused = focused
        }
        return scroll
    }

    func updateNSView(_ scroll: CourseAnswerScrollView, context: Context) {
        guard let view = scroll.documentView as? CourseAnswerTextView else { return }
        let coordinator = context.coordinator
        coordinator.parent = self
        scroll.heightChanged = heightChanged
        let codeMode = input.kind == .code
        let font = codeMode ? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular) : NSFont.systemFont(ofSize: fontSize)
        let appearanceChanged = view.codeMode != codeMode || view.font != font || view.insertionPointColor != NSColor(accent)
            || coordinator.language != input.language || coordinator.colorScheme != colorScheme
        view.codeMode = codeMode
        if view.font != font { view.font = font; scroll.invalidateContentHeight() }
        view.insertionPointColor = NSColor(accent)
        view.isAutomaticQuoteSubstitutionEnabled = !codeMode
        view.isAutomaticDashSubstitutionEnabled = !codeMode
        view.isAutomaticTextReplacementEnabled = !codeMode
        view.isAutomaticSpellingCorrectionEnabled = !codeMode
        view.isContinuousSpellCheckingEnabled = !codeMode
        coordinator.language = input.language
        if view.string != text && !view.hasMarkedText() {
            let selection = view.selectedRange()
            // A cloud/restore replacement invalidates old character ranges.
            // This manager belongs only to this editor, not the whole window.
            coordinator.editingUndoManager.removeAllActions()
            view.string = text
            scroll.invalidateContentHeight()
            view.setSelectedRange(NSRange(location: min(selection.location, (text as NSString).length), length: 0))
            coordinator.scheduleHighlight(in: view)
        } else if appearanceChanged { coordinator.scheduleHighlight(in: view) }
        coordinator.applyTextAppearance(in: view)
        view.wantsFocus = isFocused
        if isFocused && view.window?.firstResponder !== view { view.window?.makeFirstResponder(view) }
        if !isFocused && view.window?.firstResponder === view { view.window?.makeFirstResponder(nil) }
        scroll.needsLayout = true
    }

    static func dismantleNSView(_ scroll: CourseAnswerScrollView, coordinator: Coordinator) {
        coordinator.highlightTask?.cancel()
        (scroll.documentView as? CourseAnswerTextView)?.delegate = nil
        (scroll.documentView as? CourseAnswerTextView)?.focusChanged = nil
        scroll.heightChanged = nil
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CourseNativeAnswerEditor
        var highlightTask: Task<Void, Never>?
        let editingUndoManager = UndoManager()
        var language: String?
        private(set) var colorScheme: ColorScheme?
        private var appearanceCodeMode: Bool?
        private var appearanceFont: NSFont?
        private var highlighting = false
        init(_ parent: CourseNativeAnswerEditor) { self.parent = parent }
        func undoManager(for view: NSTextView) -> UndoManager? { editingUndoManager }
        func applyTextAppearance(in view: NSTextView) {
            let appearance = NSAppearance(named: parent.colorScheme == .dark ? .darkAqua : .aqua)
            view.appearance = appearance
            view.enclosingScrollView?.appearance = appearance
            guard !view.hasMarkedText() else { return }
            let font = view.font ?? NSFont.systemFont(ofSize: parent.fontSize)
            var color = NSColor.labelColor
            appearance?.performAsCurrentDrawingAppearance { color = NSColor.labelColor.usingColorSpace(.deviceRGB) ?? .labelColor }
            let codeMode = parent.input.kind == .code
            let changed = colorScheme != parent.colorScheme || appearanceCodeMode != codeMode || appearanceFont != font
            if changed {
                let selection = view.selectedRange()
                view.textColor = color
                view.setSelectedRange(selection)
                colorScheme = parent.colorScheme; appearanceCodeMode = codeMode; appearanceFont = font
            }
            var attributes = view.typingAttributes
            attributes[.foregroundColor] = color; attributes[.font] = font
            view.typingAttributes = attributes
        }
        func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
            guard let replacementString, !textView.hasMarkedText() else { return true }
            let candidate = (textView.string as NSString).replacingCharacters(in: affectedCharRange, with: replacementString)
            return candidate.count <= parent.limit && CourseAnswerEditing.accepts(candidate, input: parent.input)
        }
        func textDidChange(_ notification: Notification) {
            guard !highlighting, let view = notification.object as? NSTextView, !view.hasMarkedText() else { return }
            if view.string.count > parent.limit { view.string = String(view.string.prefix(parent.limit)) }
            if parent.text != view.string { parent.text = view.string }
            applyTextAppearance(in: view)
            scheduleHighlight(in: view)
            (view.enclosingScrollView as? CourseAnswerScrollView)?.invalidateContentHeight()
        }
        func scheduleHighlight(in view: NSTextView) {
            highlightTask?.cancel()
            guard parent.input.kind == .code, !view.hasMarkedText() else { return }
            let source = view.string
            let language = parent.input.language
            let isCode = parent.input.kind == .code
            highlightTask = Task { @MainActor [weak self, weak view] in
                try? await Task.sleep(for: .milliseconds(70))
                guard !Task.isCancelled else { return }
                let tokens = isCode ? await Task.detached(priority: .utility) {
                    CourseAnswerSyntax.tokens(in: source, language: language)
                }.value : []
                guard let self, let view, !Task.isCancelled, view.string == source, !view.hasMarkedText(), let storage = view.textStorage else { return }
                self.highlighting = true
                let undoEnabled = view.undoManager?.isUndoRegistrationEnabled == true
                if undoEnabled { view.undoManager?.disableUndoRegistration() }
                storage.beginEditing()
                let font = view.font ?? NSFont.systemFont(ofSize: self.parent.fontSize)
                storage.addAttributes([.foregroundColor: NSColor.labelColor, .font: font], range: NSRange(location: 0, length: storage.length))
                for token in tokens {
                    let color: NSColor
                    switch token.kind {
                    case .keyword: color = .systemPurple
                    case .string: color = .systemRed
                    case .comment: color = .secondaryLabelColor
                    case .number: color = .systemOrange
                    case .function: color = NSColor(self.parent.accent)
                    case .type: color = .systemTeal
                    }
                    storage.addAttribute(.foregroundColor, value: color, range: token.range)
                }
                storage.endEditing()
                view.typingAttributes = [.font: font, .foregroundColor: NSColor.labelColor]
                if undoEnabled { view.undoManager?.enableUndoRegistration() }
                self.highlighting = false
            }
        }
    }
}

private final class CourseAnswerScrollView: NSScrollView {
    var heightChanged: ((CGFloat) -> Void)?
    private var reportedHeight: CGFloat = 0
    private var measuredWidth: CGFloat = 0
    private var needsHeightMeasurement = true
    func invalidateContentHeight() {
        needsHeightMeasurement = true
        needsLayout = true
    }
    override func layout() {
        super.layout()
        guard let view = documentView as? NSTextView, let container = view.textContainer,
              let manager = view.layoutManager, contentSize.width > 0 else { return }
        if abs(view.frame.width - contentSize.width) > 0.5 { view.setFrameSize(NSSize(width: contentSize.width, height: view.frame.height)) }
        if needsHeightMeasurement || abs(contentSize.width - measuredWidth) > 0.5 {
            needsHeightMeasurement = false
            measuredWidth = contentSize.width
            manager.ensureLayout(for: container)
            let height = manager.usedRect(for: container).height + view.textContainerInset.height * 2
            if abs(height - reportedHeight) > 0.5 {
                reportedHeight = height
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.heightChanged?(self.reportedHeight)
                }
            }
        }
        let documentHeight = max(contentSize.height, reportedHeight)
        if abs(view.frame.height - documentHeight) > 0.5 {
            view.setFrameSize(NSSize(width: contentSize.width, height: documentHeight))
        }
    }
}

private final class CourseAnswerTextView: NSTextView {
    var codeMode = false
    var wantsFocus = false
    var focusChanged: ((Bool) -> Void)?
    func commitPendingInput() {
        if hasMarkedText() { unmarkText() }
        // unmarkText normally posts this itself. Also flush when the input
        // method has just ended composition but its change hasn't been posted.
        delegate?.textDidChange?(Notification(name: NSText.didChangeNotification, object: self))
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if wantsFocus { window?.makeFirstResponder(self) }
    }
    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result { focusChanged?(true) }
        return result
    }
    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result { focusChanged?(false) }
        return result
    }
    override func insertTab(_ sender: Any?) {
        if codeMode && !hasMarkedText() { changeIndentation(outdent: false) }
        else { super.insertTab(sender) }
    }
    override func insertBacktab(_ sender: Any?) {
        if codeMode && !hasMarkedText() { changeIndentation(outdent: true) }
        else { super.insertBacktab(sender) }
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if codeMode, window?.firstResponder === self, !hasMarkedText(),
           event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command {
            if event.charactersIgnoringModifiers == "]" { changeIndentation(outdent: false); return true }
            if event.charactersIgnoringModifiers == "[" { changeIndentation(outdent: true); return true }
        }
        return super.performKeyEquivalent(with: event)
    }
    private func changeIndentation(outdent: Bool) {
        guard let change = CourseAnswerEditing.indentation(in: string, selection: selectedRange(), outdent: outdent) else { return }
        let expected = (string as NSString).replacingCharacters(in: change.range, with: change.replacement)
        // NSTextView's insertion path preserves validation, undo, and IME state.
        insertText(change.replacement, replacementRange: change.range)
        if string == expected { setSelectedRange(change.selection) }
    }
    override func insertNewline(_ sender: Any?) {
        if codeMode && !hasMarkedText() {
            insertText(CourseAnswerEditing.newline(in: string, at: selectedRange().location), replacementRange: selectedRange())
        } else { super.insertNewline(sender) }
    }
}
#endif
