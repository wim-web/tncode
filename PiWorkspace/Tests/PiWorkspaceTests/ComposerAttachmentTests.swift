import AppKit
import Combine
import XCTest
@testable import PiWorkspace

@MainActor
final class ComposerAttachmentTests: XCTestCase {
    func testUnavailableAttachmentCanBeReplacedByIDAfterRelaunch() async throws {
        let fixture = try Fixture()
        let missing = fixture.root.appendingPathComponent("unavailable.txt")
        let replacement = fixture.root.appendingPathComponent("replacement.txt")
        try Data("Replacement fixture".utf8).write(to: replacement)
        let threadID: UUID
        let attachmentID: UUID
        do {
            let model = fixture.open()
            try model.openProject(fixture.root)
            fixture.worker.onEvent?(.ready([]))
            threadID = try XCTUnwrap(model.conversation?.id)
            model.attach([.file(missing)], to: ComposerAttachmentTarget(threadID: threadID))
            attachmentID = try XCTUnwrap(model.composerAttachments.first?.id)
            XCTAssertFalse(model.canSend)
            XCTAssertTrue(model.terminate())
        }

        let model = fixture.open()
        model.start()
        fixture.worker.onEvent?(.ready([]))
        XCTAssertEqual(model.conversation?.id, threadID)
        XCTAssertEqual(model.composerAttachments.first?.id, attachmentID)
        XCTAssertFalse(model.canSend)
        model.attach([.file(replacement)], to: ComposerAttachmentTarget(threadID: threadID), replacing: attachmentID)
        XCTAssertEqual(model.composerAttachments.first?.id, attachmentID)
        XCTAssertEqual(model.composerAttachments.first?.name, "replacement.txt")
        XCTAssertTrue(model.canSend)
    }

    func testInterruptedSendKeepsBytesUntilMatchingHistoryReceipt() async throws {
        let fixture = try Fixture()
        let url = fixture.root.appendingPathComponent("fixture.txt")
        let content = Data("Attachment kept after disconnect".utf8)
        try content.write(to: url)
        let model = fixture.open()
        try model.openProject(fixture.root)
        let threadID = try XCTUnwrap(model.conversation?.id)
        let sameText = ChatMessage(id: "prior", role: .user, text: "Same prompt")
        fixture.worker.onEvent?(.ready([sameText]))
        model.draft = sameText.text
        model.attach([.file(url)], to: ComposerAttachmentTarget(threadID: threadID))
        model.send()
        let first = try XCTUnwrap(fixture.worker.prompt)
        let falseReceipt = ChatMessage(id: "intervening", role: .user, text: sameText.text, submissionID: UUID())
        fixture.worker.onClose?()
        model.connect()
        fixture.worker.onEvent?(.ready([sameText, falseReceipt]))
        XCTAssertEqual(model.composerAttachments.first?.payload?.data, content)
        XCTAssertTrue(model.canSend)
        model.send()
        let retried = try XCTUnwrap(fixture.worker.prompt)
        XCTAssertNotEqual(first.submissionID, retried.submissionID)
        fixture.worker.onClose?()
        model.connect()
        let recorded = ChatMessage(id: "recorded", role: .user, text: sameText.text, submissionID: retried.submissionID)
        fixture.worker.onEvent?(.ready([sameText, falseReceipt, recorded]))
        XCTAssertTrue(model.composerAttachments.isEmpty)
        XCTAssertFalse(model.canSend)
    }

