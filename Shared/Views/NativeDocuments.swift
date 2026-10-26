import SwiftUI
import PDFKit

struct MarkdownDocumentView: View {
    let source: String
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                if block.hasPrefix("```") {
                    let lines = block.components(separatedBy: "\n")
                    Text(lines.dropFirst().filter { !$0.hasPrefix("```") }.joined(separator: "\n"))
                        .font(.body.monospaced()).textSelection(.enabled).padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                } else if block.hasPrefix("#") {
                    let depth = block.prefix(while: { $0 == "#" }).count
                    inline(String(block.dropFirst(depth)).trimmingCharacters(in: .whitespaces))
                        .font(depth == 1 ? .title : depth == 2 ? .title2 : .headline)
                } else if block == "---" || block == "***" { Divider() }
                else if block.hasPrefix("> ") {
                    inline(String(block.dropFirst(2))).foregroundStyle(.secondary).padding(.leading, 12)
                } else { inline(block) }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
            .environment(\.openURL, OpenURLAction { url in
                ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") ? .systemAction : .discarded
            })
    }
    private func inline(_ source: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return Text((try? AttributedString(markdown: source, options: options)) ?? AttributedString(source))
    }
    private var blocks: [String] {
        var result: [String] = [], code: [String] = [], inCode = false
        for line in source.components(separatedBy: .newlines) {
            if line.hasPrefix("```") {
                if inCode { code.append(line); result.append(code.joined(separator: "\n")); code = []; inCode = false }
                else { inCode = true; code = [line] }
            } else if inCode { code.append(line) }
            else if !line.isEmpty { result.append(line) }
        }
        if !code.isEmpty { result.append(code.joined(separator: "\n")) }
        return result
    }
}
struct PDFDocumentView: View {
    let asset: WorkspaceAsset
    var body: some View {
        NativePDFView(data: asset.data).navigationTitle(asset.name)
    }
}
final class PDFCoordinator {
    var data: Data
    init(_ data: Data) { self.data = data }
}
#if os(macOS)
struct NativePDFView: NSViewRepresentable {
    let data: Data
    func makeCoordinator() -> PDFCoordinator { PDFCoordinator(data) }
    func makeNSView(context: Context) -> PDFView {
        let view = PDFView(); view.autoScales = true; view.document = PDFDocument(data: data)
        return view
    }
    func updateNSView(_ view: PDFView, context: Context) {
        if context.coordinator.data != data { context.coordinator.data = data; view.document = PDFDocument(data: data) }
    }
}
#else
struct NativePDFView: UIViewRepresentable {
    let data: Data
    func makeCoordinator() -> PDFCoordinator { PDFCoordinator(data) }
    func makeUIView(context: Context) -> PDFView {
        let view = PDFView(); view.autoScales = true; view.document = PDFDocument(data: data)
        return view
    }
    func updateUIView(_ view: PDFView, context: Context) {
        if context.coordinator.data != data { context.coordinator.data = data; view.document = PDFDocument(data: data) }
    }
}
#endif
