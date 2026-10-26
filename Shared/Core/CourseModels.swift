import Foundation

enum CourseBlockType: String, Codable, CaseIterable { case text, callout, image, chart, question }
enum CourseChartType: String, Codable, CaseIterable { case bar, line }
enum CourseQuestionType: String, Codable, CaseIterable { case singleChoice, multipleChoice, shortAnswer }
enum CoursePresentationKind: String, Codable, CaseIterable { case code, table, steps, comparison, flashcards, markdown, html, svg, trace }
enum CourseAnswerFormat: String, Codable, CaseIterable { case text, code, output }
enum CourseQuestionInputKind: String, Codable, CaseIterable { case text, integer, decimal, code }

/// An author's input preference; omitted values preserve the existing short-answer behavior.
struct CourseQuestionInput: Codable, Equatable {
    var kind: CourseQuestionInputKind
    var language: String? = nil
    var placeholder: String? = nil
    var starterCode: String? = nil
    var minLines: Int? = nil
    var maxLines: Int? = nil
}

/// Execution is opt-in per question. A template substitutes exactly one literal answer slot.
struct CourseExecutionConfiguration: Codable, Equatable {
    var language: String
    var template: String? = nil
    var stdin: String? = nil
    var expectedOutput: String? = nil
}

/// Native code examples remain literal source; interactive web content has its own sandboxed payload.
struct CourseCodeSample: Codable, Equatable {
    var language: String
    var source: String
    var filename: String? = nil
    var highlightLines: [Int]? = nil
    var annotations: [CourseLineAnnotation]? = nil
    var stdin: String? = nil
    var expectedOutput: String? = nil
    var highlightSpans: [CourseCodeSpan]? = nil
}

/// A literal substring on one source line; occurrences count non-overlapping matches from one.
struct CourseCodeSpan: Codable, Equatable {
    var line: Int
    var text: String
    var occurrence: Int? = nil
}

struct CourseCodeSegment: Equatable {
    var text: String
    var highlighted: Bool
}

enum CourseCodeMarking {
    /// The caller supplies spans for this row. Overlaps are merged without changing the source text.
    static func segments(line: String, spans: [CourseCodeSpan]) -> [CourseCodeSegment] {
        let ranges = spans.compactMap { matchingRange(in: line, span: $0) }
            .sorted { $0.lowerBound < $1.lowerBound }
        guard !ranges.isEmpty else { return [CourseCodeSegment(text: line, highlighted: false)] }
        var merged: [Range<String.Index>] = []
        for range in ranges {
            if let last = merged.last, range.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else { merged.append(range) }
        }
        var result: [CourseCodeSegment] = []
        var cursor = line.startIndex
        for range in merged {
            if cursor < range.lowerBound {
                result.append(CourseCodeSegment(text: String(line[cursor..<range.lowerBound]), highlighted: false))
            }
            result.append(CourseCodeSegment(text: String(line[range]), highlighted: true))
            cursor = range.upperBound
        }
        if cursor < line.endIndex {
            result.append(CourseCodeSegment(text: String(line[cursor...]), highlighted: false))
        }
        return result
    }

    fileprivate static func matchingRange(in line: String, span: CourseCodeSpan) -> Range<String.Index>? {
        let occurrence = span.occurrence ?? 1
        guard !span.text.isEmpty, (1...20_000).contains(occurrence) else { return nil }
        var cursor = line.startIndex
        var match: Range<String.Index>?
        for _ in 0..<occurrence {
            guard let next = line.range(of: span.text, options: .literal, range: cursor..<line.endIndex) else { return nil }
            match = next
            cursor = next.upperBound
        }
        return match
    }
}

struct CourseLineAnnotation: Codable, Equatable {
    var line: Int
    var text: String
}

struct CourseTableContent: Codable, Equatable {
    var columns: [String]
    var rows: [[String]]
}

struct CourseTeachingItem: Codable, Equatable {
    var title: String
    var text: String
    var code: CourseCodeSample? = nil
}

struct CourseFlashcardContent: Codable, Equatable {
    var front: String
    var back: String
}

struct CourseMarkdownContent: Codable, Equatable {
    var source: String
}

/// Self-contained content rendered in an isolated web view with networking disabled.
struct CourseWebContent: Codable, Equatable {
    var source: String
    var height: Int? = nil
}

/// Author-written teaching frames, not the output of compiling or executing source.
struct CourseTraceContent: Codable, Equatable {
    var variants: [CourseTraceVariant]
}

struct CourseTraceVariant: Codable, Equatable {
    var id: String
    var title: String
    var code: CourseCodeSample
    var frames: [CourseTraceFrame]
}

struct CourseTraceFrame: Codable, Equatable {
    var title: String
    var line: Int
    var note: String
    var objects: [CourseTraceObject]
    var output: String? = nil
    var focusSpans: [CourseCodeSpan]? = nil
}

struct CourseTraceObject: Codable, Equatable {
    var id: String
    var names: [String]
    var value: String
    var scope: String? = nil
    var changed: Bool? = nil
}

/// Exactly one payload must match kind. The block's text remains a complete fallback.
struct CoursePresentation: Codable, Equatable {
    var kind: CoursePresentationKind
    var code: CourseCodeSample? = nil
    var table: CourseTableContent? = nil
    var steps: [CourseTeachingItem]? = nil
    var items: [CourseTeachingItem]? = nil
    var cards: [CourseFlashcardContent]? = nil
    var markdown: CourseMarkdownContent? = nil
    var html: CourseWebContent? = nil
    var svg: CourseWebContent? = nil
    var trace: CourseTraceContent? = nil
}

struct CourseChartPoint: Codable, Equatable {
    var label: String
    var value: Double
}

struct CourseOption: Codable, Equatable, Identifiable {
    var id: String
    var text: String
}

struct CourseBlock: Codable, Equatable, Identifiable {
    var id = UUID()
    var type: CourseBlockType
    var text: String? = nil
    var url: String? = nil
    var caption: String? = nil
    var chartType: CourseChartType? = nil
    var points: [CourseChartPoint]? = nil
    var questionType: CourseQuestionType? = nil
    var options: [CourseOption]? = nil
    var correctOptionIDs: [String]? = nil
    var acceptedAnswers: [String]? = nil
    var explanation: String? = nil
    var title: String? = nil
    var presentation: CoursePresentation? = nil
    var code: CourseCodeSample? = nil
    var hints: [String]? = nil
    var answerFormat: CourseAnswerFormat? = nil
    var input: CourseQuestionInput? = nil
    var execution: CourseExecutionConfiguration? = nil
    var focusLines: [Int]? = nil
    var focusSpans: [CourseCodeSpan]? = nil

    /// Only literal, explicitly authored source can become the persistent program reference.
    fileprivate var directCodeContext: CourseCodeSample? {
        if let code { return code }
        if let code = presentation?.code { return code }
        if let code = presentation?.trace?.variants.first?.code { return code }
        if let execution, let template = execution.template {
            return CourseCodeSample(language: execution.language, source: template,
                                    stdin: execution.stdin, expectedOutput: execution.expectedOutput)
        }
        return nil
    }

    var resolvedInput: CourseQuestionInput {
        var value = input ?? CourseQuestionInput(kind: answerFormat == .code || execution != nil ? .code : .text)
        if value.kind == .code && value.language == nil {
            let language = execution?.language ?? code?.language ?? "javascript"
            switch language.lowercased() {
            case "javascript", "js": value.language = "javascript"
            case "python", "py": value.language = "python"
            case "cpp", "c++", "c": value.language = "cpp"
            default: value.language = "plaintext"
            }
        }
        return value
    }

    var answerTextLimit: Int {
        if resolvedInput.kind == .code { return 20_000 }
        return switch answerFormat ?? .text {
        case .text: 4_000
        case .code: 20_000
        case .output: 8_000
        }
    }

    /// A nil result means an open response has no automatic answer key.
    func evaluate(selectedOptionIDs: Set<String>, text: String) -> Bool? {
        guard type == .question else { return nil }
        switch questionType {
        case .singleChoice, .multipleChoice:
            guard let correctOptionIDs else { return nil }
            return selectedOptionIDs == Set(correctOptionIDs)
        case .shortAnswer:
            guard let acceptedAnswers, !acceptedAnswers.isEmpty else { return nil }
            if resolvedInput.kind == .code || answerFormat == .code || answerFormat == .output {
                let response = Self.literalAnswer(text)
                return acceptedAnswers.contains { Self.literalAnswer($0) == response }
            }
            let response = Self.normalizedAnswer(text)
            return acceptedAnswers.contains { Self.normalizedAnswer($0) == response }
        case nil: return nil
        }
    }

