import Foundation
import XCTest
@testable import PiWorkspace

@MainActor
final class PromptLinkDestinationTests: XCTestCase {
    private let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    private var checkout: URL { root.appendingPathComponent("checkout") }
    private var index: URL { root.appendingPathComponent("workspace.json") }
    private let worker = LinkWorker()

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testChangedRemoteRejectsListedProjectAndPreservesDraft() async throws {
        let model = try makeWorkspace()
        let review = try start(model, "repo=fixture/first")
        let before = try Data(contentsOf: index)
        let matches = try await model.matchingPromptLinkProjects(for: review)
        let match = try XCTUnwrap(matches.first)
        try git("remote", "set-url", "origin", "https://github.com/fixture/second.git")
        await assertRejected(model, review, match)
        XCTAssertEqual(try Data(contentsOf: index), before)
        XCTAssertEqual(model.draft, "Keep editing")
        XCTAssertTrue(worker.opens.isEmpty)
    }

    func testMovedAndReplacedFolderRequireANewSelection() async throws {
        let model = try makeWorkspace()
        let review = try start(model, "repo=fixture/first")
        let matches = try await model.matchingPromptLinkProjects(for: review)
        let match = try XCTUnwrap(matches.first)
        let before = try Data(contentsOf: index)
        try FileManager.default.moveItem(at: checkout, to: root.appendingPathComponent("moved"))
        await assertRejected(model, review, match)
        try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: false)
        try git("init", "-q")
        try git("remote", "add", "origin", "git@github.com:fixture/first.git")
        await assertRejected(model, review, match)
        XCTAssertEqual(try Data(contentsOf: index), before)
        let fresh = try await model.matchingPromptLinkProjects(for: review)
        try await model.openPromptLinkDraft(review, in: XCTUnwrap(fresh.first))
        XCTAssertEqual(model.project?.id, match.id)
        XCTAssertEqual(model.draft, "Review me")
        XCTAssertEqual(model.project?.conversations.last?.composerText, "Keep editing")
    }

    func testReviewSupersededDuringConfirmationLookupCannotCommit() async throws {
        var onRead: (() -> Void)?
        let model = try makeWorkspace(makeReader: { path in
            onRead?()
            return GitHubReader(directory: path)
        })
        let review = try start(model, "repo=fixture/first")
        let matches = try await model.matchingPromptLinkProjects(for: review)
        let match = try XCTUnwrap(matches.first)
        let before = try Data(contentsOf: index)
        onRead = {
            model.promptLinkReview = nil
            XCTAssertTrue(model.openPromptLink(URL(string: "pi-workspace://new/v1?prompt=Review+me&repo=fixture/first")!))
        }
        defer { onRead = nil }
        await assertRejected(model, review, match)
        let replacement = try XCTUnwrap(model.promptLinkReview)
        XCTAssertNotEqual(replacement.id, review.id)
        await assertRejected(model, replacement, match)
        XCTAssertFalse(replacement.alreadyOpened)
        XCTAssertEqual(try Data(contentsOf: index), before)
        XCTAssertTrue(worker.opens.isEmpty)
    }

    func testExplicitCloneDestinationPreservesTheParent() async throws {
        let model = try makeWorkspace()
        let parent = try XCTUnwrap(model.project)
        let review = try start(model, "repo=fixture/first")
        let (request, remote) = try model.promptLinkCloneRequest(for: review)
        XCTAssertEqual(remote.argument, "https://github.com/fixture/first.git")
        let destination = root.appendingPathComponent("chosen clone")
        let local = try ProjectCloneRemote(checkout.absoluteString, relativeTo: nil)
        try await model.openProject(.clone(local, destination: destination), request: request)
        XCTAssertEqual(model.project?.path, destination.resolvingSymlinksInPath().path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent(".git/HEAD").path))
        XCTAssertEqual(model.draft, "Review me")
        XCTAssertEqual(model.projects.first?.selectedConversation, parent.selectedConversation)
        XCTAssertEqual(model.projects.first?.conversations.first?.composerText, "Keep editing")
    }

    func testFreshLookupOfCloneThroughLocalMirrorUsesConfiguredForge() async throws {
        let model = try makeWorkspace()
        let remote = "https://github.com/fixture/mirrored.git"
        let rewrite = "url." + checkout.absoluteString + ".insteadOf"
        let clone = root.appendingPathComponent("mirror clone")
        try git("-c", rewrite + "=" + remote, "-c", "protocol.allow=never", "-c", "protocol.file.allow=always",
                "clone", "-q", "--", remote, clone.path)
        try git("-C", clone.path, "config", rewrite, remote)
        try model.openProject(clone)
        let id = try XCTUnwrap(model.project?.id)
        let review = try start(model, "repo=fixture/mirrored")
        let matches = try await model.matchingPromptLinkProjects(for: review)
        XCTAssertEqual(matches.map(\.id), [id])
        let selected = try XCTUnwrap(matches.first)
        try await model.openPromptLinkDraft(review, in: selected)
        XCTAssertEqual(model.draft, "Review me")
        do {
            _ = try await GitHubReader(directory: clone.path).repository()
            XCTFail("General GitHub reads must use the expanded transport")
        } catch GitHubReader.ReadError.noGitHubRemote {}

        // A rewrite to another supported repository takes precedence over the configured URL.
        try git("-C", clone.path, "config", "--unset", rewrite)
        try git("-C", clone.path, "config", "url.https://github.com/fixture/other.git.insteadOf", remote)
        model.promptLinkReview = nil
        let reopened = try start(model, "repo=fixture/mirrored")
        let changed = try await model.matchingPromptLinkProjects(for: reopened)
        XCTAssertTrue(changed.isEmpty)
    }

    func testCatalogHintOpensScratchDraftOnExactModel() throws {
        let model = try makeWorkspace()
        model.connect()
        worker.onEvent?(.modelCatalog([.openai: ["gpt-5-mini": "Mini", "gpt-5": "GPT-5"]]))
        worker.onEvent?(.ready([]))
        let review = try start(model, "provider=openai&model=gpt-5")
        XCTAssertTrue(model.composerModelOptions().contains { $0.settings.model == "gpt-5" && $0.unavailableReason == nil })
        try model.openPromptLinkDraft(review)
        XCTAssertEqual(worker.opens.last?.config.model, "gpt-5")
        XCTAssertEqual(model.conversation?.modelSelection?.model, "gpt-5")
        XCTAssertEqual(model.projects.first?.conversations.first?.composerText, "Keep editing")
    }

    func testUnavailableHintsInheritTheDestinationDefault() throws {
        var hasKey = true
        let model = try makeWorkspace(credentialExists: { _ in hasKey })
        model.connect()
        worker.onEvent?(.modelCatalog([.openai: ["gpt-5": "GPT-5", "gpt-5-mini": "Mini"]]))
        worker.onEvent?(.ready([]))
        for hint in ["provider=openai&model=unknown", "provider=unconfigured&model=gpt-5", "provider=openai&model=gpt-5"] {
            model.promptLinkReview = nil
            if hint == "provider=openai&model=gpt-5" { hasKey = false }
            try model.openPromptLinkDraft(start(model, hint))
            XCTAssertNil(model.conversation?.modelSelection, hint)
            XCTAssertEqual(worker.opens.last?.config, model.workspace.model, hint)
        }
    }

    func testRegisteredProjectResolvesCatalogHintUsingItsProfile() async throws {
        let model = try makeWorkspace()
        let destination = try XCTUnwrap(model.project)
        let profile = ModelSettings(provider: .openai, model: "gpt-5-mini", thinkingLevel: .high)
        try model.applySettings(profile, in: .project(destination.id), newKey: "", removeKey: false)
        try model.openProject(root)
        let foreground = try XCTUnwrap(model.project)
        try model.applySettings(.init(provider: .local, model: "foreground"), in: .project(foreground.id),
                                newKey: "", removeKey: false)
        worker.onEvent?(.modelCatalog([.openai: ["gpt-5-mini": "Mini", "gpt-5": "GPT-5"]]))
        let review = try start(model, "repo=fixture/first&provider=openai&model=gpt-5")
        let matches = try await model.matchingPromptLinkProjects(for: review)
        try await model.openPromptLinkDraft(review, in: XCTUnwrap(matches.first))
        var requested = profile
        requested.model = "gpt-5"
        XCTAssertEqual(worker.opens.last?.config, requested)
        XCTAssertEqual(model.project?.id, destination.id)
        XCTAssertEqual(model.project?.modelOverride, profile)
        XCTAssertEqual(model.projects.last?.selectedConversation, foreground.selectedConversation)
        XCTAssertEqual(model.project?.conversations.last?.composerText, "Keep editing")
    }

    private func assertRejected(_ model: WorkspaceModel, _ review: PromptLinkReview,
                                _ match: PromptLinkProject, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            try await model.openPromptLinkDraft(review, in: match)
            XCTFail("A stale selection committed a draft", file: file, line: line)
        } catch {}
    }

    private func makeWorkspace(
        credentialExists: @escaping (String) -> Bool = { _ in true },
        makeReader: @escaping (String) -> GitHubReader = { GitHubReader(directory: $0) }
    ) throws -> WorkspaceModel {
        try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
        try git("init", "-q")
        try git("remote", "add", "origin", "https://github.com/fixture/first.git")
        let draft = Conversation(id: UUID(), title: "Original", isDraft: true, composerText: "Keep editing")
        let project = Project(id: UUID(), path: checkout.path, title: "Fixture",
                              conversations: [draft], selectedConversation: draft.id)
        try WorkspaceStore(root: root).save(.init(projects: [project], selectedProject: project.id, welcomeCompleted: true))
        return WorkspaceModel(root: root, keychainService: "unused", credentialExists: credentialExists,
                              readCredential: { _ in nil }, makeProcess: { [worker] _, _ in worker }, makeGitHubReader: makeReader)
    }

    private func start(_ model: WorkspaceModel, _ query: String) throws -> PromptLinkReview {
        let url = try XCTUnwrap(URL(string: "pi-workspace://new/v1?prompt=Review+me&" + query))
        XCTAssertTrue(model.openPromptLink(url))
        return try XCTUnwrap(model.promptLinkReview)
    }

    private func git(_ arguments: String...) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", checkout.path] + arguments
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }
}

private final class LinkWorker: PiConnection {
    var onEvent: ((PiEvent) -> Void)?
    var onClose: (() -> Void)?
    var opens = [OpenConversation]()
    func send(_ command: any Encodable) throws {
        if let open = command as? OpenConversation { opens.append(open) }
    }
    func close() {}
}
