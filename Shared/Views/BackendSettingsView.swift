import SwiftUI
import AuthenticationServices
#if os(macOS)
import AppKit
#else
import UIKit
#endif

private enum BackendSettingsRoute: Hashable {
    case linkedAccounts
}

struct BackendSettingsView: View {
    @Environment(WorkspaceStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var email = ""
    @State private var password = ""
    @State private var verificationCode = ""
    @State private var needsVerificationCode = false
    @State private var showingPasswordLogin = false
    @State private var busy = false
    @State private var authorization = PasskeyAuthorization()
    @State private var webAuthorization = WebLoginAuthorization()
    @State private var passkeys: [RegisteredPasskeys.Credential] = []
    var body: some View {
        let backend = store.backend
        Form {
            ProfileSettingsSection()
            if store.isDemoMode {
                Section { Label(WorkspaceLocalization.string("演示模式无需登录"), systemImage: "flask") }
            } else {
            #if os(macOS)
            if !backend.signedIn && backend.sessionRestoreNeedsAuthorization {
                Section {
                    Button(WorkspaceLocalization.string("恢复已保存的登录"), systemImage: "key") {
                        run {
                            try await backend.restoreSavedSession()
                            try await store.completeAccountSignIn()
                        }
                    }.buttonStyle(WorkspacePrimaryButtonStyle()).disabled(busy || store.syncing)
                        .workspaceActionRow()
                        .accessibilityIdentifier("account-restore-session")
                } footer: {
                    Text(WorkspaceLocalization.string("上次的登录需要 Mac 授权。你也可以继续使用本机内容。"))
                }
            }
            #endif
            if !backend.signedIn {
                Section {
                    Button(busy ? WorkspaceLocalization.string("正在登录…") : webLoginTitle, systemImage: "person.crop.circle") {
                        run {
                            try await backend.signInWithWeb(using: webAuthorization)
                            password = ""
                            try await store.completeAccountSignIn()
                        }
                    }.buttonStyle(WorkspacePrimaryButtonStyle(prominent: !prefersNativeLogin)).disabled(busy || store.syncing)
                    .workspaceActionRow()
                }
            }
            Section(WorkspaceLocalization.string("账号")) {
                if backend.signedIn {
                    LabeledContent(WorkspaceLocalization.string("账号"), value: backend.accountName)
                    if NativeCapabilities.passkeysEnabled {
                        Button(WorkspaceLocalization.string("添加新的通行密钥"), systemImage: "person.badge.key") {
                            run { try await backend.addPasskey(using: authorization); passkeys = try await backend.registeredPasskeys().credentials; store.information = WorkspaceLocalization.string("通行密钥已添加，可在其他设备使用同一账号登录。") }
                        }.disabled(busy || store.syncing)
                        ForEach(passkeys) { credential in
                            HStack {
                                Text(WorkspaceLocalization.string("通行密钥 · ") + Date(timeIntervalSince1970: credential.created / 1000).formatted(.dateTime.year().month(.abbreviated).day().locale(WorkspaceLocalization.locale)))
                                Spacer()
                                Button(WorkspaceLocalization.string("撤销"), role: .destructive) {
                                    run { try await backend.revokePasskey(credential.id); passkeys = try await backend.registeredPasskeys().credentials }
                                }.disabled(busy)
                            }
                        }
                        Button(WorkspaceLocalization.string("查看已注册通行密钥")) { run { passkeys = try await backend.registeredPasskeys().credentials } }.disabled(busy)
                    }
                    Button(WorkspaceLocalization.string("退出登录"), role: .destructive) {
                        run { defer { store.accountSessionChanged() }; try await backend.signOut() }
                    }.disabled(busy || store.syncing)
                } else {
                    if NativeCapabilities.passkeysEnabled {
                        Button(WorkspaceLocalization.string("使用通行密钥登录"), systemImage: "person.badge.key") {
                            run {
                                try await backend.signInWithPasskey(using: authorization)
                                try await store.completeAccountSignIn()
                            }
                        }.disabled(busy || store.syncing)
                    }
                    #if os(iOS)
                    Button {
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { showingPasswordLogin.toggle() }
                    } label: {
                        HStack {
                            Text(WorkspaceLocalization.string("使用账号密码"))
                            Spacer()
                            Image(systemName: showingPasswordLogin ? "chevron.up" : "chevron.down")
                                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                        }
                    }
                    .accessibilityValue(showingPasswordLogin ? WorkspaceLocalization.string("已展开") : WorkspaceLocalization.string("已收起"))
                    .accessibilityIdentifier("account-password-expand")
                    .disabled(busy || store.syncing)
                    #endif
                }
                if !backend.signedIn {
                    Text(WorkspaceLocalization.string("登录后，你的内容会在设备间自动同步。"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if !backend.signedIn && (prefersNativeLogin || showingPasswordLogin) {
                Section { passwordLoginFields }
                Section { passwordLoginAction.workspaceActionRow() }
            }
            if backend.signedIn { Section(WorkspaceLocalization.string("云同步")) {
                LabeledContent(WorkspaceLocalization.string("状态"), value: store.syncStatus)
                Toggle(WorkspaceLocalization.string("自动同步"), isOn: Binding(get: { store.automaticSync }, set: { store.automaticSync = $0 }))
                    .disabled(!backend.signedIn || store.syncing)
                if let sync = backend.lastSync { LabeledContent(WorkspaceLocalization.string("最近同步"), value: sync.formatted(.dateTime.year().month(.abbreviated).day().hour().minute().locale(WorkspaceLocalization.locale))) }
            }
            Section {
                Button(syncActionTitle, systemImage: "arrow.triangle.2.circlepath") {
                    run {
                        if let review = store.pendingSyncReview { store.pendingImport = review.remote.snapshot }
                        else { try await store.synchronize() }
                    }
                }.buttonStyle(WorkspacePrimaryButtonStyle()).disabled(busy || store.syncing || !backend.signedIn)
                    .workspaceActionRow()
            }
            }
            if backend.signedIn {
                Section {
                    NavigationLink(value: BackendSettingsRoute.linkedAccounts) {
                        Label(WorkspaceLocalization.string("关联账户"), systemImage: "person.2")
                    }
                }
            }
            if RemotePushBridge.isEnabled && backend.signedIn {
                Section(WorkspaceLocalization.string("通知")) {
                    LabeledContent(WorkspaceLocalization.string("远程提醒"), value: backend.deviceRegistrationStatus)
                    Button(WorkspaceLocalization.string("启用此设备的远程提醒"), systemImage: "antenna.radiowaves.left.and.right") {
                        run { try await store.notifications.requestAuthorization(); try RemotePushBridge.registerWithApple() }
                    }.disabled(!backend.signedIn || busy)
                }
            }
            }
        }.formStyle(.grouped).navigationTitle(WorkspaceLocalization.string("个人资料与账号")).workspaceInlineTitle()
            .scrollDismissesKeyboard(.interactively)
            .navigationDestination(for: BackendSettingsRoute.self) { route in
                switch route {
                case .linkedAccounts: LinkedAccountsSettingsView()
                }
            }
            .workspaceSelectionFeedback(trigger: backend.signedIn)
            .onChange(of: backend.accountIdentityScope) { _, _ in
                passkeys = []; verificationCode = ""; needsVerificationCode = false
                store.accountSessionChanged()
            }
    }
    private var prefersNativeLogin: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }
    private var webLoginTitle: String { prefersNativeLogin ? WorkspaceLocalization.string("注册或使用通行密钥") : WorkspaceLocalization.string("登录工作坊") }
    @ViewBuilder private var passwordLoginFields: some View {
        TextField(WorkspaceLocalization.string("账号（邮箱）"), text: $email).autocorrectionDisabled().nativeEmailInput()
        SecureField(WorkspaceLocalization.string("密码"), text: $password).textContentType(.password)
        if needsVerificationCode {
            TextField(WorkspaceLocalization.string("验证码或恢复码"), text: $verificationCode)
                .textContentType(.oneTimeCode).autocorrectionDisabled()
        }
    }
    private var passwordLoginAction: some View {
        Button(busy ? WorkspaceLocalization.string("正在登录…") : WorkspaceLocalization.string("登录"), systemImage: "person.crop.circle.badge.checkmark") {
            run {
                do {
                    try await store.backend.signIn(email: email, password: password,
                        code: needsVerificationCode ? verificationCode.trimmingCharacters(in: .whitespacesAndNewlines) : nil)
                } catch NativeBackendError.secondFactorRequired {
                    needsVerificationCode = true; return
                } catch NativeBackendError.invalidSecondFactor {
                    needsVerificationCode = true; verificationCode = ""; throw NativeBackendError.invalidSecondFactor
                }
                password = ""; verificationCode = ""; needsVerificationCode = false
                try await store.completeAccountSignIn()
            }
        }.buttonStyle(WorkspacePrimaryButtonStyle(prominent: prefersNativeLogin))
            .disabled(busy || store.syncing || email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || password.isEmpty || (needsVerificationCode && verificationCode.isEmpty))
            .accessibilityIdentifier("account-password-login")
    }
    private var syncActionTitle: String {
        if store.syncing { return WorkspaceLocalization.string("正在同步…") }
        if store.pendingSyncReview != nil { return WorkspaceLocalization.string("继续比较冲突") }
        if store.syncNeedsRetry { return WorkspaceLocalization.string("重试同步") }
        return WorkspaceLocalization.string("立即同步")
    }
    private func run(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true
        Task { do { try await operation() } catch {
                let failure = error as NSError
                let authorizationCanceled = failure.domain == ASAuthorizationError.errorDomain && failure.code == ASAuthorizationError.canceled.rawValue
                let webLoginCanceled = failure.domain == ASWebAuthenticationSessionError.errorDomain && failure.code == ASWebAuthenticationSessionError.canceledLogin.rawValue
                if !(error is CancellationError) && !authorizationCanceled && !webLoginCanceled { store.errorMessage = error.localizedDescription }
            }; busy = false }
    }
}

struct APIConfigurationView: View {
    var body: some View {
        List {
            NavigationLink { TextImportSettingsView() } label: {
                Label(WorkspaceLocalization.string("AI 连接"), systemImage: "link")
            }
            NavigationLink { CoursePublishingSettingsView() } label: {
                Label(WorkspaceLocalization.string("课程发布"), systemImage: "book.closed")
            }
        }.navigationTitle(WorkspaceLocalization.string("API 接口")).workspaceInlineTitle()
    }
}

struct CoursePublishingSettingsView: View {
    var body: some View { TextImportSettingsView(integrationKind: .course) }
}

enum APIIntegrationKind { case calendar, course }

struct TextImportSettingsView: View {
    var integrationKind = APIIntegrationKind.calendar
    @Environment(WorkspaceStore.self) private var store
    @State private var configuration: CalendarTextIntegration?
    @State private var loadedScope: String?
    @State private var loading = false
    @State private var busy = false
    @State private var notice: String?
    @State private var credentialToRevoke: CalendarTextCredential?
    @State private var connectionDraft: AIConnectionDraft?
    @State private var operationTask: Task<Void, Never>?

    var body: some View {
        let backend = store.backend
        Form {
            if !store.isDemoMode, backend.currentWorkspaceID == nil, let scope = backend.accountIdentityScope {
                if !isCourse {
                    Section {
                        Text(WorkspaceLocalization.string("为每个 AI 或自动化工具创建独立连接，再把对应提示词交给它。"))
                        .foregroundStyle(.secondary)
                    }
                }
                if let configuration, loadedScope == scope {
                    if isCourse { courseSections(configuration, scope: scope) }
                    else {
                        credentialsSection(configuration, scope: scope)
                        promptSection(configuration, scope: scope)
                    }
                } else {
                    Section {
                        if loading { ProgressView(WorkspaceLocalization.string("正在加载…")) }
                        else { Button(WorkspaceLocalization.string("重新加载"), systemImage: "arrow.clockwise") { startOperation { try await reload(scope: scope) } } }
                    }
                }
            } else {
                Section {
                    Text(store.isDemoMode ? WorkspaceLocalization.string("演示模式不提供真实 API 密钥。") : backend.currentWorkspaceID != nil
                        ? WorkspaceLocalization.string("切换到个人空间后，即可配置 API 接口。") : WorkspaceLocalization.string("登录工作坊后，即可配置 API 接口。"))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(isCourse ? WorkspaceLocalization.string("课程 API") : WorkspaceLocalization.string("AI 连接"))
        .workspaceInlineTitle()
        .task(id: backend.accountIdentityScope) {
            clearPage()
            guard !store.isDemoMode, backend.currentWorkspaceID == nil, let scope = backend.accountIdentityScope else { return }
            loading = true
            defer { if backend.accountIdentityScope == scope { loading = false } }
            do { try await reload(scope: scope) }
            catch { showError(error, scope: scope) }
        }
        .sheet(item: $connectionDraft, onDismiss: {
            guard let scope = store.backend.accountIdentityScope, loadedScope == scope else { return }
            startOperation { try await reload(scope: scope) }
        }) { draft in
            AIConnectionNameEditor(draft: draft)
                .environment(store)
        }
        .onDisappear { operationTask?.cancel(); operationTask = nil }
        .alert(item: $credentialToRevoke) { credential in
            Alert(title: Text(WorkspaceLocalization.string(isCourse ? "撤销写入密钥？" : "撤销 AI 连接？")), message: Text(isCourse ? WorkspaceLocalization.format("使用“%@”的工具将无法再发布课程。", String(describing: credential.name)) : WorkspaceLocalization.format("使用“%@”的工具将无法再访问日程接口。", String(describing: credential.name))),
                primaryButton: .destructive(Text(WorkspaceLocalization.string("撤销"))) {
                    guard let scope = backend.accountIdentityScope, loadedScope == scope,
                          configuration?.credentials.contains(where: { $0.id == credential.id }) == true else { return }
                    startOperation {
                        try await revokeCredential(credential.id)
                        try await reload(scope: scope)
                        notice = WorkspaceLocalization.string("密钥已撤销")
                    }
                }, secondaryButton: .cancel(Text(WorkspaceLocalization.string("取消"))))
        }
        .workspaceSelectionFeedback(trigger: notice)
    }

    private func courseSections(_ configuration: CalendarTextIntegration, scope: String) -> some View {
        CourseAPISections(configuration: configuration, credentialID: credentialID, busy: busy, notice: notice,
            copyManual: {
                startOperation {
                    let prompt = try await store.backend.manualCoursePrompt(scope: scope)
                    try Task.checkCancellation()
                    guard store.backend.accountIdentityScope == scope else { throw NativeBackendError.configuration }
                    copyPrompt(prompt)
                    notice = WorkspaceLocalization.string("已复制课程制作提示词")
                }
            }, copyAutomatic: {
                startOperation {
                    let prompt = try await store.backend.coursePublishingPrompt(scope: scope)
                    try Task.checkCancellation()
                    guard store.backend.accountIdentityScope == scope else { throw NativeBackendError.configuration }
                    copyPrompt(prompt)
                    notice = WorkspaceLocalization.string("已复制 AI 提示词")
                }
            }, create: {
                startOperation {
                    try await createCredential()
                    try await reload(scope: scope)
                    notice = WorkspaceLocalization.string("密钥已创建")
                }
            }, revoke: { credentialToRevoke = $0 })
    }

    private func credentialsSection(_ configuration: CalendarTextIntegration, scope: String) -> some View {
        Section {
            ForEach(configuration.credentials) { credential in
                connectionRow(credential, scope: scope)
            }
            if configuration.credentials.isEmpty {
                Text(WorkspaceLocalization.string("还没有 AI 连接")).foregroundStyle(.secondary)
            }
            Button(WorkspaceLocalization.string("创建 AI 连接"), systemImage: "plus") {
                connectionDraft = AIConnectionDraft(scope: scope)
            }
            .disabled(busy || configuration.credentials.count >= 10)
            .accessibilityIdentifier("calendar-api-create-connection")
        } header: {
            Text(WorkspaceLocalization.string("已授权的连接"))
        } footer: {
            Text(WorkspaceLocalization.string("连接可读取项目组、添加项目组和日程。每个 AI 请使用独立连接；暂停可恢复，撤销后需重新创建。"))
        }
    }

    private func connectionRow(_ credential: CalendarTextCredential, scope: String) -> some View {
        let enabled = credential.enabled ?? true
        let canCopy = store.backend.canCopyCalendarTextCredential(credential.id)
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: enabled ? "link" : "pause.circle")
                .foregroundStyle(.secondary).frame(width: 24).padding(.top, 3)
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(credential.name).font(.body.weight(.medium))
                    if !enabled {
                        Text(WorkspaceLocalization.string("已暂停")).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text(lastUseDescription(credential))
                    .font(.caption).foregroundStyle(.secondary)
                Text(WorkspaceLocalization.format("到期 %@", credential.expirationDate.formatted(.dateTime.year().month(.abbreviated).day().locale(WorkspaceLocalization.locale))))
                    .font(.caption).foregroundStyle(.secondary)
                if canCopy {
                    Button(WorkspaceLocalization.string("复制 AI 提示词"), systemImage: "doc.on.doc") {
                        copyConnectionPrompt(credential, scope: scope)
                    }
                    .buttonStyle(.borderless).font(.subheadline)
                    .disabled(busy || !enabled)
                } else {
                    Text(WorkspaceLocalization.string("提示词仅可在创建此连接的设备复制"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            Menu {
                Button(WorkspaceLocalization.string("重命名"), systemImage: "pencil") {
                    connectionDraft = AIConnectionDraft(scope: scope, credential: credential)
                }
                Button(WorkspaceLocalization.string(enabled ? "暂停连接" : "恢复连接"), systemImage: enabled ? "pause" : "play") {
                    startOperation {
                        try await store.backend.updateCalendarTextCredential(credential.id, name: credential.name, enabled: !enabled)
                        try await reload(scope: scope)
                        notice = WorkspaceLocalization.string(enabled ? "连接已暂停" : "连接已恢复")
                    }
                }
                Button(WorkspaceLocalization.string("撤销连接"), systemImage: "trash", role: .destructive) {
                    credentialToRevoke = credential
                }
            } label: {
                Image(systemName: "ellipsis").frame(width: 44, height: 36).contentShape(Rectangle())
            }
            .disabled(busy)
            .accessibilityLabel(WorkspaceLocalization.format("管理%@", credential.name))
        }
        .padding(.vertical, 5)
    }

    private func lastUseDescription(_ credential: CalendarTextCredential) -> String {
        guard let lastUsed = credential.lastUsed else { return WorkspaceLocalization.string("尚未使用") }
        return WorkspaceLocalization.format("最近使用 %@", Date(timeIntervalSince1970: lastUsed / 1000).formatted(.dateTime.month().day().hour().minute().locale(WorkspaceLocalization.locale)))
    }

    private func copyConnectionPrompt(_ credential: CalendarTextCredential, scope: String) {
        startOperation {
            let prompt = try await store.backend.calendarTextPrompt(scope: scope, credentialID: credential.id)
            try Task.checkCancellation()
            guard store.backend.accountIdentityScope == scope else { throw NativeBackendError.configuration }
            copyPrompt(prompt)
            notice = WorkspaceLocalization.format("已复制“%@”的提示词", credential.name)
        }
    }

    @ViewBuilder private func promptSection(_ configuration: CalendarTextIntegration, scope: String) -> some View {
        Section {
            if let notice { Label(notice, systemImage: "checkmark.circle").font(.footnote).foregroundStyle(.secondary) }
            NavigationLink(WorkspaceLocalization.string("格式与调用说明")) { APIProtocolReferenceView(prompt: configuration.prompt) }
        } footer: {
            Text(WorkspaceLocalization.string("提示词包含此连接的密钥，请仅交给你信任的工具。无需提供登录密码。"))
        }
    }

    private func reload(scope: String) async throws {
        let result = try await (isCourse ? store.backend.courseIntegration() : store.backend.calendarTextIntegration())
        try Task.checkCancellation()
        guard store.backend.accountIdentityScope == scope, store.backend.currentWorkspaceID == nil, !store.isDemoMode else { throw NativeBackendError.configuration }
        configuration = result
        loadedScope = scope
    }

    private func clearPage() {
        operationTask?.cancel()
        operationTask = nil
        configuration = nil
        loadedScope = nil
        credentialToRevoke = nil
        connectionDraft = nil
        notice = nil
        busy = false
    }

    private func startOperation(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !busy, !store.isDemoMode, store.backend.currentWorkspaceID == nil, let scope = store.backend.accountIdentityScope else { return }
        busy = true
        notice = nil
        operationTask = Task { @MainActor in
            defer { if store.backend.accountIdentityScope == scope { busy = false } }
            do {
                try Task.checkCancellation()
                guard store.backend.accountIdentityScope == scope else { throw NativeBackendError.configuration }
                try await operation()
            }
            catch { showError(error, scope: scope) }
        }
    }

    private func showError(_ error: Error, scope: String) {
        guard !(error is CancellationError), !Task.isCancelled, store.backend.accountIdentityScope == scope else { return }
        store.errorMessage = error.localizedDescription
    }

    private func copyPrompt(_ prompt: String) {
        #if os(iOS)
        UIPasteboard.general.setItems([["public.utf8-plain-text": prompt]], options: [
            .localOnly: true, .expirationDate: Date().addingTimeInterval(5 * 60)
        ])
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(prompt, forType: .string)
        #endif
    }
    private var isCourse: Bool { integrationKind == .course }
    private var credentialID: String? { isCourse ? store.backend.courseCredentialID : store.backend.calendarTextCredentialID }
    private func createCredential() async throws {
        if isCourse { try await store.backend.createCourseCredential() }
        else { try await store.backend.createCalendarTextCredential() }
    }
    private func revokeCredential(_ id: String) async throws {
        if isCourse { try await store.backend.revokeCourseCredential(id) }
        else { try await store.backend.revokeCalendarTextCredential(id) }
    }

}

private struct AIConnectionDraft: Identifiable {
    let id = UUID()
    let scope: String
    var credential: CalendarTextCredential?
}

private struct AIConnectionNameEditor: View {
    let draft: AIConnectionDraft
    @Environment(WorkspaceStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var saving = false
    @State private var failure: String?
    @State private var saveTask: Task<Void, Never>?

    init(draft: AIConnectionDraft) {
        self.draft = draft
        _name = State(initialValue: draft.credential?.name ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(WorkspaceLocalization.string("例如：我的 ChatGPT"), text: $name)
                        .onChange(of: name) { _, value in
                            if value.count > 60 { name = String(value.prefix(60)) }
                        }
                        .accessibilityIdentifier("calendar-api-connection-name")
                } header: {
                    Text(WorkspaceLocalization.string("连接名称"))
                } footer: {
                    Text(WorkspaceLocalization.string("使用容易辨认的名字，方便以后暂停或撤销。"))
                }
                if let failure { Section { Text(failure).foregroundStyle(.red) } }
            }
            .formStyle(.grouped)
            .navigationTitle(WorkspaceLocalization.string(draft.credential == nil ? "创建 AI 连接" : "重命名连接"))
            .workspaceInlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(WorkspaceLocalization.string("取消")) { dismiss() }.disabled(saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(WorkspaceLocalization.string(saving ? "正在保存…" : "完成")) { save() }
                        .disabled(saving || trimmedName.isEmpty)
                }
            }
        }
        .interactiveDismissDisabled(saving)
        .onChange(of: store.backend.accountIdentityScope) { _, scope in
            if scope != draft.scope { saveTask?.cancel(); dismiss() }
        }
        .onDisappear { saveTask?.cancel() }
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func save() {
        guard !saving, !trimmedName.isEmpty, store.backend.accountIdentityScope == draft.scope,
              !store.isDemoMode, store.backend.currentWorkspaceID == nil else { return }
        saving = true
        failure = nil
        let newName = trimmedName
        saveTask = Task { @MainActor in
            defer { saving = false }
            do {
                if let credential = draft.credential {
                    try await store.backend.updateCalendarTextCredential(credential.id, name: newName, enabled: credential.enabled ?? true)
                } else {
                    try await store.backend.createCalendarTextCredential(name: newName)
                }
                try Task.checkCancellation()
                guard store.backend.accountIdentityScope == draft.scope else { return }
                dismiss()
            } catch {
                guard !(error is CancellationError), !Task.isCancelled,
                      store.backend.accountIdentityScope == draft.scope else { return }
                failure = error.localizedDescription
            }
        }
    }
}

/// Presentation only; credential operations remain owned by TextImportSettingsView.
private struct CourseAPISections: View {
    @Environment(\.workspacePalette) private var palette
    let configuration: CalendarTextIntegration
    let credentialID: String?
    let busy: Bool
    let notice: String?
    let copyManual: () -> Void
    let copyAutomatic: () -> Void
    let create: () -> Void
    let revoke: (CalendarTextCredential) -> Void

    var body: some View {
        Section {
            methodHeading(WorkspaceLocalization.string("手动制作"), detail: WorkspaceLocalization.string("让 AI 生成课程，再复制回 App。无需密钥。"), symbol: "doc.text")
            Button(action: copyManual) {
                actionLabel(WorkspaceLocalization.string("复制制作提示词"), symbol: "doc.on.doc")
            }
            .buttonStyle(.plain)
            .disabled(busy || configuration.manualPrompt == nil)
            .accessibilityIdentifier("course-api-copy-manual")
            NavigationLink { CoursePasteUploadView() } label: {
                actionLabel(WorkspaceLocalization.string("粘贴课程并上传"), symbol: "doc.on.clipboard")
            }
            .accessibilityIdentifier("course-api-upload")
        }

        Section {
            methodHeading(WorkspaceLocalization.string("自动发布"), detail: WorkspaceLocalization.string("让支持联网的 AI 直接制作并上传课程。"), symbol: "arrow.up.doc")
            ForEach(configuration.credentials) { credential in
                HStack(spacing: 12) {
                    Image(systemName: "key").foregroundStyle(.secondary).frame(width: 24)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(credential.name).font(.body.weight(.medium))
                        Text(WorkspaceLocalization.format("到期 %@", String(describing: credential.expirationDate.formatted(.dateTime.year().month(.abbreviated).day().locale(WorkspaceLocalization.locale)))))
                            .font(.footnote).foregroundStyle(.secondary)
                        if credential.id == credentialID {
                            Text(WorkspaceLocalization.string("已保存在此设备")).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                    Button(role: .destructive) { revoke(credential) } label: {
                        Image(systemName: "trash").frame(width: 44, height: 44).contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless).disabled(busy)
                    .accessibilityLabel(WorkspaceLocalization.format("撤销%@", String(describing: credential.name)))
                }
                .padding(.vertical, 4)
            }
            if credentialID == nil {
                Button(action: create) {
                    actionLabel(WorkspaceLocalization.string("创建发布密钥"), symbol: "key")
                }
                .buttonStyle(.plain).disabled(busy)
                .accessibilityIdentifier("course-api-create-key")
            }
            Button(action: copyAutomatic) {
                actionLabel(WorkspaceLocalization.string("复制自动发布提示词"), symbol: "doc.on.doc")
            }
            .buttonStyle(.plain).disabled(busy || credentialID == nil)
            .accessibilityIdentifier("course-api-copy-automatic")
        } footer: {
            Text(credentialID == nil
                ? WorkspaceLocalization.string("先创建发布密钥，再复制提示词。密钥仅用于发布或更新课程。")
                : WorkspaceLocalization.string("自动发布提示词包含密钥，请仅交给你信任的 AI。可随时撤销密钥。"))
        }

        Section {
            NavigationLink {
                APIProtocolReferenceView(prompt: configuration.prompt)
            } label: {
                actionLabel(WorkspaceLocalization.string("格式与调用说明"), symbol: "curlybraces")
            }
            if let notice {
                Label(notice, systemImage: "checkmark.circle.fill")
                    .font(.footnote).foregroundStyle(.secondary)
                    .accessibilityIdentifier("course-api-notice")
            }
        }
    }

    private func methodHeading(_ title: String, detail: String, symbol: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.title3.weight(.medium))
                .foregroundStyle(palette.accent).frame(width: 42, height: 42)
                .background(palette.surface, in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.headline).foregroundStyle(.primary)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private func actionLabel(_ title: String, symbol: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).frame(width: 24)
            Text(title).font(.body.weight(.medium))
        }
        .foregroundStyle(palette.accent)
        .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
        .contentShape(Rectangle())
    }
}

/// Keep long protocol text out of the settings form until it is requested.
private struct APIProtocolReferenceView: View {
    let prompt: String
    var body: some View {
        ScrollView {
            Text(prompt)
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: 900, alignment: .leading)
                .padding(20).frame(maxWidth: .infinity)
        }
        .navigationTitle(WorkspaceLocalization.string("格式与调用说明")).workspaceInlineTitle()
    }
}

#Preview("课程 API · 未配置") {
    NavigationStack {
        Form {
            CourseAPISections(configuration: CalendarTextIntegration(credentials: [], endpoint: "", protocolVersion: "WORKSHOP-COURSE/1",
                prompt: "WORKSHOP-COURSE/1", manualPrompt: "制作课程"), credentialID: nil, busy: false, notice: nil,
                copyManual: {}, copyAutomatic: {}, create: {}, revoke: { _ in })
        }
        .formStyle(.grouped).navigationTitle(WorkspaceLocalization.string("课程 API")).workspaceInlineTitle()
    }
}

#Preview("课程 API · 已配置") {
    NavigationStack {
        Form {
            CourseAPISections(configuration: CalendarTextIntegration(credentials: [CalendarTextCredential(id: "preview", name: "我的 iPhone",
                created: 0, expires: 1_814_716_800_000, lastUsed: nil)], endpoint: "", protocolVersion: "WORKSHOP-COURSE/1",
                prompt: "WORKSHOP-COURSE/1", manualPrompt: "制作课程"), credentialID: "preview", busy: false, notice: "已复制 AI 提示词",
                copyManual: {}, copyAutomatic: {}, create: {}, revoke: { _ in })
        }
        .formStyle(.grouped).navigationTitle(WorkspaceLocalization.string("课程 API")).workspaceInlineTitle()
    }
}

extension View {
    @ViewBuilder func nativeEmailInput() -> some View {
        #if os(iOS)
        self.keyboardType(.emailAddress).textInputAutocapitalization(.never).textContentType(.username)
        #else
        self
        #endif
    }
}

private struct LinkedAccountsSettingsView: View {
    @Environment(WorkspaceStore.self) private var store
    @State private var sharing: LinkedAccountSharing?
    @State private var email = ""
    @State private var invitationRole = "editor"
    @State private var busy = false
    @State private var failure: String?
    @State private var memberToRemove: LinkedAccountSharing.Member?
    @State private var workspaceToLeave: LinkedAccountSharing.Workspace?

    var body: some View {
        Form {
            if let sharing {
                workspaceSection(sharing)
                if !sharing.incoming.isEmpty { incomingSection(sharing) }
                inviteSection
                if !sharing.members.isEmpty { membersSection(sharing) }
                if !sharing.outgoing.isEmpty { outgoingSection(sharing) }
            } else if busy {
                Section { ProgressView(WorkspaceLocalization.string("正在加载…")) }
            } else {
                Section { Button(WorkspaceLocalization.string("重新加载"), systemImage: "arrow.clockwise") { run { try await reload() } } }
            }
            if let failure { Section { Text(failure).foregroundStyle(.red) } }
        }
        .formStyle(.grouped)
        .navigationTitle(WorkspaceLocalization.string("关联账户"))
        .workspaceInlineTitle()
        .disabled(busy || store.syncing)
        .task(id: store.backend.accountIdentityScope) {
            sharing = nil
            guard store.backend.signedIn, !store.isDemoMode else { return }
            busy = true
            defer { busy = false }
            do { try await reload() } catch { show(error) }
        }
        .confirmationDialog(WorkspaceLocalization.string("移除此账户的共享权限？"), isPresented: Binding(get: { memberToRemove != nil }, set: { if !$0 { memberToRemove = nil } }), titleVisibility: .visible) {
            if let member = memberToRemove {
                Button(WorkspaceLocalization.string("移除关联"), role: .destructive) {
                    memberToRemove = nil
                    run { try await change("member", method: "DELETE", values: ["id": member.id]) }
                }
            }
        } message: { Text(WorkspaceLocalization.string("对方将无法继续查看或修改你的共享空间。")) }
        .confirmationDialog(WorkspaceLocalization.string("退出这个共享空间？"), isPresented: Binding(get: { workspaceToLeave != nil }, set: { if !$0 { workspaceToLeave = nil } }), titleVisibility: .visible) {
            if let workspace = workspaceToLeave, let membershipID = workspace.membershipID {
                Button(WorkspaceLocalization.string("退出共享"), role: .destructive) {
                    workspaceToLeave = nil
                    run {
                        try await store.selectLinkedWorkspace(id: nil, role: "owner")
                        try await change("member", method: "DELETE", values: ["id": membershipID])
                    }
                }
            }
        } message: { Text(WorkspaceLocalization.string("退出后，将无法继续访问此共享空间；个人空间中的副本保留。")) }
    }

    private func workspaceSection(_ data: LinkedAccountSharing) -> some View {
        Section(WorkspaceLocalization.string("当前空间")) {
            Button {
                run { try await store.selectLinkedWorkspace(id: nil, role: "owner") }
            } label: {
                workspaceRow(WorkspaceLocalization.string("个人空间"), role: "owner", selected: store.backend.currentWorkspaceID == nil)
            }
            ForEach(data.workspaces.filter { $0.id != data.ownedWorkspaceID }) { workspace in
                Button {
                    run { try await store.selectLinkedWorkspace(id: workspace.id, role: workspace.role) }
                } label: {
                    workspaceRow(workspace.ownerEmail, role: workspace.role, selected: store.backend.currentWorkspaceID == workspace.id)
                }
                if workspace.membershipID != nil {
                    Button(WorkspaceLocalization.string("退出此共享空间"), role: .destructive) { workspaceToLeave = workspace }
                }
            }
        }
    }

    private func workspaceRow(_ title: String, role: String, selected: Bool) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).foregroundStyle(.primary)
                if role != "owner" { Text(roleTitle(role)).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            if selected { Image(systemName: "checkmark").foregroundStyle(.tint).accessibilityLabel(WorkspaceLocalization.string("当前空间")) }
        }
    }

    private func incomingSection(_ data: LinkedAccountSharing) -> some View {
        Section {
            ForEach(data.incoming) { invitation in
                VStack(alignment: .leading, spacing: 12) {
                    Text(invitation.ownerEmail).font(.headline)
                    Text(roleTitle(invitation.role)).font(.subheadline).foregroundStyle(.secondary)
                    HStack {
                        Button(WorkspaceLocalization.string("接受")) {
                            run {
                                let identity = store.backend.accountIdentityScope
                                if store.backend.currentWorkspaceID != nil { try await store.selectLinkedWorkspace(id: nil, role: "owner") }
                                try await store.synchronize(bindAccount: true)
                                guard store.backend.accountIdentityScope == identity else { throw CancellationError() }
                                guard store.pendingSyncReview == nil else { throw WorkspaceFailure.invalid(WorkspaceLocalization.string("请先处理云同步冲突，再接受邀请。")) }
                                try await change("accept", values: ["id": invitation.id])
                                try await store.selectLinkedWorkspace(id: invitation.workspaceID, role: invitation.role)
                            }
                        }.buttonStyle(.borderedProminent)
                        Button(WorkspaceLocalization.string("拒绝"), role: .destructive) { run { try await change("decline", values: ["id": invitation.id]) } }.buttonStyle(.bordered)
                    }
                }.padding(.vertical, 4)
            }
        } header: { Text(WorkspaceLocalization.string("收到的邀请")) } footer: {
            Text(WorkspaceLocalization.string("接受后，双方现有事项会合并共享；个人空间保留副本。"))
        }
    }

    private var inviteSection: some View {
        Section {
            TextField(WorkspaceLocalization.string("对方账号（邮箱）"), text: $email).nativeEmailInput().autocorrectionDisabled()
            Picker(WorkspaceLocalization.string("允许对方"), selection: $invitationRole) {
                Text(WorkspaceLocalization.string("共同编辑")).tag("editor")
                Text(WorkspaceLocalization.string("只读")).tag("viewer")
            }
            Button(WorkspaceLocalization.string("发送邀请"), systemImage: "paperplane") {
                run {
                    try await change("invitations", values: ["email": email.trimmingCharacters(in: .whitespacesAndNewlines), "role": invitationRole])
                    email = ""
                }
            }.disabled(email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } header: { Text(WorkspaceLocalization.string("邀请加入我的空间")) } footer: {
            Text(WorkspaceLocalization.string("共同编辑允许新增、修改和删除；只读仅可查看。"))
        }
    }

    private func membersSection(_ data: LinkedAccountSharing) -> some View {
        Section(WorkspaceLocalization.string("我的共享成员")) {
            ForEach(data.members) { member in
                VStack(alignment: .leading, spacing: 8) {
                    Text(member.email)
                    HStack {
                        Menu(roleTitle(member.role)) {
                            Button(WorkspaceLocalization.string("共同编辑")) { run { try await change("permission", values: ["id": member.id, "role": "editor"]) } }
                            Button(WorkspaceLocalization.string("只读")) { run { try await change("permission", values: ["id": member.id, "role": "viewer"]) } }
                        }
                        Spacer()
                        Button(WorkspaceLocalization.string("移除"), role: .destructive) { memberToRemove = member }
                    }.font(.subheadline)
                }.padding(.vertical, 4)
            }
        }
    }

    private func outgoingSection(_ data: LinkedAccountSharing) -> some View {
        Section(WorkspaceLocalization.string("已发出的邀请")) {
            ForEach(data.outgoing.filter { $0.status == "pending" }) { invitation in
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(invitation.email)
                        Text(roleTitle(invitation.role)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(WorkspaceLocalization.string("撤回"), role: .destructive) { run { try await change("invitation", method: "DELETE", values: ["id": invitation.id]) } }
                }
            }
        }
    }

    private func roleTitle(_ role: String) -> String { role == "editor" ? WorkspaceLocalization.string("共同编辑") : WorkspaceLocalization.string("只读") }
    private func reload() async throws {
        let identity = store.backend.accountIdentityScope
        let result = try await store.backend.linkedAccountSharing()
        guard identity == store.backend.accountIdentityScope else { throw CancellationError() }
        sharing = result
    }
    private func change(_ action: String, method: String = "POST", values: [String: String]) async throws {
        try await store.backend.changeLinkedAccountSharing(action: action, method: method, values: values)
        try await reload()
    }
    private func run(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true; failure = nil
        let identity = store.backend.accountIdentityScope
        Task { @MainActor in
            defer { busy = false }
            do {
                guard identity == store.backend.accountIdentityScope else { return }
                try await operation()
            } catch { if identity == store.backend.accountIdentityScope { show(error) } }
        }
    }
    private func show(_ error: Error) {
        if !(error is CancellationError), !Task.isCancelled { failure = error.localizedDescription }
    }
}