    private static func normalizedAnswer(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            .folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    private static func literalAnswer(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct CourseLesson: Codable, Equatable, Identifiable {
    var id = UUID()
    var title: String
    var blocks: [CourseBlock]
    var objectives: [String]? = nil
    var estimatedMinutes: Int? = nil
    var referenceCode: CourseCodeSample? = nil

    /// Resolves within this lesson so an older course can keep its program visible while paging.
    /// Neighboring blocks supply source only; their old focus must not follow the learner.
    func codeContext(for blockID: UUID, courseReference: CourseCodeSample? = nil) -> CourseCodeSample? {
        guard let index = blocks.firstIndex(where: { $0.id == blockID }) else { return nil }
        let block = blocks[index]
        if var code = block.directCodeContext ?? referenceCode ?? courseReference {
            if block.focusLines != nil || block.focusSpans != nil {
                code.highlightLines = block.focusLines
                code.highlightSpans = block.focusSpans
            }
            return code
        }
        for previous in blocks[..<index].reversed() {
            if var code = previous.directCodeContext {
                code.highlightLines = block.focusLines
                code.highlightSpans = block.focusSpans
                return code
            }
        }
        for next in blocks.dropFirst(index + 1) {
            if var code = next.directCodeContext {
                code.highlightLines = block.focusLines
                code.highlightSpans = block.focusSpans
                return code
            }
        }
        return nil
    }
}

struct CourseDocument: Codable, Equatable, Identifiable {
    var protocolVersion = "WORKSHOP-COURSE/1"
    var id = UUID()
    var title: String
    var summary: String = ""
    var lessons: [CourseLesson]
    var referenceCode: CourseCodeSample? = nil

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol"
        case id, title, summary, lessons, referenceCode
    }
}

struct CourseSummary: Codable, Equatable, Identifiable {
    var id: UUID
    var title: String
    var summary: String
    var revision: Int
    var updatedAt: Date
    var lessonCount: Int
}

struct CourseEdition: Codable, Equatable {
    var course: CourseDocument
    var revision: Int
    var updatedAt: Date
}

struct CourseCatalog: Codable, Equatable {
    var courses: [CourseSummary]
    // Optional so catalog caches made before personal stars remain readable.
    var starredCourseIDs: [UUID]? = nil

    func isStarred(_ id: UUID) -> Bool { starredCourseIDs?.contains(id) == true }
    mutating func setStarred(_ id: UUID, starred: Bool) {
        var ids = Set(starredCourseIDs ?? [])
        if starred { ids.insert(id) } else { ids.remove(id) }
        starredCourseIDs = ids.sorted { $0.uuidString < $1.uuidString }
    }
}

struct CourseAnswer: Codable, Equatable {
    var lessonID: UUID
    var blockID: UUID
    var selectedOptionIDs: [String] = []
    var text: String = ""
    var updatedAt: Date
}

struct CourseProgressUpdate: Codable, Equatable {
    var mutationID = UUID()
    var courseRevision: Int
    var lessonID: UUID
    var blockID: UUID? = nil
    var selectedOptionIDs: [String]? = nil
    var text: String? = nil
    var completed: Bool? = nil
}

struct CourseProgress: Codable, Equatable {
    var courseID: UUID
    var courseRevision: Int? = nil
    var completedLessonIDs: [UUID] = []
    var answers: [CourseAnswer] = []

    init(courseID: UUID, courseRevision: Int? = nil, completedLessonIDs: [UUID] = [], answers: [CourseAnswer] = []) {
        self.courseID = courseID
        self.courseRevision = courseRevision
        self.completedLessonIDs = completedLessonIDs
        self.answers = answers
    }

    enum CodingKeys: String, CodingKey { case courseID, courseRevision, completedLessonIDs, answers }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        courseID = try values.decode(UUID.self, forKey: .courseID)
        courseRevision = try values.decodeIfPresent(Int.self, forKey: .courseRevision)
        completedLessonIDs = try values.decodeIfPresent([UUID].self, forKey: .completedLessonIDs) ?? []
        answers = try values.decodeIfPresent([CourseAnswer].self, forKey: .answers) ?? []
    }

    /// Validate against the current edition before changing any locally cached progress.
    mutating func apply(update: CourseProgressUpdate, edition: CourseEdition, at date: Date = Date()) throws {
        guard courseID == edition.course.id, update.courseRevision == edition.revision,
              courseRevision == nil || courseRevision == edition.revision else {
            throw WorkspaceFailure.invalid(WorkspaceLocalization.string("课程已更新，请刷新后重试。"))
        }
        guard let lesson = edition.course.lessons.first(where: { $0.id == update.lessonID }) else {
            throw WorkspaceFailure.invalid(WorkspaceLocalization.string("课时不存在。"))
        }
        var next = self
        if let blockID = update.blockID {
            guard let block = lesson.blocks.first(where: { $0.id == blockID }), block.type == .question else {
                throw WorkspaceFailure.invalid(WorkspaceLocalization.string("题目不存在。"))
            }
            let selected = update.selectedOptionIDs ?? []
            let text = update.text ?? ""
            try CourseValidation.validateAnswer(block: block, selected: selected, text: text)
            next.answers.removeAll { $0.lessonID == lesson.id && $0.blockID == block.id }
            next.answers.append(CourseAnswer(lessonID: lesson.id, blockID: block.id,
                                             selectedOptionIDs: selected, text: text, updatedAt: date))
        } else if update.selectedOptionIDs != nil || update.text != nil || update.completed == nil {
            throw WorkspaceFailure.invalid(WorkspaceLocalization.string("请指定题目或课时完成状态。"))
        }
        if let completed = update.completed {
            if completed {
                for block in lesson.blocks where block.type == .question {
                    guard let answer = next.answers.first(where: { $0.lessonID == lesson.id && $0.blockID == block.id }) else {
                        throw WorkspaceFailure.invalid(WorkspaceLocalization.string("请先回答本课时的所有题目。"))
                    }
                    try CourseValidation.validateAnswer(block: block, selected: answer.selectedOptionIDs, text: answer.text)
                }
            }
            next.completedLessonIDs.removeAll { $0 == lesson.id }
            if completed { next.completedLessonIDs.append(lesson.id) }
        }
        next.courseRevision = edition.revision
        self = next
    }
}

struct CourseLearningTarget: Equatable {
    var courseID: UUID
    var lessonID: UUID
    var revision: Int
}

/// Derive a continuation from existing progress; no separate completion state is stored.
enum CourseLearningContinuation {
    static func orderedCourses(_ courses: [CourseSummary], progress: [UUID: CourseProgress]) -> [CourseSummary] {
        let ranked = courses.enumerated().map { index, course in
            let saved = progress[course.id].flatMap {
                $0.courseID == course.id && ($0.courseRevision == nil || $0.courseRevision == course.revision) ? $0 : nil
            }
            return (course: course, index: index,
                completed: Set(saved?.completedLessonIDs ?? []).count >= course.lessonCount,
                lastStudy: saved?.answers.map(\.updatedAt).max() ?? .distantPast)
        }
        return ranked.sorted { lhs, rhs in
            if lhs.completed != rhs.completed { return !lhs.completed }
            if lhs.lastStudy != rhs.lastStudy { return lhs.lastStudy > rhs.lastStudy }
            return lhs.index < rhs.index
        }.map { $0.course }
    }