    func testRowTargetAndQueueEditorKeepSeparateAttachmentOwners() async throws {
        let fixture = try Fixture()
        let firstFile = fixture.root.appendingPathComponent("first.txt")
        let secondFile = fixture.root.appendingPathComponent("second.txt")
        try Data("First draft bytes".utf8).write(to: firstFile)
        try Data("Second draft bytes".utf8).write(to: secondFile)
        let model = fixture.open()
        try model.openProject(fixture.root)
        let project = try XCTUnwrap(model.project?.id)
        let first = ComposerAttachmentTarget(threadID: try XCTUnwrap(model.conversation?.id))
        XCTAssertTrue(model.attach([.file(firstFile)], to: first))
        model.addConversation()
        let second = ComposerAttachmentTarget(threadID: try XCTUnwrap(model.conversation?.id))
        XCTAssertNotEqual(first.threadID, second.threadID)
        XCTAssertTrue(model.attach([.file(secondFile)], to: first))
        XCTAssertTrue(model.composerAttachments.isEmpty)
        model.selectConversation(first.threadID, in: project)
        fixture.worker.onEvent?(.ready([]))
        XCTAssertEqual(model.composerAttachments.map(\.name), ["first.txt", "second.txt"])

        model.send()
        let active = try XCTUnwrap(fixture.worker.prompt)
        let sent = ChatMessage(id: "sent", role: .user, text: "", submissionID: active.submissionID)
        fixture.worker.onEvent?(.history([sent]))
        fixture.worker.onEvent?(.inputMode(turnID: active.turnID, .steer))
        XCTAssertTrue(model.attach([.file(firstFile)], to: first))
        model.queueDraft(steering: true)
        let steer = try XCTUnwrap(fixture.worker.steer)
        XCTAssertEqual(steer.attachments?.map(\.name), ["first.txt"])
        fixture.worker.onEvent?(.queueRejected(turnID: active.turnID, queuedID: steer.queuedID))
        XCTAssertEqual(model.queuedMessages.first?.attachments, steer.attachments)
        XCTAssertTrue(model.attach([.file(secondFile)], to: first))
        model.editQueuedMessage(steer.queuedID)
        let queueTarget = model.attachmentTarget(for: first.threadID)
        XCTAssertEqual(model.composerAttachments.map(\.name), ["first.txt"])
        model.cancelQueuedMessageEdit()
        XCTAssertFalse(model.attach([.file(firstFile)], to: queueTarget))
        XCTAssertEqual(model.composerAttachments.map(\.name), ["second.txt"])
        XCTAssertEqual(model.queuedMessages.first?.attachments, steer.attachments)
        fixture.worker.onEvent?(.finished(turnID: active.turnID, [sent], error: "Pause the queue"))
        model.selectConversation(second.threadID, in: project)
        XCTAssertEqual(model.conversation?.id, second.threadID)
        model.selectConversation(first.threadID, in: project)
        XCTAssertEqual(model.conversation?.id, first.threadID)
        fixture.worker.onEvent?(.ready([sent]))
        model.editQueuedMessage(steer.queuedID)
        XCTAssertEqual(model.editingQueuedMessageID, steer.queuedID)
        XCTAssertFalse(model.attach([.file(secondFile)], to: queueTarget))
        XCTAssertEqual(model.composerAttachments.map(\.name), ["first.txt"])
        let reopened = model.attachmentTarget(for: first.threadID)
        XCTAssertTrue(model.attach([.file(secondFile)], to: reopened))
        model.updateQueuedMessage()
        XCTAssertEqual(model.queuedMessages.first?.attachments?.map(\.name), ["first.txt", "second.txt"])
    }

    func testSelectedAttachmentsReachPinnedSDK() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let endpoint = environment["PI_ATTACHMENT_TEST_ENDPOINT"],
              let executable = environment["PI_ATTACHMENT_TEST_NODE"],
              let worker = environment["PI_ATTACHMENT_TEST_WORKER"],
              let fixturePath = environment["PI_ATTACHMENT_TEST_FIXTURES"] else {
            throw XCTSkip("Run scripts/verify-attachments.mjs for the loopback integration.")
        }
        let fixture = try Fixture()
        let source = URL(fileURLWithPath: fixturePath)
        let first = source.appendingPathComponent("red/same.png")
        let second = source.appendingPathComponent("blue/same.png")
        let note = source.appendingPathComponent("note.txt")
        let settings = ModelSettings(provider: .local, model: "attachment-fixture", endpoint: endpoint, localImages: true)
        let open = {
            WorkspaceModel(root: fixture.workspace, keychainService: "dev.piworkspace.attachment-tests",
                           readCredential: { _ in "attachment-fixture-key" }) { config, cwd in
                try PiProcess(config: config, cwd: cwd, executable: URL(fileURLWithPath: executable),
                              arguments: [worker])
            }
        }
        let threadID: UUID
        let removed: UUID
        let kept: UUID
        do {
            let model = open()
            try model.applySettings(settings, in: .workspace, newKey: "", removeKey: false)
            try model.openProject(fixture.root)
            await wait(for: .ready, in: model)
            XCTAssertTrue(model.supportsImageInput)
            threadID = try XCTUnwrap(model.conversation?.id)
            model.attach([first, second, note].map(ComposerAttachmentInput.file), to: ComposerAttachmentTarget(threadID: threadID))
            let attachments = model.composerAttachments
            XCTAssertEqual(attachments.map(\.name), ["same.png", "same.png", "note.txt"])
            removed = try XCTUnwrap(attachments.first?.id)
            kept = try XCTUnwrap(attachments.dropFirst().first?.id)
            XCTAssertNotEqual(removed, kept)
            XCTAssertEqual(attachments[0].payload?.data, try Data(contentsOf: first))
            XCTAssertEqual(attachments[1].payload?.data, try Data(contentsOf: second))
            XCTAssertNotEqual(try previewColor(attachments[0]), try previewColor(attachments[1]))
            model.removeAttachment(removed, in: ComposerAttachmentTarget(threadID: threadID))
            XCTAssertTrue(model.terminate())
        }

