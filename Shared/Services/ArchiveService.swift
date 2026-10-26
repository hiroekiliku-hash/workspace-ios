import Foundation
import CryptoKit
import CommonCrypto
import Security
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let workspaceArchive = UTType(exportedAs: "org.example.workspace.archive", conformingTo: .data)
}
struct ArchiveDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.workspaceArchive, .json, .data] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw WorkspaceFailure.invalid(WorkspaceLocalization.string("无法读取归档。")) }
        self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
enum ArchiveService {
    private static let magic = Data("GWNA1".utf8)
    static func encoder() -> JSONEncoder {
        WorkspaceCoding.encoder()
    }
    static func decoder() -> JSONDecoder {
        WorkspaceCoding.decoder()
    }
    static func encode(_ state: WorkspaceState, password: String?) throws -> Data {
        try WorkspaceLogic.validate(state)
        let plaintext = try encoder().encode(state)
        guard plaintext.count <= 128 * 1024 * 1024 else { throw WorkspaceFailure.tooLarge }
        guard let password, !password.isEmpty else { return plaintext }
        guard password.count >= 8 else { throw WorkspaceFailure.invalid(WorkspaceLocalization.string("归档密码至少需要 8 个字符。")) }
        var salt = Data(count: 16)
        let randomStatus = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        guard randomStatus == errSecSuccess else { throw WorkspaceFailure.invalid(WorkspaceLocalization.string("无法生成安全随机数。")) }
        let key = try deriveKey(password, salt: salt)
        let box = try AES.GCM.seal(plaintext, using: key, authenticating: magic + salt)
        guard let combined = box.combined else { throw WorkspaceFailure.invalid(WorkspaceLocalization.string("无法生成加密归档。")) }
        return magic + salt + combined
    }
    static func read(url: URL, password: String?) throws -> WorkspaceState {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 128 * 1024 * 1024 + 1024 else { throw WorkspaceFailure.tooLarge }
        return try decode(Data(contentsOf: url), password: password)
    }
    static func decode(_ data: Data, password: String?) throws -> WorkspaceState {
        guard data.count <= 128 * 1024 * 1024 + 1024 else { throw WorkspaceFailure.tooLarge }
        var plaintext = data
        if data.starts(with: magic) {
            guard let password, !password.isEmpty else { throw WorkspaceFailure.invalid(WorkspaceLocalization.string("这是加密归档，请在“设置 → 导入”中输入归档密码。")) }
            guard data.count > 49 else { throw WorkspaceFailure.invalid(WorkspaceLocalization.string("归档已截断。")) }
            let salt = data.subdata(in: 5..<21)
            do {
                let key = try deriveKey(password, salt: salt)
                let box = try AES.GCM.SealedBox(combined: data.dropFirst(21))
                plaintext = try AES.GCM.open(box, using: key, authenticating: magic + salt)
            } catch { throw WorkspaceFailure.invalid(WorkspaceLocalization.string("密码不正确，或归档内容已损坏。")) }
        }
        let state = try decoder().decode(WorkspaceState.self, from: plaintext)
        try WorkspaceLogic.validate(state)
        return state
    }
    private static func deriveKey(_ password: String, salt: Data) throws -> SymmetricKey {
        var key = Data(count: 32)
        let status = password.withCString { pass in
            salt.withUnsafeBytes { saltBytes in
                key.withUnsafeMutableBytes { output in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pass, password.utf8.count,
                        saltBytes.bindMemory(to: UInt8.self).baseAddress!, salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), 200_000,
                        output.bindMemory(to: UInt8.self).baseAddress!, 32)
                }
            }
        }
        guard status == kCCSuccess else { throw WorkspaceFailure.invalid(WorkspaceLocalization.string("无法派生归档加密密钥。")) }
        return SymmetricKey(data: key)
    }
}
