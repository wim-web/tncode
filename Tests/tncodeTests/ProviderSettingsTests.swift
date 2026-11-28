import XCTest
@testable import tncode

@MainActor
final class ProviderSettingsTests: XCTestCase {
    private func makeModel(_ workspace: Workspace) throws -> (WorkspaceModel, URL) {
        let root = FileManager.default.temporaryDirectory.appending(path: "provider-settings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let index = root.appendingPathComponent(WorkspaceStore.indexName)
        try JSONEncoder().encode(workspace).write(to: index)
        let model = WorkspaceModel(root: root, keychainService: "dev.tncode.provider-settings-test",
                                   piAgentDirectory: root.appendingPathComponent("pi"),
                                   credentialExists: { $0 == Provider.anthropic.rawValue },
                                   readCredential: { _ in nil })
        XCTAssertNil(model.startupFailure)
        return (model, root)
    }

    func testPreferencesSaveOnlyWhatDiffersFromDefaults() throws {
        let (model, root) = try makeModel(Workspace(model: .codex, welcomeCompleted: true))
        defer { try? FileManager.default.removeItem(at: root) }
        try model.updateProviderPreferences(.codexAgent) {
            $0.enabled = true
            $0.displayName = "  "
            $0.binaryPath = " /opt/codex "
            $0.customModels = []
        }
        XCTAssertEqual(model.workspace.providers, [Provider.codexAgent.rawValue: ProviderPreferences(binaryPath: "/opt/codex")])
        XCTAssertEqual(CodexRuntimeEnvironment.preferences.binaryPath, "/opt/codex")
        var environment: [String: String] = [:]
        CodexRuntimeEnvironment.apply(to: &environment)
        XCTAssertEqual(environment["TNCODE_CODEX_BIN"], "/opt/codex")
        XCTAssertNil(environment["CODEX_HOME"])

        try model.updateProviderPreferences(.codexAgent) { $0 = $0.withoutCustomizations }
        XCTAssertNil(model.workspace.providers)
        let saved = try JSONDecoder().decode(Workspace.self, from: Data(contentsOf: root.appendingPathComponent(WorkspaceStore.indexName)))
        XCTAssertNil(saved.providers)
    }

    func testCustomModelsJoinThePickerAndDisabledInstancesLeaveIt() throws {
        let (model, root) = try makeModel(Workspace(model: .codex, welcomeCompleted: true))
        defer { try? FileManager.default.removeItem(at: root) }
        try model.updateProviderPreferences(.anthropic) {
            $0.customModels = ["claude-custom"]
            $0.displayName = "Work Anthropic"
        }
        try model.updateProviderPreferences(.local) {
            $0.customModels = ["llama-a"]
            $0.endpoint = "http://127.0.0.1:9999/v1"
        }
        var options = model.defaultModelOptions(current: model.workspace.model)
        let anthropic = try XCTUnwrap(options.first { $0.settings.provider == .anthropic && $0.settings.model == "claude-custom" })
        XCTAssertEqual(anthropic.detail, "Work Anthropic")
        XCTAssertNil(anthropic.unavailableReason)
        let local = try XCTUnwrap(options.first { $0.settings.provider == .local && $0.settings.model == "llama-a" })
        XCTAssertEqual(local.settings.endpoint, "http://127.0.0.1:9999/v1")

        try model.updateProviderPreferences(.anthropic) { $0.enabled = false }
        options = model.defaultModelOptions(current: model.workspace.model)
        XCTAssertFalse(options.contains { $0.settings.provider == .anthropic })
        XCTAssertEqual(model.providerStatus(.anthropic).key, .disabled)
        // The model in use stays listed even when its instance is turned off.
        try model.updateProviderPreferences(.codexAgent) { $0.enabled = false }
        XCTAssertTrue(model.defaultModelOptions(current: model.workspace.model).contains { $0.settings.provider == .codexAgent })
    }

    func testStatusFollowsTheInstanceCredentials() throws {
        let (model, root) = try makeModel(Workspace(model: .codex, welcomeCompleted: true))
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(model.providerStatus(.anthropic).key, .ready)
        XCTAssertEqual(model.providerStatus(.openai).key, .warning)
        XCTAssertEqual(model.providerStatus(.piCopilot).key, .warning)
        XCTAssertEqual(model.providerStatus(.local).key, .ready)
        XCTAssertEqual(model.providerStatus(.codexAgent).key, .warning)
        model.setCodexAccountStatus(.notInstalled)
        XCTAssertEqual(model.providerStatus(.codexAgent).key, .error)
    }

    func testDefaultToolPermissionAppliesToNewProjectsOnly() throws {
        let existing = Project(id: UUID(), path: "/tmp", title: "Existing")
        let (model, root) = try makeModel(Workspace(projects: [existing], model: .codex, welcomeCompleted: true))
        defer { try? FileManager.default.removeItem(at: root) }
        try model.updateDefaultToolPermission(.supervised)
        XCTAssertEqual(model.workspace.defaultToolPermission, .supervised)
        XCTAssertEqual(model.workspace.projects.first?.toolPermission, .readFiles)
        try model.updateToolPermission(.shellAndEdits, forProject: existing.id)
        XCTAssertEqual(model.workspace.projects.first?.toolPermission, .shellAndEdits)
        try model.updateDefaultToolPermission(.readFiles)
        XCTAssertNil(model.workspace.defaultToolPermission)
    }

    func testCheckedTimeReadsLikeT3Code() {
        let now = Date()
        XCTAssertEqual(ProviderCheckedTime.text(since: now.addingTimeInterval(-10), now: now), "just now")
        XCTAssertEqual(ProviderCheckedTime.text(since: now.addingTimeInterval(-125), now: now), "2m ago")
        XCTAssertEqual(ProviderCheckedTime.text(since: now.addingTimeInterval(-7200), now: now), "2h ago")
    }

    func testHexColorsRoundTripThroughHSV() {
        for hex in ["#2563eb", "#ff0000", "#00ff00", "#123456", "#000000", "#ffffff"] {
            XCTAssertEqual(HSV(hex: hex)?.hex, hex)
        }
        XCTAssertNil(HSV(hex: "2563eb"))
    }
}