        let model = open()
        model.start()
        await wait(for: .ready, in: model)
        XCTAssertEqual(model.conversation?.id, threadID)
        XCTAssertEqual(model.composerAttachments.map(\.name), ["same.png", "note.txt"])
        XCTAssertEqual(model.composerAttachments.first?.id, kept)
        XCTAssertTrue(model.canSend)
        model.send()
        XCTAssertEqual(model.phase, .running)
        await wait(for: .ready, in: model)
        XCTAssertNil(model.error)
        XCTAssertEqual(model.messages.last?.text, "Attachment fixture received.")
        let user = try XCTUnwrap(model.messages.first)
        XCTAssertEqual(user.attachments?.map(\.name), ["same.png", "note.txt"])
        XCTAssertEqual(user.attachments?.first?.id, kept)
        XCTAssertNotNil(user.submissionID)
        XCTAssertTrue(model.composerAttachments.isEmpty)

        model.connect()
        await wait(for: .ready, in: model)
        XCTAssertEqual(model.messages.first?.id, user.id)
        XCTAssertEqual(model.messages.first?.attachments?.map(\.name), ["same.png", "note.txt"])

        let largeText = "\u{FEFF}" + String(repeating: "  日本語 👩🏽‍💻 e\u{301}\r\n", count: 1300)
        let largeImage = try makeAttachmentImage(width: 2200, height: 1600, type: .png, noisy: true)
        XCTAssertGreaterThan(largeImage.count, ComposerAttachment.maxBytes)
        let target = model.attachmentTarget(for: threadID)
        var sentImageID: UUID?
        for run in 1...2 {
            model.draft = "Large paste \(run)"
            XCTAssertTrue(model.attach([.pastedText(largeText), .image(largeImage, .png)], to: target))
            let attachments = model.composerAttachments
            XCTAssertEqual(attachments.map(\.name), ["pasted-text.txt", "Pasted Image.png"])
            XCTAssertEqual(attachments.first?.payload?.data, Data(largeText.utf8))
            let image = try XCTUnwrap(attachments.last)
            XCTAssertNotEqual(image.id, sentImageID)
            let bytes = try XCTUnwrap(image.payload?.data)
            try bytes.write(to: source.appendingPathComponent("normalized-\(run).png"))
            XCTAssertTrue(model.canSend)
            model.send()
            XCTAssertEqual(model.phase, .running)
            await wait(for: .ready, in: model)
            XCTAssertNil(model.error)
            XCTAssertTrue(model.composerAttachments.isEmpty)
            let message = try XCTUnwrap(model.messages.last(where: { $0.role == .user }))
            XCTAssertEqual(message.text, "Large paste \(run)")
            XCTAssertEqual(message.attachments?.map(\.id), attachments.map(\.id))
            sentImageID = image.id
        }

        var textOnly = settings
        textOnly.localImages = false
        try model.applySettings(textOnly, in: .workspace, newKey: "", removeKey: false)
        await wait(for: .ready, in: model)
        model.attach([.file(first)], to: ComposerAttachmentTarget(threadID: threadID))
        XCTAssertFalse(model.supportsImageInput)
        XCTAssertFalse(model.canSend)
        XCTAssertNotNil(model.attachmentSendError)
        XCTAssertEqual(model.composerAttachments.map(\.name), ["same.png"])
    }

    private func previewColor(_ attachment: ComposerAttachment) throws -> NSColor {
        let image = try XCTUnwrap(attachment.preview(maximumSize: 16))
        let bytes = try XCTUnwrap(image.tiffRepresentation)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: bytes))
        return try XCTUnwrap(bitmap.colorAt(x: 0, y: 0))
    }

    private func wait(for phase: WorkspaceModel.Phase, in model: WorkspaceModel) async {
        let reached = expectation(description: "Pi phase is \(phase)")
        let observation = model.$phase.filter { $0 == phase }.first().sink { _ in reached.fulfill() }
        await fulfillment(of: [reached], timeout: 10)
        observation.cancel()
    }

    private final class Fixture {
        let root: URL
        @MainActor let worker = Worker()
        var workspace: URL { root.appendingPathComponent("workspace") }

        @MainActor init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        deinit { try? FileManager.default.removeItem(at: root) }

        @MainActor
        func open() -> WorkspaceModel {
            WorkspaceModel(root: workspace, keychainService: "dev.piworkspace.attachment-tests",
                           readCredential: { _ in "attachment-fixture-key" }, makeProcess: { _, _ in self.worker })
        }
    }

    private final class Worker: PiConnection {
        var onEvent: ((PiEvent) -> Void)?
        var onClose: (() -> Void)?
        var prompt: SendPrompt?
        var steer: SendQueuedInput?

        func send(_ command: any Encodable) throws {
            if let command = command as? SendPrompt { prompt = command }
            if let command = command as? SendQueuedInput { steer = command }
        }

        func close() {}
    }
}
