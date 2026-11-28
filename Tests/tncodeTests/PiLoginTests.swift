import XCTest
@testable import tncode

@MainActor
final class PiLoginTests: XCTestCase {
    func testPiBrowserSignInSelectsAccountAndSendsFirstMessage() async throws {
        let env = ProcessInfo.processInfo.environment
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sidecar")
        let worker = env["PI_ROUTING_WORKER"].map { URL(fileURLWithPath: $0) } ?? source.appendingPathComponent("worker.mjs")
        let login = worker.deletingLastPathComponent().appendingPathComponent("login.mjs")
        let nodePath = env["PI_ROUTING_NODE"] ?? (env["PATH"] ?? "").split(separator: ":")
            .map { String($0) + "/node" }.first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let nodePath, FileManager.default.fileExists(atPath: source.appendingPathComponent("node_modules").path) else {
            throw XCTSkip("The sign-in test requires Node and the pinned Sidecar dependencies.")
        }
        let node = URL(fileURLWithPath: nodePath)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let logins = PiSavedLogins(directory: root.appendingPathComponent("new-account"))
        let callbackFile = root.appendingPathComponent("test-browser-callback")
        let envFile = root.appendingPathComponent("fixture.env")
        let model = WorkspaceModel(root: root.appendingPathComponent("workspace"), keychainService: "unused",
                                   piAgentDirectory: logins.directory, credentialExists: { _ in false },
                                   readCredential: { _ in XCTFail("Unexpected Keychain read"); return nil },
                                   makeProcess: { config, cwd in
            try PiProcess(config: config, cwd: cwd, executable: node,
                          arguments: ["--env-file", envFile.path, "--import", source.appendingPathComponent("fixtures/saved-login-upstream.mjs").path, worker.path],
                          loginDirectory: logins.directory)
        })
        defer { _ = model.terminate() }
        var draft = ModelSettingsDraft(workspace: model.workspace.model, project: nil, signingIn: true)
        XCTAssertEqual(draft.settings.provider, .codexAgent)
        draft.settings = ModelSettings(provider: .piCodex, model: Provider.piCodex.defaultModel)
        let variables = "TNCODE_LOGIN_FIXTURE_CALLBACK_FILE=\(callbackFile.path)\nTNCODE_OAUTH_FIXTURE_MODEL=\(draft.settings.model)\n"
        try Data(variables.utf8).write(to: envFile)

        var browserURLs: [URL] = []
        let signIn = ProviderSignIn(makeHelper: { directory in
            try ProviderSignIn.Helper(config: directory, cwd: directory.path, executable: node,
                                      arguments: ["--env-file", envFile.path, "--import", source.appendingPathComponent("fixtures/login-upstream.mjs").path, login.path],
                                      loginDirectory: directory)
        }, openBrowser: { browserURLs.append($0); return true }, deviceID: { UUID() })
        defer { signIn.cancel() }
        var applications = 0
        func start() {
            signIn.start(draft.settings.provider, logins: logins) { profile in
                draft.useAccount(profile)
                do {
                    try model.applySettings(draft.settings, in: draft.scope, newKey: draft.key, removeKey: draft.removeKey)
                    applications += 1
                } catch { XCTFail(error.localizedDescription) }
            }
        }
        func wait(for check: () -> Bool) async throws {
            for _ in 0..<400 {
                if let error = signIn.error ?? model.error { throw WorkspaceError(error) }
                if check() { return }
                try await Task.sleep(for: .milliseconds(25))
            }
            throw WorkspaceError("Timed out waiting for the test sign-in.")
        }

        XCTAssertTrue(logins.profiles().isEmpty)
        start()
        try await wait { browserURLs.count == 1 && signIn.instructions?.prompt != nil }
        XCTAssertEqual(browserURLs[0].host, "auth.openai.com")
        let previousPrompt = try XCTUnwrap(signIn.instructions?.prompt)
        signIn.cancel()
        XCTAssertNil(signIn.instructions)
        XCTAssertEqual(applications, 0)
        XCTAssertTrue(logins.profiles().isEmpty)

        start()
        try await wait { browserURLs.count == 2 && signIn.instructions?.prompt != nil }
        signIn.answer(previousPrompt, with: "cancelled-login-response")
        XCTAssertNotNil(signIn.instructions?.prompt)
        let callback = try XCTUnwrap(URL(string: String(contentsOf: callbackFile, encoding: .utf8)))
        guard callback.scheme == "http", callback.host == "127.0.0.1", callback.port != nil else {
            XCTFail("Expected the test helper’s loopback callback.")
            return
        }
        let state = URLComponents(url: browserURLs[1], resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "state" }?.value
        XCTAssertNotNil(state)
        XCTAssertEqual(URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "state" }?.value, state)
        let browser = URLSession(configuration: .ephemeral)
        defer { browser.invalidateAndCancel() }
        let (_, response) = try await browser.data(from: callback)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        try await wait { applications == 1 }
        XCTAssertNil(signIn.instructions)
        XCTAssertEqual(model.effectiveModel, draft.settings)
        XCTAssertTrue(model.hasCredential(for: draft.settings))
        try model.openProject(project)
        try await wait { model.phase == .ready }
        model.draft = "First message after browser sign-in"
        model.send()
        try await wait { model.phase == .ready && model.messages.count == 2 }
        XCTAssertEqual(model.messages.map(\.text), ["First message after browser sign-in", "Saved Pi login reply."])
    }

    func testExistingWorkspaceKeepsItsProviderAndPiLoginsRemainSelectable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let agent = root.appendingPathComponent("agent")
        try FileManager.default.createDirectory(at: agent, withIntermediateDirectories: true)
        let auth = agent.appendingPathComponent("auth.json")
        let saved = #"{"openai":{"type":"api_key","key":"fixture-key"},"anthropic":{"type":"oauth","access":"a","refresh":"r","expires":1},"openai-codex":{"type":"oauth","access":"a","refresh":"r","expires":1,"accountId":"first"}}"#
        try Data(saved.utf8).write(to: auth)
        try Data(#"{"defaultProvider":"openai-codex","defaultModel":"my-model","defaultThinkingLevel":"high"}"#.utf8)
            .write(to: agent.appendingPathComponent("settings.json"))

        let fresh = WorkspaceModel(root: root.appendingPathComponent("new"), keychainService: "test",
                                   piAgentDirectory: agent)
        XCTAssertEqual(fresh.effectiveModel, .codex)
        let route = try XCTUnwrap(fresh.piLogins.profiles().first)
        XCTAssertEqual(route.provider, .piCodex)
        XCTAssertEqual(route.model, "my-model")
        XCTAssertEqual(route.thinkingLevel, .high)
        XCTAssertEqual(fresh.piLogins.profiles().map(\.provider), [.piCodex, .piAnthropic])
        XCTAssertTrue(fresh.hasCredential(for: route))
        try Data(saved.replacingOccurrences(of: "first", with: "second").utf8).write(to: auth)
        XCTAssertFalse(fresh.hasCredential(for: route))

        let old = root.appendingPathComponent("existing")
        let original = ModelSettings(provider: .openai, model: "gpt-5-mini")
        try WorkspaceStore(root: old).save(.init(model: original))
        let existing = WorkspaceModel(root: old, keychainService: "test", piAgentDirectory: agent)
        XCTAssertEqual(existing.effectiveModel, original)
        try FileManager.default.removeItem(at: auth)
        XCTAssertTrue(existing.piLogins.profiles().isEmpty)
    }

    func testSendFromNewProjectThroughSavedLoginAndReopenHistory() async throws {
        let environment = ProcessInfo.processInfo.environment
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sidecar")
        let node = environment["PI_ROUTING_NODE"] ?? (environment["PATH"] ?? "").split(separator: ":")
            .map { String($0) + "/node" }.first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let node, FileManager.default.fileExists(atPath: source.appendingPathComponent("node_modules").path) else {
            throw XCTSkip("The saved-login wire test requires Node and the pinned Sidecar dependencies.")
        }
        let worker = environment["PI_ROUTING_WORKER"] ?? source.appendingPathComponent("worker.mjs").path
        let fixture = source.appendingPathComponent("fixtures/saved-login-upstream.mjs").path
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let agent = root.appendingPathComponent("agent")
        let project = root.appendingPathComponent("project")
        let workspace = root.appendingPathComponent("workspace")
        for folder in [agent, project] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }

        let setup = Process()
        setup.executableURL = URL(fileURLWithPath: node)
        setup.environment = ["HOME": root.path, "PI_CODING_AGENT_DIR": agent.path]
        setup.arguments = ["--input-type=module", "-e", """
            import { writeFileSync } from "node:fs";
            import { join } from "node:path";
            import { pathToFileURL } from "node:url";
            const { codexCredential, codexModel } = await import(pathToFileURL(process.argv[1]));
            writeFileSync(join(process.argv[2], "auth.json"), JSON.stringify({"openai-codex": codexCredential()}));
            writeFileSync(join(process.argv[2], "settings.json"), JSON.stringify({defaultProvider:"openai-codex",defaultModel:codexModel}));
            """, fixture, agent.path]
        try setup.run()
        setup.waitUntilExit()
        guard setup.terminationStatus == 0 else {
            XCTFail("Could not seed the test Pi login.")
            return
        }

        let savedProfile = try XCTUnwrap(PiSavedLogins(directory: agent).profiles().first)
        try WorkspaceStore(root: workspace).save(.init(model: savedProfile))
        func launch() -> WorkspaceModel {
            WorkspaceModel(root: workspace, keychainService: "unused", piAgentDirectory: agent,
                           credentialExists: { _ in XCTFail("Unexpected Keychain lookup"); return false },
                           readCredential: { _ in XCTFail("Unexpected Keychain read"); return nil },
                           makeProcess: { config, cwd in
                try PiProcess(config: config, cwd: cwd, executable: URL(fileURLWithPath: node),
                              arguments: ["--import", fixture, worker],
                              loginDirectory: PiSavedLogins(directory: agent).directory)
            })
        }
        func wait(_ model: WorkspaceModel, for condition: () -> Bool) async throws {
            for _ in 0..<500 {
                if let error = model.error { throw WorkspaceError(error) }
                if condition() { return }
                try await Task.sleep(for: .milliseconds(30))
            }
            throw WorkspaceError("Timed out waiting for the saved Pi login.")
        }

        let threadID: UUID
        do {
            let model = launch()
            try model.openProject(project)
            try await wait(model) { model.phase == .ready }
            threadID = try XCTUnwrap(model.conversation?.id)
            XCTAssertEqual(model.effectiveModel.provider, .piCodex)
            model.draft = "Hello from my existing Pi login."
            model.send()
            try await wait(model) { model.phase == .ready && model.messages.count == 2 }
            XCTAssertEqual(model.messages.map(\.text), ["Hello from my existing Pi login.", "Saved Pi login reply."])
            XCTAssertEqual(model.conversation?.historyModel?.account, model.effectiveModel.account)
            model.draft = "Keep this follow-up."
            XCTAssertTrue(model.terminate())
        }
        let model = launch()
        model.start()
        defer { _ = model.terminate() }
        try await wait(model) { model.phase == .ready && model.messages.count == 2 }
        XCTAssertEqual(model.conversation?.id, threadID)
        XCTAssertEqual(model.messages.last?.text, "Saved Pi login reply.")
        try FileManager.default.removeItem(at: agent.appendingPathComponent("auth.json"))
        model.send()
        XCTAssertTrue(model.showingSettings)
        XCTAssertEqual(model.draft, "Keep this follow-up.")
        XCTAssertEqual(model.messages.count, 2)
    }
}
