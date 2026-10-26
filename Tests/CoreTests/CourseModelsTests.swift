import XCTest
#if SWIFT_PACKAGE
@testable import WorkspaceCore
#endif

final class CourseModelsTests: XCTestCase {
    func testCatalogPersonalStarsDecodeOldCachesAndRoundTripWithoutDuplicates() throws {
        var catalog = try WorkspaceCoding.decoder().decode(CourseCatalog.self, from: Data("{\"courses\":[]}".utf8))
        let first = UUID(), second = UUID()
        XCTAssertNil(catalog.starredCourseIDs)
        XCTAssertFalse(catalog.isStarred(first))
        catalog.setStarred(first, starred: true)
        catalog.setStarred(first, starred: true)
        catalog.setStarred(second, starred: true)
        XCTAssertEqual(Set(catalog.starredCourseIDs ?? []), Set([first, second]))
        XCTAssertEqual(catalog.starredCourseIDs?.count, 2)
        catalog.setStarred(first, starred: false)
        XCTAssertFalse(catalog.isStarred(first)); XCTAssertTrue(catalog.isStarred(second))
        let restored = try WorkspaceCoding.decoder().decode(CourseCatalog.self, from: WorkspaceCoding.encoder().encode(catalog))
        XCTAssertEqual(restored, catalog)
    }

    func testProtocolRoundTripAndDefaultProgress() throws {
        let edition = CourseDemo.edition(now: Date(timeIntervalSince1970: 1_700_000_000))
        try CourseValidation.validate(edition.course)
        let encoded = try JSONEncoder().encode(edition.course)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(object["protocol"] as? String, "WORKSHOP-COURSE/1")
        XCTAssertNil(object["protocolVersion"])
        XCTAssertEqual(try JSONDecoder().decode(CourseDocument.self, from: encoded), edition.course)
        let progressData = Data("{\"courseID\":\"\(edition.course.id.uuidString)\"}".utf8)
        let progress = try JSONDecoder().decode(CourseProgress.self, from: progressData)
        XCTAssertTrue(progress.answers.isEmpty)
        XCTAssertTrue(progress.completedLessonIDs.isEmpty)
    }

    func testDemoIncludesStableSelfContainedRichProgrammingLesson() throws {
        let edition = CourseDemo.edition()
        try CourseValidation.validate(edition.course)
        XCTAssertEqual(edition.revision, 3)
        XCTAssertEqual(edition.course.lessons.map(\.id.uuidString), [
            "8343F80B-F43C-4901-B585-A67647EA9701", "8343F80B-F43C-4901-B585-A67647EA9702", "8343F80B-F43C-4901-B585-A67647EA9703",
            "8343F80B-F43C-4901-B585-A67647EA9704", "8343F80B-F43C-4901-B585-A67647EA9705", "8343F80B-F43C-4901-B585-A67647EA9706"
        ])
        let lesson = edition.course.lessons[2]
        XCTAssertEqual(lesson.title, "代码与互动演示")
        XCTAssertEqual(lesson.blocks.compactMap { $0.presentation?.kind }, [.markdown, .svg, .html])
        XCTAssertEqual(lesson.blocks.map(\.id), CourseDemo.edition().course.lessons[2].blocks.map(\.id))
        XCTAssertTrue(lesson.blocks.allSatisfy { !($0.text?.isEmpty ?? true) && $0.type != .image })
        XCTAssertTrue(try XCTUnwrap(lesson.blocks[0].presentation?.markdown?.source).contains("```cpp"))
        let html = try XCTUnwrap(lesson.blocks[2].presentation?.html?.source)
        XCTAssertTrue(html.contains("++count")); XCTAssertTrue(html.contains("prefers-reduced-motion")); XCTAssertTrue(html.contains("重置"))
        XCTAssertFalse(html.contains("<img")); XCTAssertFalse(html.contains("<video")); XCTAssertFalse(html.contains("https://"))
        XCTAssertEqual(try CourseImport.parse(String(decoding: WorkspaceCoding.encoder().encode(edition.course), as: UTF8.self)), edition.course)
    }

    func testDemoCoversCurrentPresentationAndInputKindsWithoutRemoteExecution() throws {
        let course = CourseDemo.edition().course
        let blocks = course.lessons.flatMap(\.blocks)
        XCTAssertEqual(Set(blocks.compactMap { $0.presentation?.kind.rawValue }),
                       Set(CoursePresentationKind.allCases.map(\.rawValue)))
        let questions = blocks.filter { $0.questionType == .shortAnswer }
        XCTAssertEqual(Set(questions.map { $0.resolvedInput.kind.rawValue }),
                       Set(CourseQuestionInputKind.allCases.map(\.rawValue)))
        let executable = questions.filter { $0.execution != nil }
        XCTAssertFalse(executable.isEmpty)
        XCTAssertTrue(executable.allSatisfy { $0.execution?.language == "javascript" },
                      "Demo exercises must run locally without a signed-in account or server request.")
        for kind in [CourseQuestionInputKind.integer, .decimal, .code] {
            XCTAssertTrue(executable.contains { $0.resolvedInput.kind == kind }, "Missing runnable \(kind.rawValue) demo.")
        }
        XCTAssertTrue(executable.contains { $0.execution?.template == nil }, "Include a complete-program exercise as well as fill-in templates.")
        XCTAssertFalse(blocks.contains { $0.type == .image || $0.url != nil }, "The demo must remain usable offline.")
    }