    static func nextLesson(in edition: CourseEdition, progress: CourseProgress?) -> CourseLesson? {
        guard let progress, progress.courseID == edition.course.id,
              progress.courseRevision == nil || progress.courseRevision == edition.revision else {
            return edition.course.lessons.first
        }
        let completed = Set(progress.completedLessonIDs)
        let remaining = edition.course.lessons.filter { !completed.contains($0.id) }
        let questions = Dictionary(uniqueKeysWithValues: remaining.map { lesson in
            (lesson.id, Set(lesson.blocks.filter { $0.type == .question }.map(\.id)))
        })
        if let latest = progress.answers.filter({ questions[$0.lessonID]?.contains($0.blockID) == true })
            .max(by: { $0.updatedAt < $1.updatedAt }) {
            return remaining.first { $0.id == latest.lessonID }
        }
        return remaining.first
    }
}

enum CourseValidation {
    static func validate(_ course: CourseDocument) throws {
        try require(course.protocolVersion == "WORKSHOP-COURSE/1", WorkspaceLocalization.string("不支持的课程协议。"))
        try bounded(course.title, max: 240, required: true)
        try bounded(course.summary, max: 2_000)
        if let referenceCode = course.referenceCode { try validateCode(referenceCode) }
        try require((1...40).contains(course.lessons.count), WorkspaceLocalization.string("课程应包含 1 至 40 个课时。"))
        var ids: Set<UUID> = [course.id]
        for lesson in course.lessons {
            try require(ids.insert(lesson.id).inserted, WorkspaceLocalization.string("课程、课时与内容块的 ID 不可重复。"))
            try bounded(lesson.title, max: 240, required: true)
            if let referenceCode = lesson.referenceCode { try validateCode(referenceCode) }
            if let objectives = lesson.objectives {
                try require(objectives.count <= 6, WorkspaceLocalization.string("每课时最多提供 6 个学习目标。"))
                for objective in objectives { try bounded(objective, max: 500, required: true) }
            }
            if let minutes = lesson.estimatedMinutes {
                try require((1...180).contains(minutes), WorkspaceLocalization.string("预计学习时长应为 1 至 180 分钟。"))
            }
            try require((1...80).contains(lesson.blocks.count), WorkspaceLocalization.string("课时应包含 1 至 80 个内容块。"))
            for block in lesson.blocks {
                try require(ids.insert(block.id).inserted, WorkspaceLocalization.string("课程、课时与内容块的 ID 不可重复。"))
                if let title = block.title { try bounded(title, max: 240, required: true) }
                if let presentation = block.presentation {
                    try require(block.type == .text || block.type == .callout, WorkspaceLocalization.string("仅文字和要点块支持结构化展示。"))
                    try validatePresentation(presentation)
                }
                if let code = block.code {
                    try require(block.type == .question, WorkspaceLocalization.string("题目之外的代码示例请放入 presentation。"))
                    try validateCode(code)
                }
                if let hints = block.hints {
                    try require(block.type == .question && hints.count <= 5, WorkspaceLocalization.string("每道题最多提供 5 条提示。"))
                    for hint in hints { try bounded(hint, max: 2_000, required: true) }
                }
                if block.answerFormat != nil {
                    try require(block.type == .question && block.questionType == .shortAnswer,
                                WorkspaceLocalization.string("仅简答题支持指定文字、代码或输出答案。"))
                }
                if let input = block.input {
                    try require(block.type == .question && block.questionType == .shortAnswer,
                                WorkspaceLocalization.string("仅简答题支持指定输入方式。"))
                    try validateInput(input)
                }
                if let execution = block.execution {
                    try require(block.type == .question && block.questionType == .shortAnswer,
                                WorkspaceLocalization.string("仅简答题支持运行答案。"))
                    try validateExecution(execution, input: block.resolvedInput)
                }
                if let focusLines = block.focusLines {
                    try require(focusLines.count <= 200 && Set(focusLines).count == focusLines.count,
                                WorkspaceLocalization.string("代码关注行最多 200 行且不能重复。"))
                    if !focusLines.isEmpty {
                        guard let code = lesson.codeContext(for: block.id, courseReference: course.referenceCode) else {
                            throw WorkspaceFailure.invalid(WorkspaceLocalization.string("代码关注行需要可显示的程序代码。"))
                        }
                        let lineCount = code.source.replacingOccurrences(of: "\r\n", with: "\n")
                            .replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n").count
                        try require(focusLines.allSatisfy { (1...lineCount).contains($0) },
                                    WorkspaceLocalization.string("代码关注行必须在程序源码范围内。"))
                    }
                }
                if let focusSpans = block.focusSpans {
                    try validateSpans(focusSpans, source: lesson.codeContext(for: block.id, courseReference: course.referenceCode)?.source)
                }
                try bounded(block.caption ?? "", max: 2_000)
                try bounded(block.explanation ?? "", max: 4_000)
                try bounded(block.text ?? "", max: block.type == .question ? 4_000 : 20_000,
                            required: [.text, .callout, .question].contains(block.type))
                if let url = block.url {
                    try bounded(url, max: 2_048, required: true)
                    let components = URLComponents(string: url)
                    try require(url.range(of: #"\.svg(?:$|[?#])"#, options: [.regularExpression, .caseInsensitive]) == nil,
                                WorkspaceLocalization.string("课程图片暂不支持 SVG，请使用 PNG、JPEG 或其他位图格式。"))
                    try require(url.utf16.count <= 2_048 && components?.scheme?.lowercased() == "https"
                                && !(components?.host?.isEmpty ?? true) && components?.user == nil && components?.password == nil,
                                WorkspaceLocalization.string("课程图片必须使用不含账号密码的 HTTPS 地址。"))
                }
                switch block.type {
                case .text, .callout: break
                case .image:
                    try require(block.url != nil, WorkspaceLocalization.string("图片需要 HTTPS 地址。"))
                case .chart:
                    try require(block.chartType != nil, WorkspaceLocalization.string("请选择图表类型。"))
                    let points = block.points ?? []
                    try require((1...60).contains(points.count), WorkspaceLocalization.string("图表应包含 1 至 60 个数据点。"))
                    for point in points {
                        try bounded(point.label, max: 120, required: true)
                        try require(point.value.isFinite && abs(point.value) <= 1e15, WorkspaceLocalization.string("图表数值必须是绝对值不超过 10¹⁵ 的有限数字。"))
                    }
                case .question:
                    try validateQuestion(block)
                }
            }
        }
    }

    static func validateAnswer(block: CourseBlock, selected: [String], text: String) throws {
        try require(block.type == .question, WorkspaceLocalization.string("仅题目可以提交答案。"))
        try bounded(text, max: block.answerTextLimit)
        let selectedSet = Set(selected)
        try require(selectedSet.count == selected.count, WorkspaceLocalization.string("选项不可重复。"))
        switch block.questionType {
        case .singleChoice, .multipleChoice:
            let valid = Set((block.options ?? []).map(\.id))
            try require(!selected.isEmpty && selectedSet.isSubset(of: valid) && text.isEmpty,
                        WorkspaceLocalization.string("请选择有效答案。"))
            if block.questionType == .singleChoice {
                try require(selected.count == 1, WorkspaceLocalization.string("单选题请选择一个答案。"))
            }
        case .shortAnswer:
            try require(selected.isEmpty && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                        WorkspaceLocalization.string("请填写答案。"))
            try validateNumericAnswer(text, kind: block.resolvedInput.kind)
        case nil: throw WorkspaceFailure.invalid(WorkspaceLocalization.string("题目类型无效。"))
        }
    }

    private static func validateQuestion(_ block: CourseBlock) throws {
        switch block.questionType {
        case .singleChoice, .multipleChoice:
            let options = block.options ?? []
            try require((2...12).contains(options.count), WorkspaceLocalization.string("选择题应包含 2 至 12 个选项。"))
            var optionIDs = Set<String>()
            for option in options {
                try require(!option.id.isEmpty && option.id.utf8.count <= 40
                            && option.id.unicodeScalars.allSatisfy {
                                (65...90).contains($0.value) || (97...122).contains($0.value)
                                || (48...57).contains($0.value) || $0.value == 45 || $0.value == 95
                            } && optionIDs.insert(option.id).inserted, WorkspaceLocalization.string("选项 ID 应为不重复的 ASCII 字母、数字、短横线或下划线。"))
                try bounded(option.text, max: 1_000, required: true)
            }
            let correct = block.correctOptionIDs ?? []
            try require(!correct.isEmpty && Set(correct).count == correct.count
                        && Set(correct).isSubset(of: optionIDs), WorkspaceLocalization.string("正确答案应引用已有选项。"))
            if block.questionType == .singleChoice {
                try require(correct.count == 1, WorkspaceLocalization.string("单选题应恰好有一个正确答案。"))
            }
            try require(block.acceptedAnswers == nil, WorkspaceLocalization.string("选择题不可配置文字答案。"))
        case .shortAnswer:
            try require(block.options == nil && block.correctOptionIDs == nil, WorkspaceLocalization.string("简答题不可配置选项。"))
            let accepted = block.acceptedAnswers ?? []
            try require(accepted.count <= 20 && Set(accepted).count == accepted.count, WorkspaceLocalization.string("简答题最多支持 20 个不重复的参考答案。"))
            let limit = block.resolvedInput.kind == .code || block.answerFormat == .code || block.answerFormat == .output
                ? block.answerTextLimit : 500
            for answer in accepted {
                try bounded(answer, max: limit, required: true)
                try validateNumericAnswer(answer, kind: block.resolvedInput.kind)
            }
        case nil: throw WorkspaceFailure.invalid(WorkspaceLocalization.string("请选择题目类型。"))
        }
    }

    private static func validateInput(_ value: CourseQuestionInput) throws {
        if let placeholder = value.placeholder { try bounded(placeholder, max: 500) }
        if let min = value.minLines { try require((2...24).contains(min), WorkspaceLocalization.string("输入框行数应为 2 至 24 行。")) }
        if let max = value.maxLines { try require((2...24).contains(max), WorkspaceLocalization.string("输入框行数应为 2 至 24 行。")) }
        if let min = value.minLines, let max = value.maxLines {
            try require(max >= min, WorkspaceLocalization.string("输入框最大行数不能小于最小行数。"))
        }
        if value.kind == .code {
            if let language = value.language {
                try require(["javascript", "python", "cpp"].contains(language), WorkspaceLocalization.string("代码输入语言应为 javascript、python 或 cpp。"))
            }
            if let starterCode = value.starterCode { try bounded(starterCode, max: 20_000) }
        } else {
            try require(value.language == nil && value.starterCode == nil, WorkspaceLocalization.string("仅代码输入支持语言和初始源码。"))
        }
    }

    private static func validateExecution(_ value: CourseExecutionConfiguration, input: CourseQuestionInput) throws {
        try require(["javascript", "python", "cpp"].contains(value.language), WorkspaceLocalization.string("运行语言应为 javascript、python 或 cpp。"))
        if let template = value.template {
            try bounded(template, max: 20_000, required: true)
            try require(template.components(separatedBy: "{{ANSWER}}").count == 2,
                        WorkspaceLocalization.string("运行模板必须恰好包含一个 {{ANSWER}}。"))
        }
        if input.kind != .code {
            try require(value.template != nil, WorkspaceLocalization.string("非代码输入的运行题需要包含 {{ANSWER}} 的代码模板。"))
        }
        if input.kind == .code, let language = input.language {
            try require(language == value.language, WorkspaceLocalization.string("代码输入与运行语言应一致。"))
        }
        if let stdin = value.stdin { try bounded(stdin, max: 4_000) }
        if let output = value.expectedOutput { try bounded(output, max: 8_000) }
    }

    private static func validateNumericAnswer(_ text: String, kind: CourseQuestionInputKind) throws {
        let pattern: String
        switch kind {
        case .integer: pattern = #"^[+-]?[0-9]+$"#
        case .decimal: pattern = #"^[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)$"#
        case .text, .code: return
        }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        try require(value.range(of: pattern, options: .regularExpression) != nil,
                    kind == .integer ? WorkspaceLocalization.string("请填写有效的整数。") : WorkspaceLocalization.string("请填写有效的小数。"))
    }

    private static func validatePresentation(_ value: CoursePresentation) throws {
        let payloads = [value.code != nil, value.table != nil, value.steps != nil, value.items != nil,
                        value.cards != nil, value.markdown != nil, value.html != nil, value.svg != nil, value.trace != nil]
        try require(payloads.filter { $0 }.count == 1, WorkspaceLocalization.string("结构化展示必须且只能包含一种匹配的内容。"))
        switch value.kind {
        case .trace:
            guard let trace = value.trace else { throw WorkspaceFailure.invalid(WorkspaceLocalization.string("推演展示需要 trace 内容。")) }
            try validateTrace(trace)
        case .code:
            guard let code = value.code else { throw WorkspaceFailure.invalid(WorkspaceLocalization.string("代码展示需要 code 内容。")) }
            try validateCode(code)
        case .table:
            guard let table = value.table else { throw WorkspaceFailure.invalid(WorkspaceLocalization.string("表格展示需要 table 内容。")) }
            try require((1...8).contains(table.columns.count) && (1...60).contains(table.rows.count),
                        WorkspaceLocalization.string("表格应包含 1 至 8 列、1 至 60 行。"))
            for column in table.columns { try bounded(column, max: 120, required: true) }
            for row in table.rows {
                try require(row.count == table.columns.count, WorkspaceLocalization.string("表格每行的单元格数量必须与列数一致。"))
                for cell in row { try bounded(cell, max: 2_000) }
            }
        case .steps:
            guard let steps = value.steps else { throw WorkspaceFailure.invalid(WorkspaceLocalization.string("分步展示需要 steps 内容。")) }
            try require((1...20).contains(steps.count), WorkspaceLocalization.string("分步展示应包含 1 至 20 步。"))
            for step in steps { try validateTeachingItem(step) }
        case .comparison:
            guard let items = value.items else { throw WorkspaceFailure.invalid(WorkspaceLocalization.string("对照展示需要 items 内容。")) }
            try require((2...4).contains(items.count), WorkspaceLocalization.string("对照展示应包含 2 至 4 项。"))
            for item in items { try validateTeachingItem(item) }
        case .flashcards:
            guard let cards = value.cards else { throw WorkspaceFailure.invalid(WorkspaceLocalization.string("记忆卡片需要 cards 内容。")) }
            try require((1...20).contains(cards.count), WorkspaceLocalization.string("记忆卡片应包含 1 至 20 张。"))
            for card in cards {
                try bounded(card.front, max: 2_000, required: true)
                try bounded(card.back, max: 4_000, required: true)
            }
        case .markdown:
            guard let markdown = value.markdown else { throw WorkspaceFailure.invalid(WorkspaceLocalization.string("Markdown 展示需要 markdown 内容。")) }
            try bounded(markdown.source, max: 20_000, required: true)
        case .html:
            guard let html = value.html else { throw WorkspaceFailure.invalid(WorkspaceLocalization.string("HTML 展示需要 html 内容。")) }
            try validateWebContent(html)
        case .svg:
            guard let svg = value.svg else { throw WorkspaceFailure.invalid(WorkspaceLocalization.string("SVG 展示需要 svg 内容。")) }
            try validateWebContent(svg)
        }
    }

    private static func validateTrace(_ trace: CourseTraceContent) throws {
        try require((1...4).contains(trace.variants.count), WorkspaceLocalization.string("推演应包含 1 至 4 个方案。"))
        var variantIDs = Set<String>()
        for variant in trace.variants {
            try validateTraceIdentifier(variant.id)
            try require(variantIDs.insert(variant.id).inserted, WorkspaceLocalization.string("推演方案 ID 不可重复。"))
            try bounded(variant.title, max: 120, required: true)
            try validateCode(variant.code)
            let lineCount = variant.code.source.replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n").count
            try require((2...24).contains(variant.frames.count), WorkspaceLocalization.string("每个推演方案应包含 2 至 24 帧。"))
            for frame in variant.frames {
                try bounded(frame.title, max: 120, required: true)
                try bounded(frame.note, max: 400, required: true)
                try require((1...lineCount).contains(frame.line), WorkspaceLocalization.string("推演行号超出源码范围。"))
                if let focusSpans = frame.focusSpans { try validateSpans(focusSpans, source: variant.code.source) }
                try require((1...4).contains(frame.objects.count), WorkspaceLocalization.string("每帧应包含 1 至 4 个对象。"))
                var objectIDs = Set<String>()
                for object in frame.objects {
                    try validateTraceIdentifier(object.id)
                    try require(objectIDs.insert(object.id).inserted, WorkspaceLocalization.string("同一帧的对象 ID 不可重复。"))
                    try require((1...3).contains(object.names.count), WorkspaceLocalization.string("每个对象应有 1 至 3 个名称。"))
                    for name in object.names { try bounded(name, max: 80, required: true) }
                    try bounded(object.value, max: 120, required: true)
                    if let scope = object.scope { try bounded(scope, max: 80, required: true) }
                }
                if let output = frame.output { try bounded(output, max: 2_000) }
            }
        }
    }

    private static func validateTraceIdentifier(_ id: String) throws {
        try require(!id.isEmpty && id.utf8.count <= 40 && id.unicodeScalars.allSatisfy {
            (65...90).contains($0.value) || (97...122).contains($0.value)
                || (48...57).contains($0.value) || $0.value == 45 || $0.value == 95
        }, WorkspaceLocalization.string("推演 ID 应为 1 至 40 个 ASCII 字母、数字、短横线或下划线。"))
    }

    private static func validateWebContent(_ content: CourseWebContent) throws {
        try bounded(content.source, max: 60_000, required: true)
        if let height = content.height {
            try require((120...640).contains(height), WorkspaceLocalization.string("互动内容高度应为 120 至 640。"))
        }
    }

    private static func validateTeachingItem(_ item: CourseTeachingItem) throws {
        try bounded(item.title, max: 240, required: true)
        try bounded(item.text, max: 4_000, required: true)
        if let code = item.code { try validateCode(code) }
    }

    private static func validateCode(_ code: CourseCodeSample) throws {
        try require(!code.language.isEmpty && code.language.utf8.count <= 40 && code.language.unicodeScalars.allSatisfy {
            (65...90).contains($0.value) || (97...122).contains($0.value) || (48...57).contains($0.value)
                || [43, 45, 46, 95].contains($0.value)
        }, WorkspaceLocalization.string("代码语言应为 1 至 40 个字母、数字或 +、-、.、_。"))
        try bounded(code.source, max: 20_000, required: true)
        if let filename = code.filename { try bounded(filename, max: 240, required: true) }
        if let stdin = code.stdin { try bounded(stdin, max: 4_000) }
        if let output = code.expectedOutput { try bounded(output, max: 8_000) }
        let lineCount = code.source.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n").count
        if let highlights = code.highlightLines {
            try require(highlights.count <= 200 && Set(highlights).count == highlights.count
                        && highlights.allSatisfy { (1...lineCount).contains($0) }, WorkspaceLocalization.string("代码高亮行必须在源码范围内，最多 200 行且不能重复。"))
        }
        if let highlightSpans = code.highlightSpans { try validateSpans(highlightSpans, source: code.source) }
        if let annotations = code.annotations {
            try require(annotations.count <= 40 && Set(annotations.map(\.line)).count == annotations.count,
                        WorkspaceLocalization.string("代码最多提供 40 条不重复行号的注解。"))
            for annotation in annotations {
                try require((1...lineCount).contains(annotation.line), WorkspaceLocalization.string("代码注解行号超出源码范围。"))
                try bounded(annotation.text, max: 2_000, required: true)
            }
        }
    }

    private struct CodeSpanIdentity: Hashable {
        var line: Int
        var text: [UInt16]
        var occurrence: Int
    }

    private static func validateSpans(_ spans: [CourseCodeSpan], source: String?) throws {
        try require(spans.count <= 200, WorkspaceLocalization.string("代码字符标记最多 200 项。"))
        guard !spans.isEmpty else { return }
        guard let source else { throw WorkspaceFailure.invalid(WorkspaceLocalization.string("代码字符标记需要可显示的程序代码。")) }
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
        var seen = Set<CodeSpanIdentity>()
        for span in spans {
            try require((1...lines.count).contains(span.line), WorkspaceLocalization.string("代码字符标记行号超出源码范围。"))
            try require(span.text.utf16.count <= 2_000 && !span.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        && span.text.unicodeScalars.allSatisfy {
                            !(0...31).contains($0.value) && !(127...159).contains($0.value)
                                && $0.value != 0x2028 && $0.value != 0x2029
                        }, WorkspaceLocalization.string("代码字符标记需为同一行内的非空文字，最多 2000 字符且不能包含控制字符。"))
            let occurrence = span.occurrence ?? 1
            try require((1...20_000).contains(occurrence), WorkspaceLocalization.string("代码字符标记出现次数应为 1 至 20000。"))
            try require(seen.insert(CodeSpanIdentity(line: span.line, text: Array(span.text.utf16), occurrence: occurrence)).inserted,
                        WorkspaceLocalization.string("代码字符标记不能重复。"))
            try require(CourseCodeMarking.matchingRange(in: lines[span.line - 1], span: span) != nil,
                        WorkspaceLocalization.string("代码字符标记必须精确匹配对应行中指定次数的原文。"))
        }
    }

    private static func bounded(_ text: String, max: Int, required: Bool = false) throws {
        try require(text.unicodeScalars.allSatisfy {
            !((0...8).contains($0.value) || $0.value == 11 || $0.value == 12 || (14...31).contains($0.value))
        }, WorkspaceLocalization.string("课程文字不能包含不支持的控制字符。"))
        // Angle brackets are ordinary text: C++ headers and templates must survive unchanged.
        // Only explicit html/svg presentations may execute in the network-isolated web renderer.
        try require(text.utf16.count <= max && (!required || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty),
                    WorkspaceLocalization.string("课程文字为空或超过长度限制。"))
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw WorkspaceFailure.invalid(message) }
    }
}

enum CourseDemo {
    static func edition(now: Date = Date()) -> CourseEdition {
        var first = CourseLesson(id: UUID(uuidString: "8343F80B-F43C-4901-B585-A67647EA9701")!, title: "把一天安排得更从容", blocks: [
            CourseBlock(type: .text, text: "先记录要做的事，再选择真正重要的事。为每项任务保留合理的时间，也给自己留一点空白。"),
            CourseBlock(type: .callout, text: "试一试：选出今天最重要的一件事，为它安排一个不被打扰的时段。"),
            CourseBlock(type: .chart, caption: "示例：一天的时间分配（小时）", chartType: .bar, points: [
                CourseChartPoint(label: "学习", value: 5), CourseChartPoint(label: "运动", value: 1),
                CourseChartPoint(label: "休息", value: 8), CourseChartPoint(label: "其他", value: 10)
            ]),
            CourseBlock(type: .question, text: "哪一种安排更适合开始今天？", questionType: .singleChoice,
                        options: [CourseOption(id: "a", text: "先挑选最重要的任务"), CourseOption(id: "b", text: "把所有时间都排满")],
                        correctOptionIDs: ["a"], explanation: "先确定重点，再为任务留出缓冲。")
        ])
        var second = CourseLesson(id: UUID(uuidString: "8343F80B-F43C-4901-B585-A67647EA9702")!, title: "建立自己的节奏", blocks: [
            CourseBlock(type: .text, text: "复盘的目的，是找到适合自己的节奏。每天记录一点进展，持续比完美更重要。"),
            CourseBlock(type: .chart, caption: "示例：一周的专注时长（分钟）", chartType: .line, points: [
                CourseChartPoint(label: "周一", value: 35), CourseChartPoint(label: "周二", value: 45),
                CourseChartPoint(label: "周三", value: 40), CourseChartPoint(label: "周四", value: 55)
            ]),
            CourseBlock(type: .question, text: "哪些习惯有助于保持节奏？", questionType: .multipleChoice,
                        options: [CourseOption(id: "a", text: "安排休息"), CourseOption(id: "b", text: "定期复盘"), CourseOption(id: "c", text: "永远不允许计划变化")],
                        correctOptionIDs: ["a", "b"], explanation: "留出休息和调整的空间，计划才能持续。"),
            CourseBlock(type: .question, text: "写下一件今天想完成的小事。", questionType: .shortAnswer,
                        explanation: "这道题没有标准答案。写下自己的想法，就迈出了第一步。",
                        input: CourseQuestionInput(kind: .text, placeholder: "例如：读完一章，或整理今天的笔记", minLines: 2, maxLines: 5))
        ])
        let incrementProgram = CourseCodeSample(language: "cpp", source: """
            #include <iostream>

            int main() {
                int count = 0;
                ++count;
                std::cout << count;
            }
            """, filename: "counter.cpp", highlightLines: [5],
            annotations: [CourseLineAnnotation(line: 5, text: "前置递增：先把 count 增加 1。")],
            expectedOutput: "1", highlightSpans: [CourseCodeSpan(line: 5, text: "++")])
        var third = CourseLesson(id: UUID(uuidString: "8343F80B-F43C-4901-B585-A67647EA9703")!, title: "代码与互动演示", blocks: [
            CourseBlock(type: .text, text: "整数变量 count 从 0 开始。执行 ++count 后变成 1，std::cout 会输出 1。", title: "从一行代码开始",
                presentation: CoursePresentation(kind: .markdown, markdown: CourseMarkdownContent(source: """
                ## 让变量增加一次
                `++count` 会把变量的值加上 **1**。先预测输出，再点击下方演示验证。

                ```cpp
                #include <iostream>

                int main() {
                    int count = 0;
                    ++count;
                    std::cout << count; // 输出 1
                }
                ```
                每次执行递增语句，都是在原来的值上再加一。
                """))),
            CourseBlock(type: .text, text: "变量 count 可以看成一个有名称的盒子。初始盒子里是 0，执行 ++count 后，盒子里的值变成 1。", title: "变量如何变化",
                presentation: CoursePresentation(kind: .svg, svg: CourseWebContent(source: """
                <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 360 180" role="img" aria-label="count 从 0 增加到 1">
                  <style>text{font-family:system-ui,sans-serif;fill:#24372f}.box{fill:#e7efe8;stroke:#548467;stroke-width:2}.arrow{stroke:#548467;stroke-width:3;fill:none}</style>
                  <rect class="box" x="15" y="35" width="105" height="105" rx="18"/>
                  <text x="67" y="65" text-anchor="middle" font-size="16">count</text><text x="67" y="114" text-anchor="middle" font-size="42">0</text>
                  <path class="arrow" d="M135 90H220M210 80L220 90L210 100"/>
                  <text x="177" y="66" text-anchor="middle" font-size="16">++count</text>
                  <rect class="box" x="240" y="35" width="105" height="105" rx="18"/>
                  <text x="292" y="65" text-anchor="middle" font-size="16">count</text><text x="292" y="114" text-anchor="middle" font-size="42">1</text>
                </svg>
                """, height: 200))),
            CourseBlock(type: .callout, text: "互动示例从 count = 0 开始。点击执行 ++count，值增加 1；点击重置，值回到 0。开启减少动态后，数字变化不使用缩放动画。", title: "亲手运行一次",
                presentation: CoursePresentation(kind: .html, html: CourseWebContent(source: """
                <!doctype html><html lang="zh-CN"><head><meta name="viewport" content="width=device-width,initial-scale=1"><style>
                :root{color-scheme:light dark}*{box-sizing:border-box}body{margin:0;padding:20px;font:16px system-ui,sans-serif;color:light-dark(#24372f,#e5eee7);background:transparent}
                .demo{display:grid;gap:16px;text-align:center}code{font-family:ui-monospace,monospace}.value{font:600 52px ui-monospace,monospace;transition:transform .16s ease;color:light-dark(#356747,#a5d5b2)}.value.bump{transform:scale(1.08)}
                .actions{display:flex;gap:10px;justify-content:center}button{border:0;border-radius:99px;padding:12px 18px;font:600 15px system-ui;cursor:pointer;color:light-dark(#fff,#183824);background:light-dark(#356747,#a5d5b2)}button.secondary{background:light-dark(#e3ebe5,#2c3e31);color:inherit}label{font-size:13px;display:flex;gap:6px;align-items:center;justify-content:center}body.reduce .value{transition:none}
                @media(prefers-reduced-motion:reduce){.value{transition:none}}
                </style></head><body><section class="demo" aria-label="变量递增演示"><code>int count = <output id="inline">0</output>;</code><output id="value" class="value" aria-live="polite">0</output><div class="actions"><button id="increment">执行 ++count</button><button id="reset" class="secondary">重置</button></div><label><input type="checkbox" id="reduce">减少动态</label></section><script>
                (()=>{let count=0;const value=document.getElementById('value');const inline=document.getElementById('inline');const reduce=document.getElementById('reduce');reduce.checked=matchMedia('(prefers-reduced-motion: reduce)').matches;const setMotion=()=>document.body.classList.toggle('reduce',reduce.checked);setMotion();reduce.addEventListener('change',setMotion);function show(){value.textContent=String(count);inline.textContent=String(count);if(!reduce.checked){value.classList.remove('bump');requestAnimationFrame(()=>{value.classList.add('bump');setTimeout(()=>value.classList.remove('bump'),170)})}}document.getElementById('increment').addEventListener('click',()=>{count=Math.min(count+1,9999);show()});document.getElementById('reset').addEventListener('click',()=>{count=0;show()})})();
                </script></body></html>
                """, height: 280)))
        ], objectives: ["读懂一个完整的 C++ 递增示例。", "用示意图和交互观察变量变化。"], estimatedMinutes: 5,
           referenceCode: incrementProgram)
        third.blocks[0].focusLines = [4, 5]
        third.blocks[0].focusSpans = [CourseCodeSpan(line: 4, text: "count"), CourseCodeSpan(line: 5, text: "++")]
        third.blocks[1].focusLines = [4, 5]
        third.blocks[1].focusSpans = [CourseCodeSpan(line: 4, text: "0"), CourseCodeSpan(line: 5, text: "count")]
        third.blocks[2].focusLines = [5]
        third.blocks[2].focusSpans = [CourseCodeSpan(line: 5, text: "++count")]

        let sumProgram = CourseCodeSample(language: "javascript", source: """
            let total = 0;
            for (let i = 1; i <= 3; i++) {
                total = total + i;
            }
            console.log(total);
            """, filename: "sum.js", highlightLines: [3],
            annotations: [CourseLineAnnotation(line: 3, text: "先读取右边的旧值，再把相加的结果写回左边。")],
            expectedOutput: "6", highlightSpans: [CourseCodeSpan(line: 3, text: "total", occurrence: 2)])
        var fourth = CourseLesson(id: UUID(uuidString: "8343F80B-F43C-4901-B585-A67647EA9704")!, title: "看着程序，逐步推演", blocks: [
            CourseBlock(type: .text, text: "这段程序把 1、2、3 依次加进 total。完整程序会一直保留在上方；蓝色标记会跟随讲解，精确到变量或运算符。", title: "完整程序随时可看",
                presentation: CoursePresentation(kind: .code, code: sumProgram)),
            CourseBlock(type: .text, text: "total = total + i 右侧先计算，左侧后接收。现在只标记右侧第二次出现的 total，它表示累加前的旧值。", title: "同一个变量，两个位置",
                focusLines: [3], focusSpans: [CourseCodeSpan(line: 3, text: "total", occurrence: 2)]),
            CourseBlock(type: .text, text: "点击执行下一步，观察 i、total 与输出如何变化；也可以退回上一帧对照。", title: "一步一步观察",
                presentation: CoursePresentation(kind: .trace, trace: CourseTraceContent(variants: [
                    CourseTraceVariant(id: "sum", title: "累加 1 到 3", code: sumProgram, frames: [
                        CourseTraceFrame(title: "先准备一个总数", line: 1, note: "total 从 0 开始。",
                            objects: [CourseTraceObject(id: "total", names: ["total"], value: "0", scope: "程序", changed: true)],
                            focusSpans: [CourseCodeSpan(line: 1, text: "0")]),
                        CourseTraceFrame(title: "第一次循环", line: 2, note: "i 取 1，满足 i <= 3，可以进入循环体。",
                            objects: [CourseTraceObject(id: "total", names: ["total"], value: "0"), CourseTraceObject(id: "i", names: ["i"], value: "1", changed: true)],
                            focusSpans: [CourseCodeSpan(line: 2, text: "i <= 3")]),
                        CourseTraceFrame(title: "第一次相加", line: 3, note: "右侧算出 0 + 1，再把结果 1 写回 total。",
                            objects: [CourseTraceObject(id: "total", names: ["total"], value: "1", changed: true), CourseTraceObject(id: "i", names: ["i"], value: "1")],
                            focusSpans: [CourseCodeSpan(line: 3, text: "total + i")]),
                        CourseTraceFrame(title: "第二次相加", line: 3, note: "i 增加到 2。这一次，旧的 total 是 1；1 + 2 得到 3。",
                            objects: [CourseTraceObject(id: "total", names: ["total"], value: "3", changed: true), CourseTraceObject(id: "i", names: ["i"], value: "2", changed: true)],
                            focusSpans: [CourseCodeSpan(line: 3, text: "total", occurrence: 2), CourseCodeSpan(line: 3, text: "i")]),
                        CourseTraceFrame(title: "第三次相加", line: 3, note: "i 增加到 3，total 由 3 + 3 变成 6。之后 i 变为 4，循环结束。",
                            objects: [CourseTraceObject(id: "total", names: ["total"], value: "6", changed: true), CourseTraceObject(id: "i", names: ["i"], value: "3", changed: true)],
                            focusSpans: [CourseCodeSpan(line: 3, text: "=")]),
                        CourseTraceFrame(title: "输出最终结果", line: 5, note: "程序输出 total 的最终值 6。",
                            objects: [CourseTraceObject(id: "total", names: ["total"], value: "6")], output: "6",
                            focusSpans: [CourseCodeSpan(line: 5, text: "total")])
                    ])
                ]))),
            CourseBlock(type: .question, text: "回看上方程序：循环结束后，total 的值是多少？只输入一个整数。", questionType: .shortAnswer,
                acceptedAnswers: ["6"], explanation: "0 + 1 + 2 + 3 = 6。输入后点继续，也会先检查这道题。",
                input: CourseQuestionInput(kind: .integer, placeholder: "最终的 total", minLines: 2, maxLines: 3),
                focusLines: [5], focusSpans: [CourseCodeSpan(line: 5, text: "total")])
        ], objectives: ["让完整程序与当前讲解保持对应。", "按变量、表达式和行号观察状态变化。"], estimatedMinutes: 4, referenceCode: sumProgram)

        let doubleStarter = """
            function double(value) {
                return value;
            }
            """
        let doubleProgram = CourseCodeSample(language: "javascript", source: doubleStarter + "\nconst value = Number(readLine());\nconsole.log(double(value));",
            filename: "double.js", highlightLines: [2],
            annotations: [CourseLineAnnotation(line: 2, text: "这里仍返回原数，请在下面的编辑器中改成返回两倍。")],
            stdin: "3", expectedOutput: "6", highlightSpans: [CourseCodeSpan(line: 2, text: "value")])
        var fifth = CourseLesson(id: UUID(uuidString: "8343F80B-F43C-4901-B585-A67647EA9705")!, title: "填数字，写代码，真正运行", blocks: [
            CourseBlock(type: .callout, text: "这里的练习可以直接在本机运行。数字题使用数字键盘，程序题使用代码编辑器。填写答案后，可点运行代码，也可点底部继续提交当前答案。", title: "从输入到结果"),
            CourseBlock(type: .question, text: "补全循环的结束值，使程序依次输出 1、2、3。只填一个整数。", questionType: .shortAnswer,
                acceptedAnswers: ["4"], explanation: "条件是 i < 4，所以循环体会执行 i = 1、2、3。",
                title: "整数填空", hints: ["注意条件中的 < 不包含右侧的数。"],
                input: CourseQuestionInput(kind: .integer, placeholder: "填入结束值", minLines: 2, maxLines: 3),
                execution: CourseExecutionConfiguration(language: "javascript", template: "for (let i = 1; i < {{ANSWER}}; i++) {\n    console.log(i);\n}", expectedOutput: "1\n2\n3"),
                focusLines: [1], focusSpans: [CourseCodeSpan(line: 1, text: "{{ANSWER}}")]),
            CourseBlock(type: .question, text: "一条绳子长 2 米，取它的多少倍恰好是 1 米？填一个小数，让程序输出 1。", questionType: .shortAnswer,
                acceptedAnswers: ["0.5"], explanation: "2 × 0.5 = 1；试着运行，看看实际输出。", title: "小数输入",
                input: CourseQuestionInput(kind: .decimal, placeholder: "例如 0.5", minLines: 2, maxLines: 3),
                execution: CourseExecutionConfiguration(language: "javascript", template: "console.log(2 * ({{ANSWER}}));", expectedOutput: "1"),
                focusLines: [1], focusSpans: [CourseCodeSpan(line: 1, text: "{{ANSWER}}")]),
            CourseBlock(type: .question, text: "修改 double 函数，让它返回参数的两倍。默认程序输入是 3，运行后应输出 6。也可以展开程序输入，换个数再试。", questionType: .shortAnswer,
                explanation: "把 return value 改成 return value * 2，再运行检查结果。", title: "在代码编辑器中完成函数",
                code: doubleProgram,
                hints: ["保留函数名 double 和参数 value。", "return 后写 value * 2。"], answerFormat: .code,
                input: CourseQuestionInput(kind: .code, language: "javascript", placeholder: "补全 double 函数", starterCode: doubleProgram.source, minLines: 5, maxLines: 12),
                execution: CourseExecutionConfiguration(language: "javascript", stdin: "3", expectedOutput: "6"))
        ], objectives: ["体验适配整数、小数与源码的输入方式。", "修改源码和程序输入，检查真实运行结果。"], estimatedMinutes: 5, referenceCode: doubleProgram)

        var sixth = CourseLesson(id: UUID(uuidString: "8343F80B-F43C-4901-B585-A67647EA9706")!, title: "换一种方式，巩固理解", blocks: [
            CourseBlock(type: .text, text: "把变量的变化整理成表格：第一轮后 total 是 1，第二轮是 3，第三轮是 6。", title: "用表格对照每一轮",
                presentation: CoursePresentation(kind: .table, table: CourseTableContent(columns: ["轮次", "i", "total"], rows: [["开始", "—", "0"], ["第一轮", "1", "1"], ["第二轮", "2", "3"], ["第三轮", "3", "6"]]))),
            CourseBlock(type: .text, text: "读循环时，先看起点，再看条件，再算循环体，最后回到更新步骤。", title: "把过程拆成小步",
                presentation: CoursePresentation(kind: .steps, steps: [
                    CourseTeachingItem(title: "确定起点", text: "总数从 0 开始，i 从 1 开始。", code: CourseCodeSample(language: "javascript", source: "let total = 0;\nlet i = 1;")),
                    CourseTeachingItem(title: "判断并累加", text: "i <= 3 时，把本轮的 i 加进 total。", code: CourseCodeSample(language: "javascript", source: "total = total + i;")),
                    CourseTeachingItem(title: "更新后再判断", text: "i 增加 1，重新判断条件；不满足时退出。", code: CourseCodeSample(language: "javascript", source: "i++;"))
                ])),
            CourseBlock(type: .text, text: "i <= 3 会包含 3；i < 3 不包含 3。只差一个等号，循环次数和结果就不同。", title: "对照两种条件",
                presentation: CoursePresentation(kind: .comparison, items: [
                    CourseTeachingItem(title: "包含边界", text: "i 依次取 1、2、3，总和为 6。", code: CourseCodeSample(language: "javascript", source: "for (let i = 1; i <= 3; i++) {\n    total += i;\n}")),
                    CourseTeachingItem(title: "不包含边界", text: "i 只取 1、2，总和为 3。", code: CourseCodeSample(language: "javascript", source: "for (let i = 1; i < 3; i++) {\n    total += i;\n}"))
                ])),
            CourseBlock(type: .text, text: "先想一想，再翻开卡片核对。能够不看解析说出理由，就说明理解更扎实了。", title: "翻开卡片，检查记忆",
                presentation: CoursePresentation(kind: .flashcards, cards: [
                    CourseFlashcardContent(front: "total = total + i 先计算哪一边？", back: "先计算右侧 total + i，再把结果写回左侧 total。"),
                    CourseFlashcardContent(front: "i < 4 包含 4 吗？", back: "不包含。若从 1 开始，每次加 1，循环体里会用到 1、2、3。"),
                    CourseFlashcardContent(front: "怎样确认写的程序真的可用？", back: "运行它，对照输出；再换一组输入，检查结果是否仍符合预期。")
                ]))
        ], objectives: ["用表格、分步和对照复习同一个概念。", "通过翻卡自测，检查理解。"], estimatedMinutes: 3)
        // Keep demo answers attached to the same content across launches.
        for index in first.blocks.indices {
            first.blocks[index].id = UUID(uuidString: String(format: "8343F80B-F43C-4901-B585-A67647EA%04d", 100 + index))!
        }
        for index in second.blocks.indices {
            second.blocks[index].id = UUID(uuidString: String(format: "8343F80B-F43C-4901-B585-A67647EA%04d", 200 + index))!
        }
        for index in third.blocks.indices {
            third.blocks[index].id = UUID(uuidString: String(format: "8343F80B-F43C-4901-B585-A67647EA%04d", 300 + index))!
        }
        for index in fourth.blocks.indices {
            fourth.blocks[index].id = UUID(uuidString: String(format: "8343F80B-F43C-4901-B585-A67647EA%04d", 400 + index))!
        }
        for index in fifth.blocks.indices {
            fifth.blocks[index].id = UUID(uuidString: String(format: "8343F80B-F43C-4901-B585-A67647EA%04d", 500 + index))!
        }
        for index in sixth.blocks.indices {
            sixth.blocks[index].id = UUID(uuidString: String(format: "8343F80B-F43C-4901-B585-A67647EA%04d", 600 + index))!
        }
        return CourseEdition(course: CourseDocument(id: UUID(uuidString: "8343F80B-F43C-4901-B585-A67647EA9700")!,
                                                    title: "从容的一天", summary: "从一天的安排到代码实作：体验图表、Markdown、SVG、HTML 动画、程序推演、精确标记和可运行练习。", lessons: [first, second, third, fourth, fifth, sixth]),
                             revision: 3, updatedAt: now)
    }
}


/// Validates pasted course documents before they are re-encoded for publication.
enum CourseImport {
    static func parse(_ text: String) throws -> CourseDocument {
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.first == "\u{FEFF}" {
            body.removeFirst()
            body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if body.hasPrefix("```") {
            let lines = body.components(separatedBy: .newlines)
            guard lines.count >= 3, ["```", "```json"].contains(lines.first ?? ""), lines.last == "```" else {
                throw WorkspaceFailure.invalid(WorkspaceLocalization.string("请粘贴完整的课程 JSON，或一个 json 代码块。"))
            }
            body = lines.dropFirst().dropLast().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !body.isEmpty else { throw WorkspaceFailure.invalid(WorkspaceLocalization.string("请先粘贴课程内容。")) }
        guard body.utf8.count <= 1_048_576 else { throw WorkspaceFailure.invalid(WorkspaceLocalization.string("单个课程不能超过 1 MiB。")) }
        let data = Data(body.utf8)
        let raw: Any
        do { raw = try JSONSerialization.jsonObject(with: data) }
        catch { throw WorkspaceFailure.invalid(WorkspaceLocalization.string("课程 JSON 格式不正确，请检查括号、引号和逗号。")) }
        try rejectNull(raw)
        let course = try object(raw, required: ["protocol", "id", "title", "summary", "lessons"], optional: ["referenceCode"])
        if let referenceCode = course["referenceCode"] { try codeObject(referenceCode) }
        for lessonValue in try array(course["lessons"]) {
            let lesson = try object(lessonValue, required: ["id", "title", "blocks"], optional: ["objectives", "estimatedMinutes", "referenceCode"])
            if let referenceCode = lesson["referenceCode"] { try codeObject(referenceCode) }
            for blockValue in try array(lesson["blocks"]) {
                guard let block = blockValue as? [String: Any], let type = block["type"] as? String else {
                    throw WorkspaceFailure.invalid(WorkspaceLocalization.string("课程内容块缺少有效的类型。"))
                }
                let required: Set<String>
                let optional: Set<String>
                switch type {
                case "text", "callout": required = ["text"]; optional = ["presentation"]
                case "image": required = ["url"]; optional = ["caption"]
                case "chart": required = ["chartType", "points"]; optional = ["caption"]
                case "question": required = ["text", "questionType"]; optional = ["options", "correctOptionIDs", "acceptedAnswers", "explanation", "code", "hints", "answerFormat", "input", "execution"]
                default: throw WorkspaceFailure.invalid(WorkspaceLocalization.string("课程包含不支持的内容块类型。"))
                }
                _ = try object(block, required: required.union(["id", "type"]), optional: optional.union(["title", "focusLines", "focusSpans"]))
                if let focusSpans = block["focusSpans"] { try spansObject(focusSpans) }
                if let presentation = block["presentation"] { try presentationObject(presentation) }
                if let code = block["code"] { try codeObject(code) }
                if let input = block["input"] {
                    _ = try object(input, required: ["kind"], optional: ["language", "placeholder", "starterCode", "minLines", "maxLines"])
                }
                if let execution = block["execution"] {
                    _ = try object(execution, required: ["language"], optional: ["template", "stdin", "expectedOutput"])
                }
                if type == "chart" {
                    for point in try array(block["points"]) { _ = try object(point, required: ["label", "value"]) }
                }
                if let options = block["options"] {
                    for option in try array(options) { _ = try object(option, required: ["id", "text"]) }
                }
            }
        }
        let document: CourseDocument
        do { document = try WorkspaceCoding.decoder().decode(CourseDocument.self, from: data) }
        catch { throw WorkspaceFailure.invalid(WorkspaceLocalization.string("课程字段的类型或必填内容不正确，请按课程协议生成 JSON。")) }
        try CourseValidation.validate(document)
        return document
    }

    private static func presentationObject(_ value: Any) throws {
        guard let raw = value as? [String: Any], let kind = raw["kind"] as? String else {
            throw WorkspaceFailure.invalid(WorkspaceLocalization.string("结构化展示缺少 kind。"))
        }
        switch kind {
        case "trace":
            let value = try object(raw, required: ["kind", "trace"])
            let trace = try object(value["trace"]!, required: ["variants"])
            for rawVariant in try array(trace["variants"]) {
                let variant = try object(rawVariant, required: ["id", "title", "code", "frames"])
                try codeObject(variant["code"]!)
                for rawFrame in try array(variant["frames"]) {
                    let frame = try object(rawFrame, required: ["title", "line", "note", "objects"], optional: ["output", "focusSpans"])
                    if let focusSpans = frame["focusSpans"] { try spansObject(focusSpans) }
                    for rawObject in try array(frame["objects"]) {
                        _ = try object(rawObject, required: ["id", "names", "value"], optional: ["scope", "changed"])
                    }
                }
            }
        case "code":
            let value = try object(raw, required: ["kind", "code"])
            try codeObject(value["code"]!)
        case "table":
            let value = try object(raw, required: ["kind", "table"])
            _ = try object(value["table"]!, required: ["columns", "rows"])
        case "steps", "comparison":
            let key = kind == "steps" ? "steps" : "items"
            let value = try object(raw, required: ["kind", key])
            for rawItem in try array(value[key]) {
                let item = try object(rawItem, required: ["title", "text"], optional: ["code"])
                if let code = item["code"] { try codeObject(code) }
            }
        case "flashcards":
            let value = try object(raw, required: ["kind", "cards"])
            for card in try array(value["cards"]) { _ = try object(card, required: ["front", "back"]) }
        case "markdown", "html", "svg":
            let value = try object(raw, required: ["kind", kind])
            _ = try object(value[kind]!, required: ["source"], optional: kind == "markdown" ? [] : ["height"])
        default:
            throw WorkspaceFailure.invalid(WorkspaceLocalization.string("不支持此结构化展示类型。"))
        }
    }

    private static func codeObject(_ value: Any) throws {
        let code = try object(value, required: ["language", "source"],
            optional: ["filename", "highlightLines", "annotations", "stdin", "expectedOutput", "highlightSpans"])
        if let highlightSpans = code["highlightSpans"] { try spansObject(highlightSpans) }
        if let annotations = code["annotations"] {
            for annotation in try array(annotations) { _ = try object(annotation, required: ["line", "text"]) }
        }
    }

    private static func spansObject(_ value: Any) throws {
        for span in try array(value) { _ = try object(span, required: ["line", "text"], optional: ["occurrence"]) }
    }

    private static func object(_ value: Any, required: Set<String>, optional: Set<String> = []) throws -> [String: Any] {
        guard let object = value as? [String: Any] else { throw WorkspaceFailure.invalid(WorkspaceLocalization.string("课程中的对象格式不正确。")) }
        let keys = Set(object.keys)
        guard keys.isSubset(of: required.union(optional)) else {
            throw WorkspaceFailure.invalid(WorkspaceLocalization.string("课程包含不支持的字段，或字段用于不匹配的内容块。"))
        }
        guard required.isSubset(of: keys) else { throw WorkspaceFailure.invalid(WorkspaceLocalization.string("课程缺少协议要求的必填字段。")) }
        return object
    }

    private static func array(_ value: Any?) throws -> [Any] {
        guard let array = value as? [Any] else { throw WorkspaceFailure.invalid(WorkspaceLocalization.string("课程中的列表格式不正确。")) }
        return array
    }

    private static func rejectNull(_ value: Any) throws {
        if value is NSNull { throw WorkspaceFailure.invalid(WorkspaceLocalization.string("可选课程字段请直接省略，不要填写 null。")) }
        if let object = value as? [String: Any] {
            for value in object.values { try rejectNull(value) }
        } else if let array = value as? [Any] {
            for value in array { try rejectNull(value) }
        }
    }
}
