import Foundation
import XCTest
@testable import PiWorkspace

final class PromptLinkTests: XCTestCase {
    func testParsesFormEncodedTextAndRepositoryContext() throws {
        let link = try parse("prompt=123+%2B+%25%0A%F0%9F%8C%B1&repo=https%3A%2F%2Fwww.github.com%2FOwner%2FRepo.Git%2F&provider=OpenAI&model=gpt-5-mini")
        XCTAssertEqual(link.prompt, "123 + %\n🌱")
        XCTAssertEqual(link.repository?.slug, "owner/repo")
        XCTAssertEqual(link.modelHint, .init(provider: "openai", model: "gpt-5-mini"))
        XCTAssertFalse(link.removedHiddenCharacters)
        XCTAssertEqual(try parse("prompt=123").prompt, "123")
    }

    func testStripsHiddenCharactersAndPreservesEmojiAndLineBreaks() throws {
        let prompt = " \u{202E}hello\u{200D}there\r\n🧑‍💻\u{2028}end\u{E0061} "
        let query = try XCTUnwrap(prompt.addingPercentEncoding(withAllowedCharacters: .alphanumerics))
        let link = try parse("prompt=" + query)
        XCTAssertEqual(link.prompt, "hellothere\n🧑‍💻\nend")
        XCTAssertTrue(link.removedHiddenCharacters)
    }

    func testParsesOriginalPullRequestParameterFormsInNativeLinks() throws {
        for reference in ["Owner/Repo/42", "owner/repo%2342", "https%3A%2F%2Fwww.github.com%2FOwner%2FRepo.git%2Fpull%2F42%2Ffiles%23diff"] {
            let link = try parse("pr=\(reference)&prompt=Inspect+this&repo=other/repo&provider=openai")
            XCTAssertEqual(link.pullRequest?.url.absoluteString, "https://github.com/owner/repo/pull/42")
            XCTAssertEqual(link.repository?.slug, "owner/repo")
            XCTAssertEqual(link.prompt, "Inspect this")
            XCTAssertNil(link.modelHint)
        }
        XCTAssertEqual(try parse("pr=owner/repo/42").prompt, "")
        XCTAssertEqual(try parse("pr=owner/repo/42&prompt=+").prompt, "")
    }

    func testRejectsMalformedAndHostedCheckoutLinks() throws {
        for query in ["repo=owner/repo", "prompt=%20", "prompt=%E2%80%8B", "prompt=%FF",
                      "prompt=one&prompt=two", "prompt=ok&repo=../repo", "prompt=ok&repo=owner/...",
                      "prompt=ok&repo=file:///tmp/repo", "pr=owner/repo/0", "pr=owner/repo/9007199254740992",
                      "pr=https://github.com.invalid/owner/repo/pull/42", "pr=owner/repo/42&pr=other/repo/42",
                      "pr=owner/repo/42&prompt=%E2%80%8B"] {
            XCTAssertThrowsError(try parse(query), query)
        }
        XCTAssertThrowsError(try parse("prompt=" + String(repeating: "%F0%9F%8C%B1", count: 4_001)))
        for text in ["pi-workspace://new/v2?prompt=ok", "pi-workspace://new:10/v1?prompt=ok",
                     "pi-workspace://user@new/v1?prompt=ok", "pi-workspace://new/v1?prompt=ok#ignored",
                     "pi-workspace://thread/v1?prompt=ok", "https://app.t3.codes/new?prompt=ok"] {
            XCTAssertThrowsError(try PromptLink(url: XCTUnwrap(URL(string: text))), text)
        }
    }

    @MainActor
    func testDuplicateDeliveryAndRelaunchPreserveBothDrafts() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Project")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let original = Conversation(id: UUID(), title: "Original", isDraft: true, composerText: "Keep editing")
        let project = Project(id: UUID(), path: folder.path, title: "Local project",
                              conversations: [original], selectedConversation: original.id)
        let workspace = Workspace(projects: [project], selectedProject: project.id, welcomeCompleted: true)
        try WorkspaceStore(root: root).save(workspace)
        let index = root.appendingPathComponent("workspace.json")
        let before = try Data(contentsOf: index)
        let link = try XCTUnwrap(URL(string: "pi-workspace://new/v1?prompt=Link+draft"))

        let draftID: UUID
        do {
            let model = makeWorkspace(root)
            XCTAssertTrue(model.openPromptLink(link))
            let review = try XCTUnwrap(model.promptLinkReview)
            XCTAssertTrue(model.openPromptLink(link))
            XCTAssertEqual(model.promptLinkReview?.id, review.id)
            XCTAssertEqual(model.conversation?.id, original.id)
            XCTAssertEqual(model.draft, original.composerText)
            XCTAssertEqual(try Data(contentsOf: index), before)

            model.promptLinkReview = nil
            XCTAssertEqual(try Data(contentsOf: index), before)
            XCTAssertThrowsError(try model.openPromptLinkDraft(review))
            XCTAssertTrue(model.openPromptLink(link))
            let confirmed = try XCTUnwrap(model.promptLinkReview)
            try model.openPromptLinkDraft(confirmed)
            draftID = try XCTUnwrap(model.conversation?.id)
            XCTAssertThrowsError(try model.openPromptLinkDraft(confirmed))
            XCTAssertEqual(model.workspace.projects.count, 2)
            XCTAssertTrue(model.project?.isScratch == true)
            XCTAssertEqual(model.draft, "Link draft")
            XCTAssertEqual(model.projects.first?.conversations.first?.composerText, original.composerText)
            model.promptLinkReview = nil
            XCTAssertTrue(model.openPromptLink(link))
            XCTAssertTrue(model.promptLinkReview?.alreadyOpened == true)
        }

        let relaunched = makeWorkspace(root)
        XCTAssertNil(relaunched.startupFailure)
        XCTAssertTrue(relaunched.openPromptLink(link))
        XCTAssertTrue(relaunched.promptLinkReview?.alreadyOpened == false)
        XCTAssertEqual(relaunched.conversation?.id, draftID)
        XCTAssertEqual(relaunched.draft, "Link draft")
        XCTAssertEqual(relaunched.projects.first?.conversations.first?.id, original.id)
    }

    private func parse(_ query: String) throws -> PromptLink {
        try PromptLink(url: XCTUnwrap(URL(string: "pi-workspace://new/v1?" + query)))
    }

    @MainActor
    private func makeWorkspace(_ root: URL) -> WorkspaceModel {
        WorkspaceModel(root: root, keychainService: "unused", readCredential: { _ in nil }) { _, _ in
            throw WorkspaceError("This fixture does not launch Pi.")
        }
    }
}