    func testDemoKeepsStableUniqueContentIDsAndVisibleCodeFocus() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let edition = CourseDemo.edition(now: now)
        XCTAssertEqual(edition, CourseDemo.edition(now: now), "Opening the demo again must not regenerate lesson or block identities.")
        let course = edition.course
        let ids = [course.id] + course.lessons.map(\.id) + course.lessons.flatMap { $0.blocks.map(\.id) }
        XCTAssertEqual(Set(ids).count, ids.count)
        try CourseValidation.validate(course)
        var hasLineFocus = false, hasSpanFocus = false, hasTraceSpan = false
        for lesson in course.lessons {
            let codingBlocks = lesson.blocks.filter { $0.execution != nil || $0.presentation?.kind == .trace }
            if !codingBlocks.isEmpty {
                XCTAssertFalse(try XCTUnwrap(lesson.referenceCode).source.isEmpty,
                               "Coding demonstrations need a full program that remains available while paging.")
            }
            for block in lesson.blocks {
                if !(block.focusLines ?? []).isEmpty { hasLineFocus = true }
                if !(block.focusSpans ?? []).isEmpty { hasSpanFocus = true }
                if block.execution != nil || block.focusLines != nil || block.focusSpans != nil {
                    XCTAssertNotNil(lesson.codeContext(for: block.id, courseReference: course.referenceCode))
                }
                for variant in block.presentation?.trace?.variants ?? [] {
                    for frame in variant.frames {
                        if !(frame.focusSpans ?? []).isEmpty { hasTraceSpan = true }
                    }
                }
            }
        }
        XCTAssertTrue(hasLineFocus, "Include a teaching block that focuses a program line.")
        XCTAssertTrue(hasSpanFocus, "Include a teaching block that focuses a literal code fragment.")
        XCTAssertTrue(hasTraceSpan, "Include a native trace frame that focuses a changing code fragment.")
    }

    func testValidationRejectsDuplicateIDsUnsafeImagesAndInvalidCharts() throws {
        var course = CourseDemo.edition().course
        course.lessons[1].blocks[0].id = course.lessons[0].id
        XCTAssertThrowsError(try CourseValidation.validate(course))
        for url in ["http://example.com/a.png", "https://user:secret@example.com/a.png", "https:///image.png"] {
            course = CourseDemo.edition().course
            course.lessons[0].blocks = [CourseBlock(type: .image, url: url)]
            XCTAssertThrowsError(try CourseValidation.validate(course), url)
        }
        course = CourseDemo.edition().course
        course.lessons[0].blocks = [CourseBlock(type: .chart, chartType: .line,
                                               points: [CourseChartPoint(label: "a", value: .infinity)])]
        XCTAssertThrowsError(try CourseValidation.validate(course))
    }

    func testChoiceAndShortAnswerGrading() throws {
        let options = [CourseOption(id: "a", text: "A"), CourseOption(id: "b", text: "B"), CourseOption(id: "c", text: "C")]
        let question = CourseBlock(type: .question, text: "Choose", questionType: .multipleChoice,
                                   options: options, correctOptionIDs: ["a", "c"])
        XCTAssertEqual(question.evaluate(selectedOptionIDs: ["c", "a"], text: ""), true)
        XCTAssertEqual(question.evaluate(selectedOptionIDs: ["a"], text: ""), false)
        XCTAssertEqual(question.evaluate(selectedOptionIDs: ["a", "b", "c"], text: ""), false)
        let short = CourseBlock(type: .question, text: "Answer", questionType: .shortAnswer,
                                acceptedAnswers: ["Hello World", "你好"])
        XCTAssertEqual(short.evaluate(selectedOptionIDs: [], text: " \nhello\t WORLD  "), true)
        XCTAssertEqual(short.evaluate(selectedOptionIDs: [], text: "other"), false)
        let open = CourseBlock(type: .question, text: "Thoughts", questionType: .shortAnswer)
        XCTAssertNil(open.evaluate(selectedOptionIDs: [], text: "My own answer"))
    }

    func testProgressCompletionGateAndAtomicUpdates() throws {
        let edition = CourseDemo.edition()
        let lesson = edition.course.lessons[0]
        let question = try XCTUnwrap(lesson.blocks.first(where: { $0.type == .question }))
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var progress = CourseProgress(courseID: edition.course.id)
        XCTAssertThrowsError(try progress.apply(update: CourseProgressUpdate(courseRevision: edition.revision, lessonID: lesson.id, completed: true), edition: edition, at: now))
        XCTAssertTrue(progress.completedLessonIDs.isEmpty)
        XCTAssertTrue(progress.answers.isEmpty)
        XCTAssertThrowsError(try progress.apply(update: CourseProgressUpdate(courseRevision: edition.revision, lessonID: lesson.id,
                                                                            blockID: question.id, selectedOptionIDs: ["unknown"], completed: true), edition: edition, at: now))
        XCTAssertTrue(progress.answers.isEmpty)
        // A valid attempt is sufficient for completion; it need not be the correct answer.
        try progress.apply(update: CourseProgressUpdate(courseRevision: edition.revision, lessonID: lesson.id,
                                                         blockID: question.id, selectedOptionIDs: ["b"], completed: true), edition: edition, at: now)
        XCTAssertEqual(progress.completedLessonIDs, [lesson.id])
        XCTAssertEqual(progress.answers.first?.updatedAt, now)
        XCTAssertEqual(progress.answers.first?.selectedOptionIDs, ["b"])
        try progress.apply(update: CourseProgressUpdate(courseRevision: edition.revision, lessonID: lesson.id,
                                                         blockID: question.id, selectedOptionIDs: ["a"]), edition: edition, at: now)
        XCTAssertEqual(progress.answers.count, 1)
        XCTAssertEqual(progress.answers[0].selectedOptionIDs, ["a"])
        let saved = progress
        XCTAssertThrowsError(try progress.apply(update: CourseProgressUpdate(courseRevision: edition.revision + 1, lessonID: lesson.id, completed: false), edition: edition, at: now))
        XCTAssertEqual(progress, saved)
        try progress.apply(update: CourseProgressUpdate(courseRevision: edition.revision, lessonID: lesson.id, completed: false), edition: edition, at: now)
        XCTAssertTrue(progress.completedLessonIDs.isEmpty)
        XCTAssertEqual(progress.answers.count, 1)
    }

    func testShortAnswerRequiredForCompletion() throws {
        let edition = CourseDemo.edition()
        let lesson = edition.course.lessons[1]
        var progress = CourseProgress(courseID: edition.course.id)
        let multi = try XCTUnwrap(lesson.blocks.first(where: { $0.questionType == .multipleChoice }))
        let short = try XCTUnwrap(lesson.blocks.first(where: { $0.questionType == .shortAnswer }))
        let now = Date()
        try progress.apply(update: CourseProgressUpdate(courseRevision: edition.revision, lessonID: lesson.id,
                                                         blockID: multi.id, selectedOptionIDs: ["a", "b"]), edition: edition, at: now)
        let saved = progress
        XCTAssertThrowsError(try progress.apply(update: CourseProgressUpdate(courseRevision: edition.revision, lessonID: lesson.id,
                                                                            blockID: short.id, text: " \n ", completed: true), edition: edition, at: now))
        XCTAssertEqual(progress, saved)
        try progress.apply(update: CourseProgressUpdate(courseRevision: edition.revision, lessonID: lesson.id,
                                                         blockID: short.id, text: "Read a chapter", completed: true), edition: edition, at: now)
        XCTAssertEqual(progress.completedLessonIDs, [lesson.id])
    }
    func testProgressCannotReuseAnswersFromAnotherEdition() throws {
        let original = CourseDemo.edition()
        let lesson = original.course.lessons[0]
        let question = try XCTUnwrap(lesson.blocks.first(where: { $0.type == .question }))
        var progress = CourseProgress(courseID: original.course.id)
        try progress.apply(update: CourseProgressUpdate(courseRevision: original.revision, lessonID: lesson.id,
                                                         blockID: question.id, selectedOptionIDs: ["a"]), edition: original)
        XCTAssertEqual(progress.courseRevision, original.revision)
        let saved = progress
        var revised = original
        revised.revision = original.revision + 1
        XCTAssertThrowsError(try progress.apply(update: CourseProgressUpdate(courseRevision: revised.revision, lessonID: lesson.id,
                                                                            completed: true), edition: revised))
        XCTAssertEqual(progress, saved)
        XCTAssertEqual(try JSONDecoder().decode(CourseProgress.self, from: JSONEncoder().encode(progress)), progress)
    }

    func testCourseImportAcceptsPureJSONAndSingleFence() throws {
        let document = CourseDemo.edition().course
        let json = try XCTUnwrap(String(data: WorkspaceCoding.encoder().encode(document), encoding: .utf8))
        XCTAssertEqual(try CourseImport.parse(json), document)
        XCTAssertEqual(try CourseImport.parse("  \u{FEFF}\n" + json + "\n "), document)
        XCTAssertEqual(try CourseImport.parse("```json\n" + json + "\n```"), document)
        XCTAssertEqual(try CourseImport.parse("```\n" + json + "\n```"), document)
    }

    func testCourseImportRejectsMalformedOversizedAndUnsupportedFields() throws {
        let document = CourseDemo.edition().course
        let json = try XCTUnwrap(String(data: WorkspaceCoding.encoder().encode(document), encoding: .utf8))
        for text in ["{", "Here is your course:\n" + json, "```json\n" + json,
                     "```json\n" + json + "\n```\nextra", String(repeating: "x", count: 1_048_577)] {
            XCTAssertThrowsError(try CourseImport.parse(text))
        }
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        func reject(_ value: [String: Any]) throws {
            let data = try JSONSerialization.data(withJSONObject: value)
            XCTAssertThrowsError(try CourseImport.parse(String(decoding: data, as: UTF8.self)))
        }
        var changed = raw
        changed["accountPassword"] = "must not be echoed"
        try reject(changed)
        changed = raw
        changed.removeValue(forKey: "summary")
        try reject(changed)
        for block: [String: Any] in [
            ["id": UUID().uuidString, "type": "text", "text": "Hello", "url": "https://example.com/a.png"],
            ["id": UUID().uuidString, "type": "image", "url": "https://example.com/a.png", "caption": NSNull()],
            ["id": UUID().uuidString, "type": "image", "url": "https://example.com/a.svg"],
            ["id": UUID().uuidString, "type": "html", "text": "<script>alert(1)</script>"],
            ["id": UUID().uuidString, "type": "chart", "chartType": "line", "points": [["label": "a", "value": 1e16]]],
            ["id": UUID().uuidString, "type": "chart", "chartType": "bar", "points": [["label": "a", "value": 1, "extra": true]]],
            ["id": UUID().uuidString, "type": "video", "url": "https://example.com/a.mp4"]
        ] {
            changed = raw
            changed["lessons"] = [["id": UUID().uuidString, "title": "Lesson", "blocks": [block]]]
            try reject(changed)
        }
    }

    func testCourseImportRejectsCourseIDReusedByLessonOrBlock() throws {
        var course = CourseDemo.edition().course
        course.lessons[0].id = course.id
        var data = try WorkspaceCoding.encoder().encode(course)
        XCTAssertThrowsError(try CourseImport.parse(String(decoding: data, as: UTF8.self)))
        course = CourseDemo.edition().course
        course.lessons[0].blocks[0].id = course.id
        data = try WorkspaceCoding.encoder().encode(course)
        XCTAssertThrowsError(try CourseImport.parse(String(decoding: data, as: UTF8.self)))
    }

    func testQuickStartBeginsAtFirstLessonAndAdvancesPastCompletedLessons() {
        let edition = CourseDemo.edition()
        XCTAssertEqual(CourseLearningContinuation.nextLesson(in: edition, progress: nil)?.id, edition.course.lessons[0].id)
        var progress = CourseProgress(courseID: edition.course.id, courseRevision: edition.revision)
        progress.completedLessonIDs = [edition.course.lessons[0].id]
        XCTAssertEqual(CourseLearningContinuation.nextLesson(in: edition, progress: progress)?.id, edition.course.lessons[1].id)
        progress.completedLessonIDs = edition.course.lessons.map(\.id)
        XCTAssertNil(CourseLearningContinuation.nextLesson(in: edition, progress: progress))
    }

    func testQuickStartResumesMostRecentlyAttemptedUnfinishedLesson() throws {
        let edition = CourseDemo.edition()
        let first = edition.course.lessons[0]
        let second = edition.course.lessons[1]
        let firstQuestion = try XCTUnwrap(first.blocks.first { $0.type == .question })
        let secondQuestion = try XCTUnwrap(second.blocks.first { $0.type == .question })
        var progress = CourseProgress(courseID: edition.course.id, courseRevision: edition.revision, answers: [
            CourseAnswer(lessonID: first.id, blockID: firstQuestion.id, updatedAt: Date(timeIntervalSince1970: 100)),
            CourseAnswer(lessonID: second.id, blockID: secondQuestion.id, updatedAt: Date(timeIntervalSince1970: 200)),
            CourseAnswer(lessonID: first.id, blockID: UUID(), updatedAt: Date(timeIntervalSince1970: 300))
        ])
        XCTAssertEqual(CourseLearningContinuation.nextLesson(in: edition, progress: progress)?.id, second.id)
        progress.completedLessonIDs = [second.id]
        XCTAssertEqual(CourseLearningContinuation.nextLesson(in: edition, progress: progress)?.id, first.id)
    }

    func testQuickStartIgnoresProgressForOldEditionsAndOtherCourses() {
        let edition = CourseDemo.edition()
        var progress = CourseProgress(courseID: edition.course.id, courseRevision: edition.revision - 1,
            completedLessonIDs: edition.course.lessons.map(\.id))
        XCTAssertEqual(CourseLearningContinuation.nextLesson(in: edition, progress: progress)?.id, edition.course.lessons[0].id)
        progress.courseRevision = edition.revision
        progress.courseID = UUID()
        XCTAssertEqual(CourseLearningContinuation.nextLesson(in: edition, progress: progress)?.id, edition.course.lessons[0].id)
    }

    func testQuickStartPrioritizesRecentUnfinishedCoursesAndKeepsCatalogOrderForNewCourses() {
        let now = Date(timeIntervalSince1970: 1_000)
        let courses = (0..<5).map { index in
            CourseSummary(id: UUID(), title: "Course \(index)", summary: "", revision: 2, updatedAt: now, lessonCount: 2)
        }
        let progress = [
            courses[0].id: CourseProgress(courseID: courses[0].id, courseRevision: 2,
                completedLessonIDs: [UUID(), UUID()],
                answers: [CourseAnswer(lessonID: UUID(), blockID: UUID(), updatedAt: now)]),
            courses[2].id: CourseProgress(courseID: courses[2].id, courseRevision: 2,
                answers: [CourseAnswer(lessonID: UUID(), blockID: UUID(), updatedAt: now.addingTimeInterval(-20))]),
            courses[3].id: CourseProgress(courseID: courses[3].id, courseRevision: 2,
                answers: [CourseAnswer(lessonID: UUID(), blockID: UUID(), updatedAt: now.addingTimeInterval(-10))]),
            courses[4].id: CourseProgress(courseID: courses[4].id, courseRevision: 1,
                completedLessonIDs: [UUID(), UUID()],
                answers: [CourseAnswer(lessonID: UUID(), blockID: UUID(), updatedAt: now)])
        ]
        XCTAssertEqual(CourseLearningContinuation.orderedCourses(courses, progress: progress).map(\.id),
            [courses[3], courses[2], courses[1], courses[4], courses[0]].map(\.id))
        XCTAssertTrue(CourseLearningContinuation.orderedCourses([], progress: progress).isEmpty)
    }

    private func programmingCourse() -> CourseDocument {
        let code = CourseCodeSample(language: "cpp", source: "#include <iostream>\nint value = 7;\nstd::cout << value;",
            filename: "main.cpp", highlightLines: [1, 3], annotations: [CourseLineAnnotation(line: 3, text: "输出 value 的值。")],
            stdin: "", expectedOutput: "7")
        let item = CourseTeachingItem(title: "观察调用", text: "函数指针保存函数的地址。", code: code)
        let blocks = [
            CourseBlock(type: .text, text: code.source, title: "完整示例", presentation: CoursePresentation(kind: .code, code: code)),
            CourseBlock(type: .text, text: "value 的值为 7。", presentation: CoursePresentation(kind: .table,
                table: CourseTableContent(columns: ["变量", "值"], rows: [["value", "7"]]))),
            CourseBlock(type: .callout, text: item.text, presentation: CoursePresentation(kind: .steps, steps: [item])),
            CourseBlock(type: .text, text: "比较直接调用与间接调用。", presentation: CoursePresentation(kind: .comparison, items: [item, item])),
            CourseBlock(type: .text, text: "函数指针保存函数地址。", presentation: CoursePresentation(kind: .flashcards,
                cards: [CourseFlashcardContent(front: "函数指针保存什么？", back: "函数地址。") ])),
            CourseBlock(type: .text, text: "调用会输出 7。", presentation: CoursePresentation(kind: .markdown,
                markdown: CourseMarkdownContent(source: "## 跟踪输出\n```cpp\nstd::cout << 7;\n```"))),
            CourseBlock(type: .text, text: "点击运行会显示 7。", presentation: CoursePresentation(kind: .html,
                html: CourseWebContent(source: "<button onclick=\"this.textContent='7'\">运行</button>", height: 120))),
            CourseBlock(type: .callout, text: "圆形表示函数入口。", presentation: CoursePresentation(kind: .svg,
                svg: CourseWebContent(source: "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 100 100\"><circle cx=\"50\" cy=\"50\" r=\"20\"/></svg>"))),
            CourseBlock(type: .text, text: "value 从 7 变为 8。", presentation: CoursePresentation(kind: .trace,
                trace: CourseTraceContent(variants: [CourseTraceVariant(id: "value", title: "值传递", code: code, frames: [
                    CourseTraceFrame(title: "调用之前", line: 2, note: "value 为 7。", objects: [CourseTraceObject(id: "value", names: ["value"], value: "7")]),
                    CourseTraceFrame(title: "调用之后", line: 3, note: "value 为 8。", objects: [CourseTraceObject(id: "value", names: ["value"], value: "8", scope: "main", changed: true)], output: "8")
                ])]))),
            CourseBlock(type: .question, text: "预测这段代码的输出。", questionType: .shortAnswer,
                acceptedAnswers: ["7"], explanation: "value 为 7。", code: code, hints: ["先跟踪 value。"], answerFormat: .output)
        ]
        return CourseDocument(title: "C++ 函数指针", lessons: [CourseLesson(title: "从值到调用", blocks: blocks,
            objectives: ["看懂函数指针的声明。"], estimatedMinutes: 15)])
    }

    func testStructuredCourseRoundTripPreservesEveryPresentationAndQuestionContext() throws {
        let course = programmingCourse()
        try CourseValidation.validate(course)
        let data = try WorkspaceCoding.encoder().encode(course)
        let imported = try CourseImport.parse(String(decoding: data, as: UTF8.self))
        XCTAssertEqual(imported, course)
        XCTAssertEqual(Set(imported.lessons[0].blocks.compactMap { $0.presentation?.kind }), Set(CoursePresentationKind.allCases))
        XCTAssertEqual(imported.lessons[0].blocks.last?.code?.source, "#include <iostream>\nint value = 7;\nstd::cout << value;")
    }

    func testCourseImportPreservesAngleBracketsInCppAndOtherLiteralSource() throws {
        var course = CourseDemo.edition().course
        let source = "#include <iostream>\n#include <map>\nstd::vector<std::pair<int, int>> values;\nif (a < b && b > 0) {}\n<script>example only</script>"
        course.lessons[0].blocks = [CourseBlock(type: .text, text: source)]
        let data = try WorkspaceCoding.encoder().encode(course)
        XCTAssertEqual(try CourseImport.parse(String(decoding: data, as: UTF8.self)).lessons[0].blocks[0].text, source)
        course.lessons[0].blocks[0].text = "source\u{0000}"
        XCTAssertThrowsError(try CourseValidation.validate(course))
    }

    func testStructuredCourseRejectsInvalidLineReferencesShapesAndPlacement() throws {
        var course = programmingCourse()
        course.lessons[0].blocks[0].presentation?.code?.highlightLines = [4]
        XCTAssertThrowsError(try CourseValidation.validate(course))
        course = programmingCourse()
        course.lessons[0].blocks[0].presentation?.code?.annotations = [CourseLineAnnotation(line: 0, text: "无效")]
        XCTAssertThrowsError(try CourseValidation.validate(course))
        course = programmingCourse()
        course.lessons[0].blocks[0].presentation?.code?.source = "a\r\nb\r\nc"
        XCTAssertNoThrow(try CourseValidation.validate(course))
        course.lessons[0].blocks[0].presentation?.code?.highlightLines = [1, 1]
        XCTAssertThrowsError(try CourseValidation.validate(course))
        course = programmingCourse()
        course.lessons[0].blocks[0].presentation?.table = CourseTableContent(columns: ["x"], rows: [["1"]])
        XCTAssertThrowsError(try CourseValidation.validate(course))
        course = programmingCourse()
        course.lessons[0].blocks[1].presentation?.table?.rows = [["value"]]
        XCTAssertThrowsError(try CourseValidation.validate(course))
        course = programmingCourse()
        course.lessons[0].blocks[0].type = .image
        XCTAssertThrowsError(try CourseValidation.validate(course))
        course = programmingCourse()
        course.lessons[0].blocks[0].code = CourseCodeSample(language: "cpp", source: "int n;")
        XCTAssertThrowsError(try CourseValidation.validate(course))
        course = programmingCourse()
        course.lessons[0].estimatedMinutes = 0
        XCTAssertThrowsError(try CourseValidation.validate(course))
    }

    func testStructuredCourseImportRejectsUnknownNestedFieldsAndNulls() throws {
        let data = try WorkspaceCoding.encoder().encode(programmingCourse())
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        func reject(_ presentation: [String: Any]) throws {
            var course = raw
            var lessons = try XCTUnwrap(course["lessons"] as? [[String: Any]])
            var blocks = try XCTUnwrap(lessons[0]["blocks"] as? [[String: Any]])
            blocks[0]["presentation"] = presentation
            lessons[0]["blocks"] = blocks; course["lessons"] = lessons
            let modified = try JSONSerialization.data(withJSONObject: course)
            XCTAssertThrowsError(try CourseImport.parse(String(decoding: modified, as: UTF8.self)))
        }
        try reject(["kind": "code", "code": ["language": "cpp", "source": "int x;", "execute": true]])
        try reject(["kind": "code", "code": ["language": "cpp", "source": "int x;", "annotations": [["line": 1, "text": "x", "url": "https://example.test"]]]])
        try reject(["kind": "steps", "steps": [["title": "第一步", "text": "观察", "script": "ignored"]]])
        try reject(["kind": "table", "table": ["columns": ["x"], "rows": [["1"]], "html": "<table>"]])
        try reject(["kind": "flashcards", "cards": [["front": "问题", "back": "答案", "extra": true]]])
        try reject(["kind": "code", "code": NSNull()])
    }

    func testRichPresentationsPreserveSourceAndRequireFallback() throws {
        let course = programmingCourse()
        let imported = try CourseImport.parse(String(decoding: WorkspaceCoding.encoder().encode(course), as: UTF8.self))
        XCTAssertEqual(imported, course)
        XCTAssertEqual(imported.lessons[0].blocks.first { $0.presentation?.kind == .html }?.presentation?.html?.height, 120)
        XCTAssertNil(imported.lessons[0].blocks.first { $0.presentation?.kind == .svg }?.presentation?.svg?.height)
        for kind in [CoursePresentationKind.markdown, .html, .svg] {
            var changed = course
            let index = try XCTUnwrap(changed.lessons[0].blocks.firstIndex { $0.presentation?.kind == kind })
            changed.lessons[0].blocks[index].text = nil
            XCTAssertThrowsError(try CourseValidation.validate(changed), "Legacy clients need complete fallback text.")
            changed.lessons[0].blocks[index].text = " "
            XCTAssertThrowsError(try CourseValidation.validate(changed))
        }
    }

    func testRichPresentationSourceBoundsAndHeightUseProtocolLimits() throws {
        func document(_ value: CoursePresentation) -> CourseDocument {
            CourseDocument(title: "Rich", lessons: [CourseLesson(title: "Lesson", blocks: [
                CourseBlock(type: .text, text: "完整备用说明。", presentation: value)
            ])])
        }
        for kind in [CoursePresentationKind.markdown, .html, .svg] {
            let limit = kind == .markdown ? 20_000 : 60_000
            let source = String(repeating: "😀", count: limit / 2)
            var value = CoursePresentation(kind: kind)
            switch kind {
            case .markdown: value.markdown = CourseMarkdownContent(source: source)
            case .html: value.html = CourseWebContent(source: source, height: 640)
            case .svg: value.svg = CourseWebContent(source: source, height: 120)
            default: XCTFail("Unexpected kind")
            }
            XCTAssertNoThrow(try CourseValidation.validate(document(value)))
            XCTAssertNoThrow(try CourseImport.parse(String(decoding: WorkspaceCoding.encoder().encode(document(value)), as: UTF8.self)))
            for invalidSource in [source + "x", " ", "<p>\u{0000}</p>"] {
                var changed = value
                switch kind {
                case .markdown: changed.markdown?.source = invalidSource
                case .html: changed.html?.source = invalidSource
                case .svg: changed.svg?.source = invalidSource
                default: break
                }
                XCTAssertThrowsError(try CourseValidation.validate(document(changed)))
                XCTAssertThrowsError(try CourseImport.parse(String(decoding: WorkspaceCoding.encoder().encode(document(changed)), as: UTF8.self)))
            }
            if kind != .markdown {
                for height in [119, 641] {
                    var changed = value
                    if kind == .html { changed.html?.height = height } else { changed.svg?.height = height }
                    XCTAssertThrowsError(try CourseValidation.validate(document(changed)))
                }
            }
        }
    }

    func testRichPresentationImportRejectsUnknownNullAndMismatchedPayloads() throws {
        let data = try WorkspaceCoding.encoder().encode(programmingCourse())
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        func reject(_ presentation: [String: Any]) throws {
            var course = raw
            var lessons = try XCTUnwrap(course["lessons"] as? [[String: Any]])
            var blocks = try XCTUnwrap(lessons[0]["blocks"] as? [[String: Any]])
            blocks[0]["presentation"] = presentation
            lessons[0]["blocks"] = blocks; course["lessons"] = lessons
            let modified = try JSONSerialization.data(withJSONObject: course)
            XCTAssertThrowsError(try CourseImport.parse(String(decoding: modified, as: UTF8.self)))
        }
        for kind in ["markdown", "html", "svg"] {
            try reject(["kind": kind, kind: NSNull()])
            try reject(["kind": kind, kind: ["source": NSNull()]])
            try reject(["kind": kind, kind: ["source": "source", "externalURL": "https://example.test"]])
            try reject(["kind": kind, kind: ["height": 200]])
            try reject(["kind": kind, kind: ["source": "source"], "code": ["language": "text", "source": "other"]])
        }
        try reject(["kind": "markdown", "markdown": ["source": "# Markdown", "height": 200]])
        try reject(["kind": "html", "svg": ["source": "<svg/>"]])
        for height: Any in [NSNull(), "200", true, 200.5, 119, 641] {
            try reject(["kind": "html", "html": ["source": "<p>Content</p>", "height": height]])
            try reject(["kind": "svg", "svg": ["source": "<svg/>", "height": height]])
        }
        var course = programmingCourse()
        course.lessons[0].blocks[0].presentation = CoursePresentation(kind: .html, svg: CourseWebContent(source: "<svg/>"))
        XCTAssertThrowsError(try CourseValidation.validate(course))
        course.lessons[0].blocks[0].presentation = CoursePresentation(kind: .markdown,
            markdown: CourseMarkdownContent(source: "text"), html: CourseWebContent(source: "<p>text</p>"))
        XCTAssertThrowsError(try CourseValidation.validate(course))
    }

    func testProgrammingAnswersPreserveCaseAndInternalWhitespace() {
        var question = CourseBlock(type: .question, text: "填写调用", questionType: .shortAnswer,
            acceptedAnswers: ["Call(\"A B\");\nreturn 0;"], answerFormat: .code)
        XCTAssertEqual(question.evaluate(selectedOptionIDs: [], text: "\nCall(\"A B\");\r\nreturn 0;\n"), true)
        XCTAssertEqual(question.evaluate(selectedOptionIDs: [], text: "call(\"A B\");\nreturn 0;"), false)
        XCTAssertEqual(question.evaluate(selectedOptionIDs: [], text: "Call(\"A  B\");\nreturn 0;"), false)
        question.answerFormat = .output; question.acceptedAnswers = ["Hello\nC++"]
        XCTAssertEqual(question.evaluate(selectedOptionIDs: [], text: "Hello\r\nC++\n"), true)
        XCTAssertEqual(question.evaluate(selectedOptionIDs: [], text: "hello\nC++"), false)
        question.acceptedAnswers = []
        XCTAssertNil(question.evaluate(selectedOptionIDs: [], text: "any output"))
    }

    func testTypedQuestionInputsRoundTripAndInferLegacyEditors() throws {
        var question = CourseBlock(type: .question, text: "编写程序", questionType: .shortAnswer,
            code: CourseCodeSample(language: "c++", source: "int main() {}"), answerFormat: .code)
        XCTAssertEqual(question.resolvedInput.kind, .code)
        XCTAssertEqual(question.resolvedInput.language, "cpp")
        question.answerFormat = .output
        XCTAssertEqual(question.resolvedInput.kind, .text, "A code example alone must not turn an output question into a code editor.")
        question.code?.language = "unrecognized-language"
        question.answerFormat = .code
        XCTAssertEqual(question.resolvedInput.language, "plaintext")
        question.input = CourseQuestionInput(kind: .code, language: "javascript", placeholder: "写出函数",
            starterCode: "function twice(value) {\n  return value;\n}", minLines: 4, maxLines: 12)
        question.execution = CourseExecutionConfiguration(language: "javascript", template: "{{ANSWER}}\nconsole.log(twice(3));",
            stdin: "", expectedOutput: "6")
        var course = programmingCourse()
        course.lessons[0].blocks = [question]
        let encoded = try WorkspaceCoding.encoder().encode(course)
        XCTAssertEqual(try CourseImport.parse(String(decoding: encoded, as: UTF8.self)), course)
        XCTAssertEqual(question.resolvedInput, question.input)
        question.input = nil
        question.answerFormat = nil
        XCTAssertEqual(question.resolvedInput.kind, .code)
        XCTAssertEqual(question.resolvedInput.language, "javascript", "Execution language takes precedence over a legacy display language.")
    }

    func testNumericQuestionAnswersRejectNonNumericContent() throws {
        var question = CourseBlock(type: .question, text: "填写数字", questionType: .shortAnswer,
            input: CourseQuestionInput(kind: .integer))
        for value in ["0", "-12", "+42", " 8\n"] {
            XCTAssertNoThrow(try CourseValidation.validateAnswer(block: question, selected: [], text: value))
        }
        for value in ["", "1.5", "2e3", "NaN", "12分钟", "1 + 2", "1\n2", "１２"] {
            XCTAssertThrowsError(try CourseValidation.validateAnswer(block: question, selected: [], text: value), value)
        }
        question.input?.kind = .decimal
        for value in ["0", "-3.5", "+.5", "2.", " 1.25 "] {
            XCTAssertNoThrow(try CourseValidation.validateAnswer(block: question, selected: [], text: value))
        }
        for value in [".", "+", "1,5", "2e3", "Infinity", "1.2.3"] {
            XCTAssertThrowsError(try CourseValidation.validateAnswer(block: question, selected: [], text: value), value)
        }
        var course = programmingCourse()
        question.acceptedAnswers = ["not a number"]
        course.lessons[0].blocks = [question]
        XCTAssertThrowsError(try CourseValidation.validate(course), "Authors must provide numeric reference answers for a numeric input.")
    }

    func testQuestionInputAndExecutionBoundsAndTemplateSemantics() throws {
        var question = CourseBlock(type: .question, text: "运行填空", questionType: .shortAnswer,
            input: CourseQuestionInput(kind: .integer, minLines: 2, maxLines: 2),
            execution: CourseExecutionConfiguration(language: "javascript", template: "console.log({{ANSWER}});",
                stdin: String(repeating: "a", count: 4_000), expectedOutput: String(repeating: "b", count: 8_000)))
        func document(_ block: CourseBlock) -> CourseDocument {
            var course = programmingCourse(); course.lessons[0].blocks = [block]; return course
        }
        XCTAssertNoThrow(try CourseValidation.validate(document(question)))
        let changes: [(inout CourseBlock) -> Void] = [
            { $0.input?.minLines = 1 },
            { $0.input?.maxLines = 25 },
            { $0.input?.minLines = 4; $0.input?.maxLines = 3 },
            { $0.input?.language = "javascript" },
            { $0.input?.starterCode = "0" },
            { $0.input?.placeholder = String(repeating: "x", count: 501) },
            { $0.execution?.language = "shell" },
            { $0.execution?.template = nil },
            { $0.execution?.template = "console.log(0);" },
            { $0.execution?.template = "{{ANSWER}} + {{ANSWER}}" },
            { $0.execution?.template = String(repeating: "x", count: 20_000) + "{{ANSWER}}" },
            { $0.execution?.stdin = String(repeating: "x", count: 4_001) },
            { $0.execution?.expectedOutput = String(repeating: "x", count: 8_001) },
            { $0.type = .text },
            { $0.questionType = .singleChoice }
        ]
        for change in changes {
            var changed = question; change(&changed)
            XCTAssertThrowsError(try CourseValidation.validate(document(changed)))
        }
        question.input = CourseQuestionInput(kind: .code, language: "python", starterCode: "", minLines: 24, maxLines: 24)
        question.execution = CourseExecutionConfiguration(language: "python")
        XCTAssertNoThrow(try CourseValidation.validate(document(question)), "Complete code does not need a template.")
        question.execution?.language = "cpp"
        XCTAssertThrowsError(try CourseValidation.validate(document(question)))
        question.execution = nil
        question.input?.language = "ruby"
        XCTAssertThrowsError(try CourseValidation.validate(document(question)))
    }

    func testCodeInputHasCodeLimitsAndLiteralEvaluationWithoutLegacyAnswerFormat() throws {
        let source = String(repeating: "x", count: 20_000)
        var question = CourseBlock(type: .question, text: "写代码", questionType: .shortAnswer,
            acceptedAnswers: [source], input: CourseQuestionInput(kind: .code, language: "cpp", starterCode: source))
        var course = programmingCourse(); course.lessons[0].blocks = [question]
        XCTAssertNoThrow(try CourseValidation.validate(course))
        XCTAssertNoThrow(try CourseValidation.validateAnswer(block: question, selected: [], text: source))
        XCTAssertThrowsError(try CourseValidation.validateAnswer(block: question, selected: [], text: source + "x"))
        question.acceptedAnswers = ["Call(\"A  B\");"]
        XCTAssertEqual(question.evaluate(selectedOptionIDs: [], text: "Call(\"A  B\");\n"), true)
        XCTAssertEqual(question.evaluate(selectedOptionIDs: [], text: "call(\"A  B\");"), false)
        XCTAssertEqual(question.evaluate(selectedOptionIDs: [], text: "Call(\"A B\");"), false)
    }

    func testManualImportRejectsUnknownAndWrongTypedQuestionConfiguration() throws {
        var course = programmingCourse()
        course.lessons[0].blocks = [CourseBlock(type: .question, text: "写出答案", questionType: .shortAnswer)]
        let data = try WorkspaceCoding.encoder().encode(course)
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        func reject(_ key: String, value: Any) throws {
            var modified = raw
            var lessons = try XCTUnwrap(modified["lessons"] as? [[String: Any]])
            var blocks = try XCTUnwrap(lessons[0]["blocks"] as? [[String: Any]])
            blocks[0][key] = value; lessons[0]["blocks"] = blocks; modified["lessons"] = lessons
            let json = try JSONSerialization.data(withJSONObject: modified)
            XCTAssertThrowsError(try CourseImport.parse(String(decoding: json, as: UTF8.self)))
        }
        for input: Any in [NSNull(), ["kind":"unknown"], ["kind":"text","url":"https://example.test"],
                           ["kind":"code","minLines":true], ["kind":"code","maxLines":2.5],
                           ["kind":"text","language":"cpp"], ["kind":"code","starterCode":NSNull()]] {
            try reject("input", value: input)
        }
        for execution: Any in [NSNull(), [:], ["language":"javascript","url":"https://example.test"],
                               ["language":"cpp","template":4], ["language":"python","stdin":NSNull()]] {
            try reject("execution", value: execution)
        }
    }

    func testProgrammingAnswerLimitsAndExistingCompletionSemantics() throws {
        let code = String(repeating: "x", count: 20_000)
        let question = CourseBlock(type: .question, text: "填写代码", questionType: .shortAnswer,
            acceptedAnswers: [code], answerFormat: .code)
        var edition = CourseDemo.edition()
        edition.course.lessons[0].blocks = [question]
        try CourseValidation.validate(edition.course)
        XCTAssertNoThrow(try CourseValidation.validateAnswer(block: question, selected: [], text: code))
        XCTAssertThrowsError(try CourseValidation.validateAnswer(block: question, selected: [], text: code + "x"))
        var normal = question; normal.answerFormat = nil
        XCTAssertThrowsError(try CourseValidation.validateAnswer(block: normal, selected: [], text: String(repeating: "x", count: 4_001)))
        normal.answerFormat = .output
        XCTAssertThrowsError(try CourseValidation.validateAnswer(block: normal, selected: [], text: String(repeating: "x", count: 8_001)))
        var progress = CourseProgress(courseID: edition.course.id)
        try progress.apply(update: CourseProgressUpdate(courseRevision: edition.revision, lessonID: edition.course.lessons[0].id,
            blockID: question.id, text: "int answer = 0;", completed: true), edition: edition, at: Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(progress.completedLessonIDs, [edition.course.lessons[0].id], "Valid attempts need not match the answer key.")
        XCTAssertEqual(try WorkspaceCoding.decoder().decode(CourseProgress.self, from: WorkspaceCoding.encoder().encode(progress)), progress)
    }

    func testProgrammingFixtureIsValidAndRetainsCppAfterNativeImport() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let json = try String(contentsOf: root.appendingPathComponent("Server/Fixtures/course-programming.json"), encoding: .utf8)
        let course = try CourseImport.parse(json)
        XCTAssertTrue(course.lessons.flatMap(\.blocks).contains { $0.presentation?.code?.source.contains("#include <iostream>") == true || $0.code?.source.contains("#include <iostream>") == true })
        XCTAssertEqual(try CourseImport.parse(String(decoding: WorkspaceCoding.encoder().encode(course), as: UTF8.self)), course)
    }

    private func traceCourse() -> CourseDocument {
        var course = programmingCourse()
        course.lessons[0].blocks = course.lessons[0].blocks.filter { $0.presentation?.kind == .trace }
        return course
    }

    func testTraceBoundsIDsAndLineReferencesAreValidated() throws {
        let original = traceCourse()
        try CourseValidation.validate(original)
        let changes: [(inout CourseTraceContent) -> Void] = [
            { $0.variants = [] },
            { $0.variants = Array(repeating: $0.variants[0], count: 5) },
            { $0.variants.append($0.variants[0]) },
            { $0.variants[0].id = "含中文" },
            { $0.variants[0].id = "value\n" },
            { $0.variants[0].frames = [$0.variants[0].frames[0]] },
            { $0.variants[0].frames[0].line = 0 },
            { $0.variants[0].frames[0].line = 4 },
            { $0.variants[0].frames[0].note = String(repeating: "😀", count: 201) },
            { $0.variants[0].frames[0].objects = [] },
            { $0.variants[0].frames[0].objects.append($0.variants[0].frames[0].objects[0]) },
            { $0.variants[0].frames[0].objects[0].names = [] },
            { $0.variants[0].frames[0].objects[0].value = " " },
            { $0.variants[0].frames[0].objects[0].scope = "" },
            { $0.variants[0].frames[0].output = String(repeating: "x", count: 2001) }
        ]
        for change in changes {
            var course = original
            change(&course.lessons[0].blocks[0].presentation!.trace!)
            XCTAssertThrowsError(try CourseValidation.validate(course))
        }
        var crlf = original
        crlf.lessons[0].blocks[0].presentation?.trace?.variants[0].code.source = "a\r\nb\rc"
        XCTAssertNoThrow(try CourseValidation.validate(crlf))
        crlf.lessons[0].blocks[0].presentation?.trace?.variants[0].frames[0].output = ""
        XCTAssertNoThrow(try CourseValidation.validate(crlf))
    }

    func testTraceImportRejectsUnknownFieldsAtEveryDepthAndMixedPayloads() throws {
        let original = traceCourse()
        let data = try WorkspaceCoding.encoder().encode(original)
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        func reject(_ change: (inout [String: Any]) -> Void) throws {
            var course = raw
            var lessons = course["lessons"] as! [[String: Any]]
            var blocks = lessons[0]["blocks"] as! [[String: Any]]
            var presentation = blocks[0]["presentation"] as! [String: Any]
            change(&presentation)
            blocks[0]["presentation"] = presentation; lessons[0]["blocks"] = blocks; course["lessons"] = lessons
            let bad = try JSONSerialization.data(withJSONObject: course)
            XCTAssertThrowsError(try CourseImport.parse(String(decoding: bad, as: UTF8.self)))
        }
        try reject { $0["html"] = ["source": "<p>mixed</p>"] }
        try reject { $0["trace"] = ["variants": [], "unknown": true] }
        for level in ["variant", "frame", "object"] {
            try reject { presentation in
                var trace = presentation["trace"] as! [String: Any]
                var variants = trace["variants"] as! [[String: Any]]
                var frames = variants[0]["frames"] as! [[String: Any]]
                if level == "variant" { variants[0]["unknown"] = true }
                if level == "frame" { frames[0]["unknown"] = true; variants[0]["frames"] = frames }
                if level == "object" {
                    var objects = frames[0]["objects"] as! [[String: Any]]
                    objects[0]["unknown"] = true; frames[0]["objects"] = objects; variants[0]["frames"] = frames
                }
                trace["variants"] = variants; presentation["trace"] = trace
            }
        }
        XCTAssertEqual(try CourseImport.parse(String(decoding: data, as: UTF8.self)), original)
    }

    func testCodeContextOptionalFieldsRoundTripWithoutChangingLegacyDocuments() throws {
        let original = programmingCourse()
        let data = try WorkspaceCoding.encoder().encode(original)
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(raw["referenceCode"])
        let lessons = try XCTUnwrap(raw["lessons"] as? [[String: Any]])
        XCTAssertTrue(lessons.allSatisfy { $0["referenceCode"] == nil })
        let blocks = try XCTUnwrap(lessons[0]["blocks"] as? [[String: Any]])
        XCTAssertTrue(blocks.allSatisfy { $0["focusLines"] == nil })
        XCTAssertEqual(try CourseImport.parse(String(decoding: data, as: UTF8.self)), original)

        var course = original
        course.referenceCode = CourseCodeSample(language: "python", source: "a = 1\nprint(a)")
        course.lessons[0].referenceCode = CourseCodeSample(language: "cpp", source: "int a = 1;\n++a;", filename: "main.cpp")
        course.lessons[0].blocks = [CourseBlock(type: .text, text: "观察第二行。", focusLines: [2])]
        let encoded = try WorkspaceCoding.encoder().encode(course)
        XCTAssertEqual(try WorkspaceCoding.decoder().decode(CourseDocument.self, from: encoded), course)
        XCTAssertEqual(try CourseImport.parse(String(decoding: encoded, as: UTF8.self)), course)
    }

    func testCodeContextSourcePriorityAndLiteralExecutionTemplate() throws {
        let sample = { (source: String) in CourseCodeSample(language: "python", source: source) }
        var block = CourseBlock(type: .question, text: "修改程序。", questionType: .shortAnswer,
            code: sample("question"), execution: CourseExecutionConfiguration(language: "python", template: "print({{ANSWER}})",
                stdin: "2", expectedOutput: "3"))
        var lesson = CourseLesson(title: "Lesson", blocks: [block], referenceCode: sample("lesson"))
        let courseReference = sample("course")
        XCTAssertEqual(lesson.codeContext(for: block.id, courseReference: courseReference)?.source, "question")
        lesson.blocks[0].code = nil
        let template = try XCTUnwrap(lesson.codeContext(for: block.id, courseReference: courseReference))
        XCTAssertEqual(template.source, "print({{ANSWER}})")
        XCTAssertEqual(template.language, "python")
        XCTAssertEqual(template.stdin, "2"); XCTAssertEqual(template.expectedOutput, "3")
        lesson.blocks[0].execution = nil
        XCTAssertEqual(lesson.codeContext(for: block.id, courseReference: courseReference)?.source, "lesson")
        lesson.referenceCode = nil
        XCTAssertEqual(lesson.codeContext(for: block.id, courseReference: courseReference)?.source, "course")
        XCTAssertNil(lesson.codeContext(for: UUID(), courseReference: courseReference))

        block = CourseBlock(type: .text, text: "代码说明。", presentation: CoursePresentation(kind: .code, code: sample("presentation")))
        lesson.blocks = [block]
        XCTAssertEqual(lesson.codeContext(for: block.id, courseReference: courseReference)?.source, "presentation")
        var trace = try XCTUnwrap(traceCourse().lessons.first?.blocks.first)
        let originalVariant = try XCTUnwrap(trace.presentation?.trace?.variants.first)
        trace.presentation?.trace?.variants = [
            CourseTraceVariant(id: "first", title: "First", code: sample("first trace"), frames: originalVariant.frames),
            CourseTraceVariant(id: "second", title: "Second", code: sample("second trace"), frames: originalVariant.frames)
        ]
        lesson.blocks = [trace]
        XCTAssertEqual(lesson.codeContext(for: trace.id, courseReference: courseReference)?.source, "first trace")
    }

    func testCodeContextUsesLocalNeighborsWithoutExtractingMarkdownOrHTML() {
        let before = CourseBlock(type: .question, text: "前一段代码。", questionType: .shortAnswer,
            execution: CourseExecutionConfiguration(language: "python", template: "print({{ANSWER}})"))
        let earlier = CourseBlock(type: .text, text: "本课导言。")
        let active = CourseBlock(type: .text, text: "观察上面的程序。")
        let after = CourseBlock(type: .text, text: "下一段代码。",
            presentation: CoursePresentation(kind: .code, code: CourseCodeSample(language: "cpp", source: "int later;")))
        var lesson = CourseLesson(title: "Lesson", blocks: [earlier, before, active, after])
        XCTAssertEqual(lesson.codeContext(for: earlier.id)?.source, "print({{ANSWER}})")
        XCTAssertEqual(lesson.codeContext(for: active.id)?.source, "print({{ANSWER}})", "Prefer the preceding program over a later one.")
        lesson.referenceCode = CourseCodeSample(language: "python", source: "explicit lesson reference")
        XCTAssertEqual(lesson.codeContext(for: active.id)?.source, "explicit lesson reference")
        lesson.referenceCode = nil
        XCTAssertEqual(lesson.codeContext(for: active.id, courseReference: CourseCodeSample(language: "python", source: "explicit course reference"))?.source,
                       "explicit course reference")

        let markdown = CourseBlock(type: .text, text: "Markdown 备用说明。", presentation: CoursePresentation(kind: .markdown,
            markdown: CourseMarkdownContent(source: "```python\nprint('not a reference')\n```")))
        let html = CourseBlock(type: .text, text: "HTML 备用说明。", presentation: CoursePresentation(kind: .html,
            html: CourseWebContent(source: "<pre>print('not a reference')</pre>")))
        let isolated = CourseLesson(title: "Different lesson", blocks: [markdown, html, active])
        XCTAssertNil(isolated.codeContext(for: active.id), "No source is inferred from web content or a different lesson.")
    }

    func testCodeContextHighlightsFollowCurrentBlockWithoutStaleNeighborFocus() {
        let code = CourseCodeSample(language: "python", source: "a = 1\nprint(a)", highlightLines: [1])
        let source = CourseBlock(type: .text, text: "第一行。", presentation: CoursePresentation(kind: .code, code: code), focusLines: [2])
        let active = CourseBlock(type: .text, text: "继续讲解。")
        var lesson = CourseLesson(title: "Lesson", blocks: [source, active])
        XCTAssertEqual(lesson.codeContext(for: source.id)?.highlightLines, [2])
        lesson.blocks[0].focusLines = nil
        XCTAssertEqual(lesson.codeContext(for: source.id)?.highlightLines, [1])
        XCTAssertNil(lesson.codeContext(for: active.id)?.highlightLines)
        lesson.blocks[1].focusLines = [2]
        XCTAssertEqual(lesson.codeContext(for: active.id)?.highlightLines, [2])
        lesson.blocks[1].focusLines = []
        XCTAssertEqual(lesson.codeContext(for: active.id)?.highlightLines, [])
        lesson.referenceCode = code
        lesson.blocks[1].focusLines = nil
        XCTAssertEqual(lesson.codeContext(for: active.id)?.highlightLines, [1], "Explicit references may define a default focus.")
        lesson.blocks[1].focusLines = []
        XCTAssertEqual(lesson.codeContext(for: active.id)?.highlightLines, [])
        XCTAssertEqual(lesson.blocks[0].presentation?.code?.highlightLines, [1], "Resolving must not mutate the authored code.")
    }

    func testCodeContextFocusValidationNormalizesNewlinesAndUsesEffectiveSource() throws {
        var course = CourseDocument(title: "Code", lessons: [CourseLesson(title: "Lesson", blocks: [
            CourseBlock(type: .text, text: "逐行讲解。", focusLines: [1, 3, 4])
        ])], referenceCode: CourseCodeSample(language: "python", source: "one\r\ntwo\rthree\n"))
        XCTAssertNoThrow(try CourseValidation.validate(course))
        for lines in [[0], [-1], [5], [1, 1], Array(1...201)] {
            var invalid = course; invalid.lessons[0].blocks[0].focusLines = lines
            XCTAssertThrowsError(try CourseValidation.validate(invalid), "\(lines)")
        }
        course.lessons[0].blocks[0].presentation = CoursePresentation(kind: .code,
            code: CourseCodeSample(language: "python", source: "short source"))
        XCTAssertThrowsError(try CourseValidation.validate(course), "Current code takes precedence over a longer course reference.")
        course.lessons[0].blocks[0].presentation = nil
        course.referenceCode = nil
        XCTAssertThrowsError(try CourseValidation.validate(course))
        course.lessons[0].blocks[0].focusLines = []
        XCTAssertNoThrow(try CourseValidation.validate(course))
        course.lessons[0].referenceCode = CourseCodeSample(language: "python", source: "one line", highlightLines: [2])
        XCTAssertThrowsError(try CourseValidation.validate(course), "Explicit references use the same code validation as code blocks.")
    }

    func testCodeContextImportRejectsUnknownReferenceFieldsAndInvalidFocusTypes() throws {
        let course = CourseDocument(title: "Code", lessons: [CourseLesson(title: "Lesson", blocks: [
            CourseBlock(type: .text, text: "讲解代码。", focusLines: [1])
        ], referenceCode: CourseCodeSample(language: "python", source: "print(1)"))],
        referenceCode: CourseCodeSample(language: "python", source: "print(2)"))
        let data = try WorkspaceCoding.encoder().encode(course)
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        func reject(_ value: [String: Any]) throws {
            let modified = try JSONSerialization.data(withJSONObject: value)
            XCTAssertThrowsError(try CourseImport.parse(String(decoding: modified, as: UTF8.self)))
        }
        for level in ["course", "lesson"] {
            for reference: Any in [NSNull(), ["language": "python", "source": "print(1)", "unknown": true],
                                   ["language": "python", "source": "print(1)", "annotations": [["line": 1, "text": "why", "extra": true]]]] {
                var changed = original
                if level == "course" { changed["referenceCode"] = reference }
                else {
                    var lessons = changed["lessons"] as! [[String: Any]]
                    lessons[0]["referenceCode"] = reference; changed["lessons"] = lessons
                }
                try reject(changed)
            }
        }
        for focus: Any in [NSNull(), "1", [true], [1.5], [0], [2], [1, 1]] {
            var changed = original
            var lessons = changed["lessons"] as! [[String: Any]]
            var blocks = lessons[0]["blocks"] as! [[String: Any]]
            blocks[0]["focusLines"] = focus; lessons[0]["blocks"] = blocks; changed["lessons"] = lessons
            try reject(changed)
        }
        XCTAssertEqual(try CourseImport.parse(String(decoding: data, as: UTF8.self)), course)
    }

    func testCodeSpansSegmentsUseNonOverlappingOccurrencesAndUnionMarkedRanges() {
        XCTAssertEqual(CourseCodeMarking.segments(line: "aaaa", spans: [CourseCodeSpan(line: 1, text: "aa", occurrence: 2)]), [
            CourseCodeSegment(text: "aa", highlighted: false), CourseCodeSegment(text: "aa", highlighted: true)
        ])
        XCTAssertEqual(CourseCodeMarking.segments(line: "aaa", spans: [CourseCodeSpan(line: 1, text: "aa", occurrence: 2)]), [
            CourseCodeSegment(text: "aaa", highlighted: false)
        ])
        XCTAssertEqual(CourseCodeMarking.segments(line: "abcdef", spans: [
            CourseCodeSpan(line: 1, text: "abc"), CourseCodeSpan(line: 1, text: "bcd"), CourseCodeSpan(line: 1, text: "e")
        ]), [CourseCodeSegment(text: "abcde", highlighted: true), CourseCodeSegment(text: "f", highlighted: false)])
        XCTAssertEqual(CourseCodeMarking.segments(line: "Count count", spans: [CourseCodeSpan(line: 1, text: "count")]), [
            CourseCodeSegment(text: "Count ", highlighted: false), CourseCodeSegment(text: "count", highlighted: true)
        ])
        XCTAssertEqual(CourseCodeMarking.segments(line: "", spans: []), [CourseCodeSegment(text: "", highlighted: false)])
    }

    func testCodeSpansUnicodeMatchingPreservesLiteralSourceWithoutCanonicalEquivalence() {
        let line = "👩🏽‍💻 变量😀变量 e\u{301} é"
        let segments = CourseCodeMarking.segments(line: line, spans: [
            CourseCodeSpan(line: 1, text: "变量", occurrence: 2), CourseCodeSpan(line: 1, text: "é")
        ])
        XCTAssertEqual(segments, [
            CourseCodeSegment(text: "👩🏽‍💻 变量😀", highlighted: false),
            CourseCodeSegment(text: "变量", highlighted: true),
            CourseCodeSegment(text: " e\u{301} ", highlighted: false), CourseCodeSegment(text: "é", highlighted: true)
        ])
        XCTAssertEqual(Array(segments.map(\.text).joined().utf16), Array(line.utf16))
        XCTAssertEqual(CourseCodeMarking.segments(line: "e\u{301}", spans: [CourseCodeSpan(line: 1, text: "é")]), [
            CourseCodeSegment(text: "e\u{301}", highlighted: false)
        ])
        let partial = CourseCodeMarking.segments(line: "e\u{301}", spans: [CourseCodeSpan(line: 1, text: "e")])
        XCTAssertEqual(Array(partial.map(\.text).joined().utf16), Array("e\u{301}".utf16))
        XCTAssertTrue(partial.first?.highlighted == true)
    }

    func testCodeSpansValidationChecksExactMatchesNewlinesBoundsAndDuplicateOccurrences() throws {
        var course = CourseDocument(title: "Code", lessons: [CourseLesson(title: "Lesson", blocks: [
            CourseBlock(type: .text, text: "讲解变量。")
        ])], referenceCode: CourseCodeSample(language: "python", source: "Count count\r\naaaa\r变量😀变量\né e\u{301}"))
        let valid = [CourseCodeSpan(line: 1, text: "count"), CourseCodeSpan(line: 2, text: "aa", occurrence: 2),
                     CourseCodeSpan(line: 3, text: "变量", occurrence: 2), CourseCodeSpan(line: 4, text: "é"),
                     CourseCodeSpan(line: 4, text: "e\u{301}")]
        course.referenceCode?.highlightSpans = valid
        XCTAssertNoThrow(try CourseValidation.validate(course), "Canonical-equivalent but literal-distinct text is not a duplicate.")
        let invalid = [
            CourseCodeSpan(line: 0, text: "count"), CourseCodeSpan(line: 5, text: "count"), CourseCodeSpan(line: 1, text: "COUNT"),
            CourseCodeSpan(line: 2, text: "aa", occurrence: 3), CourseCodeSpan(line: 1, text: "count", occurrence: 0),
            CourseCodeSpan(line: 1, text: "count", occurrence: 20_001), CourseCodeSpan(line: 1, text: ""),
            CourseCodeSpan(line: 1, text: " "), CourseCodeSpan(line: 1, text: "Count\ncount"),
            CourseCodeSpan(line: 1, text: "Count\rcount"), CourseCodeSpan(line: 1, text: "\t"),
            CourseCodeSpan(line: 1, text: "\u{7f}"), CourseCodeSpan(line: 1, text: "\u{85}"),
            CourseCodeSpan(line: 1, text: "\u{2028}"), CourseCodeSpan(line: 1, text: "\u{2029}")
        ]
        for span in invalid {
            course.referenceCode?.highlightSpans = [span]
            XCTAssertThrowsError(try CourseValidation.validate(course), "\(span)")
        }
        course.referenceCode?.highlightSpans = [CourseCodeSpan(line: 1, text: "count"), CourseCodeSpan(line: 1, text: "count", occurrence: 1)]
        XCTAssertThrowsError(try CourseValidation.validate(course), "Omitted occurrence and explicit 1 designate the same match.")
        course.referenceCode?.source = String(repeating: "a", count: 20_000)
        course.referenceCode?.highlightSpans = [CourseCodeSpan(line: 1, text: "a", occurrence: 20_000)]
        XCTAssertNoThrow(try CourseValidation.validate(course))
        course.referenceCode?.highlightSpans = (1...200).map { CourseCodeSpan(line: 1, text: "a", occurrence: $0) }
        XCTAssertNoThrow(try CourseValidation.validate(course))
        course.referenceCode?.highlightSpans?.append(CourseCodeSpan(line: 1, text: "a", occurrence: 201))
        XCTAssertThrowsError(try CourseValidation.validate(course))
        let maximumText = String(repeating: "😀", count: 1_000)
        course.referenceCode?.source = maximumText + "😀"
        course.referenceCode?.highlightSpans = [CourseCodeSpan(line: 1, text: maximumText)]
        XCTAssertNoThrow(try CourseValidation.validate(course))
        course.referenceCode?.highlightSpans = [CourseCodeSpan(line: 1, text: maximumText + "😀")]
        XCTAssertThrowsError(try CourseValidation.validate(course))
    }

    func testCodeSpansCurrentFocusClearsUnspecifiedDefaultsAndNeighborMarks() throws {
        let marks = [CourseCodeSpan(line: 1, text: "value")]
        let code = CourseCodeSample(language: "python", source: "value = 1\nprint(value)", highlightLines: [1], highlightSpans: marks)
        let source = CourseBlock(type: .text, text: "程序。", presentation: CoursePresentation(kind: .code, code: code))
        let current = CourseBlock(type: .text, text: "重点。")
        var lesson = CourseLesson(title: "Lesson", blocks: [source, current], referenceCode: code)
        XCTAssertEqual(lesson.codeContext(for: current.id)?.highlightLines, [1])
        XCTAssertEqual(lesson.codeContext(for: current.id)?.highlightSpans, marks)
        lesson.blocks[1].focusSpans = [CourseCodeSpan(line: 2, text: "value")]
        XCTAssertNil(lesson.codeContext(for: current.id)?.highlightLines)
        XCTAssertEqual(lesson.codeContext(for: current.id)?.highlightSpans, lesson.blocks[1].focusSpans)
        lesson.blocks[1].focusSpans = []
        XCTAssertNil(lesson.codeContext(for: current.id)?.highlightLines)
        XCTAssertEqual(lesson.codeContext(for: current.id)?.highlightSpans, [])
        lesson.blocks[1].focusSpans = nil; lesson.blocks[1].focusLines = [2]
        XCTAssertEqual(lesson.codeContext(for: current.id)?.highlightLines, [2])
        XCTAssertNil(lesson.codeContext(for: current.id)?.highlightSpans)
        lesson.blocks[1].focusSpans = marks
        XCTAssertEqual(lesson.codeContext(for: current.id)?.highlightSpans, marks)
        lesson.blocks[1].focusLines = nil; lesson.blocks[1].focusSpans = nil; lesson.referenceCode = nil
        XCTAssertNil(lesson.codeContext(for: current.id)?.highlightLines)
        XCTAssertNil(lesson.codeContext(for: current.id)?.highlightSpans)
        XCTAssertEqual(lesson.blocks[0].presentation?.code?.highlightSpans, marks)

        var course = CourseDocument(title: "Code", lessons: [CourseLesson(title: "Lesson", blocks: [current])])
        course.lessons[0].blocks[0].focusSpans = []
        XCTAssertNoThrow(try CourseValidation.validate(course))
        course.lessons[0].blocks[0].focusSpans = marks
        XCTAssertThrowsError(try CourseValidation.validate(course))
        course.lessons[0].blocks[0] = CourseBlock(type: .question, text: "填写值。", questionType: .shortAnswer,
            input: CourseQuestionInput(kind: .integer), execution: CourseExecutionConfiguration(language: "python", template: "print({{ANSWER}})"),
            focusSpans: [CourseCodeSpan(line: 1, text: "{{ANSWER}}")])
        XCTAssertNoThrow(try CourseValidation.validate(course), "A fill-in template itself remains the source of character marks.")
    }

    func testCodeSpansTraceRoundTripAndStrictImportAtAllThreeLocations() throws {
        var course = traceCourse()
        let mark = CourseCodeSpan(line: 2, text: "value")
        course.lessons[0].blocks[0].presentation?.trace?.variants[0].code.highlightSpans = [mark]
        course.lessons[0].blocks[0].presentation?.trace?.variants[0].frames[0].focusSpans = [mark]
        course.lessons[0].blocks[0].focusSpans = [CourseCodeSpan(line: 3, text: "value")]
        let data = try WorkspaceCoding.encoder().encode(course)
        XCTAssertEqual(try WorkspaceCoding.decoder().decode(CourseDocument.self, from: data), course)
        XCTAssertEqual(try CourseImport.parse(String(decoding: data, as: UTF8.self)), course)
        var invalid = course
        invalid.lessons[0].blocks[0].presentation?.trace?.variants[0].frames[0].focusSpans = [CourseCodeSpan(line: 2, text: "missing")]
        XCTAssertThrowsError(try CourseValidation.validate(invalid))
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for location in ["code", "block", "frame"] {
            for span: Any in [NSNull(), ["line": 2, "text": "value", "extra": true],
                              ["line": true, "text": "value"], ["line": 2, "text": 4],
                              ["line": 2, "text": "value", "occurrence": true], ["line": 2, "text": "value", "occurrence": 1.5]] {
                var modified = raw
                var lessons = modified["lessons"] as! [[String: Any]]
                var blocks = lessons[0]["blocks"] as! [[String: Any]]
                var presentation = blocks[0]["presentation"] as! [String: Any]
                var trace = presentation["trace"] as! [String: Any]
                var variants = trace["variants"] as! [[String: Any]]
                if location == "code" {
                    var code = variants[0]["code"] as! [String: Any]
                    code["highlightSpans"] = [span]; variants[0]["code"] = code
                } else if location == "frame" {
                    var frames = variants[0]["frames"] as! [[String: Any]]
                    frames[0]["focusSpans"] = [span]; variants[0]["frames"] = frames
                } else { blocks[0]["focusSpans"] = [span] }
                trace["variants"] = variants; presentation["trace"] = trace; blocks[0]["presentation"] = presentation
                lessons[0]["blocks"] = blocks; modified["lessons"] = lessons
                let invalidData = try JSONSerialization.data(withJSONObject: modified)
                XCTAssertThrowsError(try CourseImport.parse(String(decoding: invalidData, as: UTF8.self)), location)
            }
        }
    }

}
