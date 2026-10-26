import Foundation
import AuthenticationServices
#if os(iOS)
import UIKit
#else
import AppKit
#endif

@MainActor final class WebLoginAuthorization: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var continuation: CheckedContinuation<URL, Error>?
    private var session: ASWebAuthenticationSession?
    private var requestID: UUID?

    func perform(url: URL) async throws -> URL {
        guard continuation == nil else { throw WorkspaceFailure.invalid(WorkspaceLocalization.string("已有网页登录正在进行。")) }
        let requestID = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                self.requestID = requestID
                let completion: ASWebAuthenticationSession.CompletionHandler = { [weak self] url, error in
                    Task { @MainActor in
                        if let error { self?.complete(.failure(error), requestID: requestID) }
                        else if let url { self?.complete(.success(url), requestID: requestID) }
                        else { self?.complete(.failure(NativeBackendError.malformed), requestID: requestID) }
                    }
                }
                let session: ASWebAuthenticationSession
                if #available(iOS 17.4, macOS 14.4, *) {
                    session = ASWebAuthenticationSession(url: url, callback: .customScheme("guangyi-workspace"), completionHandler: completion)
                } else {
                    session = ASWebAuthenticationSession(url: url, callbackURLScheme: "guangyi-workspace", completionHandler: completion)
                }
                self.session = session
                session.presentationContextProvider = self
                session.prefersEphemeralWebBrowserSession = true
                if !session.start() {
                    complete(.failure(WorkspaceFailure.invalid(WorkspaceLocalization.string("无法打开系统登录页面，请重试或使用账号密码登录。"))), requestID: requestID)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard self?.requestID == requestID else { return }
                self?.session?.cancel()
                self?.complete(.failure(CancellationError()), requestID: requestID)
            }
        }
    }
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        #if os(iOS)
        return UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first { $0.isKeyWindow } ?? ASPresentationAnchor()
        #else
        return NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first ?? ASPresentationAnchor()
        #endif
    }
    private func complete(_ result: Result<URL, Error>, requestID: UUID) {
        guard self.requestID == requestID else { return }
        let continuation = continuation
        self.continuation = nil; session = nil; self.requestID = nil
        continuation?.resume(with: result)
    }
}

@MainActor final class PasskeyAuthorization: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    private var continuation: CheckedContinuation<PasskeyCredential, Error>?
    private var controller: ASAuthorizationController?
    func perform(options: PasskeyChallenge.Options, registering: Bool, expectedHost: String) async throws -> PasskeyCredential {
        guard NativeCapabilities.passkeysEnabled else { throw NativeBackendError.passkeysUnavailable }
        guard continuation == nil else { throw WorkspaceFailure.invalid(WorkspaceLocalization.string("已有通行密钥请求正在进行。")) }
        let rpID = options.rp?.id ?? options.rpId ?? ""
        guard rpID == expectedHost, let challenge = Data(base64URL: options.challenge), !challenge.isEmpty else { throw NativeBackendError.malformed }
        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: rpID)
        let request: ASAuthorizationRequest
        if registering {
            guard let user = options.user, let handle = Data(base64URL: user.id) else { throw NativeBackendError.malformed }
            let registration = provider.createCredentialRegistrationRequest(challenge: challenge, name: user.name, userID: handle)
            registration.userVerificationPreference = .required
            request = registration
        } else {
            let assertion = provider.createCredentialAssertionRequest(challenge: challenge)
            assertion.userVerificationPreference = .required
            if let credentials = options.allowCredentials {
                assertion.allowedCredentials = try credentials.map { value in
                    guard let id = Data(base64URL: value.id) else { throw NativeBackendError.malformed }
                    return ASAuthorizationPlatformPublicKeyCredentialDescriptor(credentialID: id)
                }
            }
            request = assertion
        }
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let controller = ASAuthorizationController(authorizationRequests: [request])
            self.controller = controller
            controller.delegate = self; controller.presentationContextProvider = self
            controller.performRequests()
        }
    }
    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        #if os(iOS)
        return UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first { $0.isKeyWindow } ?? ASPresentationAnchor()
        #else
        return NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first ?? ASPresentationAnchor()
        #endif
    }
    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        let response: PasskeyCredential.Response
        let credentialID: Data
        if let credential = authorization.credential as? ASAuthorizationPlatformPublicKeyCredentialRegistration {
            guard let attestation = credential.rawAttestationObject else { complete(.failure(NativeBackendError.malformed)); return }
            credentialID = credential.credentialID
            response = .init(clientDataJSON: credential.rawClientDataJSON.base64URL, attestationObject: attestation.base64URL, transports: ["internal"])
        } else if let credential = authorization.credential as? ASAuthorizationPlatformPublicKeyCredentialAssertion {
            credentialID = credential.credentialID
            response = .init(clientDataJSON: credential.rawClientDataJSON.base64URL, authenticatorData: credential.rawAuthenticatorData.base64URL,
                signature: credential.signature.base64URL, userHandle: credential.userID.base64URL)
        } else { complete(.failure(NativeBackendError.malformed)); return }
        complete(.success(PasskeyCredential(id: credentialID.base64URL, rawId: credentialID.base64URL, response: response)))
    }
    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) { complete(.failure(error)) }
    private func complete(_ result: Result<PasskeyCredential, Error>) {
        let continuation = continuation; self.continuation = nil; controller = nil
        continuation?.resume(with: result)
    }
}
extension Data {
    init?(base64URL: String) {
        let value = base64URL.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        self.init(base64Encoded: value + String(repeating: "=", count: (4 - value.count % 4) % 4))
    }
    var base64URL: String { base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
}
