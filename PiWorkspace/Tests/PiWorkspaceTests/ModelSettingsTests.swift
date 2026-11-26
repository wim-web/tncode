import XCTest
@testable import PiWorkspace

final class ModelSettingsTests: XCTestCase {
    @MainActor
    func testLegacySettingsProjectOverrideAndReset() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }

        let a = UUID()
        let b = UUID()
        for name in ["A", "B"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: false)
        }
        let index = root.appendingPathComponent("workspace.json")
        let keychainService = "dev.piworkspace.model-key.fixture.\(root.lastPathComponent)"
        try Data("""
        {
          "projects": [
            {"id":"\(a)","title":"A","path":"\(root.path)/A","allowEdits":false,"conversations":[]},
            {"id":"\(b)","title":"B","path":"\(root.path)/B","allowEdits":false,"conversations":[]}
          ],
          "selectedProject":"\(a)",
          "model":{"provider":"openai","model":"gpt-5-mini","endpoint":"http://127.0.0.1:11434/v1","contextWindow":8192}
        }
        """.utf8).write(to: index)

        do {
            let model = WorkspaceModel(root: root, keychainService: keychainService)
            try expect(model.error == nil && model.project?.modelOverride == nil, "Legacy project inherits on load")
            try expect(model.effectiveModel.model == "gpt-5-mini", "A shows the legacy model")
            try expect(model.effectiveModel.validated().account == "openai", "A inherits the provider account")
            try model.applySettings(model.effectiveModel, in: .project(a), newKey: "", removeKey: false)
            try expect(model.project?.modelOverride == nil, "Saving unchanged inherited values leaves A inheriting")

            let override = ModelSettings(provider: .local, model: " fixture-a ",
                                         endpoint: " http://LOCALHOST:11435/v1// ", contextWindow: 16384,
                                         localTools: true)
            try model.applySettings(override, in: .project(a), newKey: "", removeKey: false)
            try expect(model.effectiveModel.model == "fixture-a" && model.effectiveModel.supportsTools,
                       "A uses its own model and tool capability")
            try expect(model.effectiveModel.contextWindow == 16384, "A uses its own context window")
            try expect(model.effectiveModel.validated().account == "local:http://localhost:11435/v1",
                       "Repeated validation binds A to the same loopback account")

            model.selectProject(b)
            try expect(model.project?.modelOverride == nil && model.effectiveModel.model == "gpt-5-mini",
                       "B still inherits the workspace model")
            try expect(model.effectiveModel.validated().account == "openai", "B still uses the inherited account")
            let newDefault = ModelSettings(provider: .anthropic, model: "claude-sonnet-4-6", thinkingLevel: .high)
            try model.applySettings(newDefault, in: .workspace, newKey: "", removeKey: false)
            try expect(model.effectiveModel == newDefault && model.project?.modelOverride == nil,
                       "Workspace changes reach B through inheritance")
            model.selectProject(a)
            try expect(model.effectiveModel.model == "fixture-a", "Workspace changes leave A’s override intact")
        }

        do {
            let reopened = WorkspaceModel(root: root, keychainService: keychainService)
            try expect(reopened.project?.id == a && reopened.project?.modelOverride != nil, "A’s override survives reloading")
            try expect(reopened.effectiveModel.validated().account == "local:http://localhost:11435/v1",
                       "Reopened A resolves the override’s account")
            reopened.selectProject(b)
            try expect(reopened.project?.modelOverride == nil && reopened.effectiveModel.thinkingLevel == .high,
                       "B inherits the saved thinking level after reloading")
            reopened.selectProject(a)
            try reopened.resetProjectModel(a)
            try reopened.resetProjectModel(a)
            try expect(reopened.project?.modelOverride == nil && reopened.effectiveModel == reopened.workspace.model,
                       "Reset returns A to inheritance and can be repeated")
            try expect(reopened.effectiveModel.validated().account == "anthropic",
                       "Reset rebinds A to the current default provider account")
        }

        let reopened = WorkspaceModel(root: root, keychainService: keychainService)
        try expect(reopened.project?.id == a && reopened.project?.modelOverride == nil &&
                   reopened.effectiveModel.thinkingLevel == .high, "Reset survives reloading")
    }

    private func expect(_ pass: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try pass() else { throw WorkspaceError(message) }
    }
}
