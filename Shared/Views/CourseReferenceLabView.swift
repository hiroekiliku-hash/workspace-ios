import SwiftUI

/// A separate sample session makes the new teaching design reversible without replacing any course.
struct CourseReferenceLabEntry<Destination: View>: View {
    @Environment(\.workspacePalette) private var palette
    @Environment(\.dynamicTypeSize) private var typeSize
    @ViewBuilder let destination: () -> Destination

    var body: some View {
        NavigationLink(destination: destination) {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("C++ · 体验课").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    Text("值传递与引用传递").font(.title3.weight(.semibold)).foregroundStyle(.primary)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "arrow.up.right").font(.body.weight(.medium))
            }
            .foregroundStyle(palette.action)
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 23, style: .continuous)
                    .fill(LinearGradient(colors: [palette.surface, palette.action.opacity(0.055)], startPoint: .topLeading, endPoint: .bottomTrailing))
            }
            .overlay { RoundedRectangle(cornerRadius: 23).strokeBorder(palette.action.opacity(0.16), lineWidth: 1) }
            .contentShape(RoundedRectangle(cornerRadius: 23))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("courses.reference-lab")
        .accessibilityLabel("体验 C++ 值传递与引用传递实验课")
    }
}

struct CourseReferenceLabPreview<Reader: View>: View {
    @Environment(\.workspacePalette) private var palette
    @State private var session: WorkspaceStore?
    @State private var document: CourseDocument?
    @State private var failure: String?
    @State private var attempt = 0
    @ViewBuilder let reader: (UUID, UUID) -> Reader

    var body: some View {
        Group {
            if let session, let document, let lesson = document.lessons.first {
                reader(document.id, lesson.id)
                    .environment(session)
                    .id(ObjectIdentifier(session))
            } else if let failure {
                ContentUnavailableView {
                    Label("暂时无法打开体验课", systemImage: "book.closed")
                } description: { Text(failure) } actions: {
                    Button("重试") { attempt += 1 }
                }
            } else {
                ProgressView("准备传参实验室…").tint(palette.action)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: attempt) {
            guard session == nil else { return }
            failure = nil
            do {
                await AppContentService.shared.refresh()
                let edition: CourseEdition
                if let published = AppContentService.shared.course("cpp-value-reference") {
                    edition = published
                } else {
                    guard let url = Bundle.main.url(forResource: "CppValueReference", withExtension: "json") else {
                        throw WorkspaceFailure.invalid(WorkspaceLocalization.string("暂时无法读取体验课，请稍后再试。"))
                    }
                    let course = try await Task.detached(priority: .userInitiated) {
                        try CourseImport.parse(String(contentsOf: url, encoding: .utf8))
                    }.value
                    // This bundled source is the version-2 public sample.
                    edition = CourseEdition(course: course, revision: 2, updatedAt: .distantPast)
                }
                try Task.checkCancellation()
                let isolated = try WorkspaceStore(repository: SwiftDataRepository(inMemory: true), isDemoMode: true)
                isolated.courses.prepare()
                try isolated.courses.installPublishedSample(edition)
                try Task.checkCancellation()
                document = edition.course
                session = isolated
            } catch is CancellationError {
                // Leaving a sample must not publish a late error into the real workspace.
            } catch { failure = error.localizedDescription }
        }
    }
}
