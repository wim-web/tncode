import AppKit
import Carbon
import Combine
import SwiftUI
import XCTest
@testable import PiWorkspace

@MainActor
final class ComposerAttachmentTests: XCTestCase {
    func testImageCopyKeepsPNGBytesAndUsesTheFullOrientedJPEG() throws {
        let original = try makeAttachmentImage(width: 7, height: 3, type: .png)
        XCTAssertEqual(ComposerAttachment.pngForCopy(.init(mimeType: "image/png", data: original)), original)
        let jpg = try makeAttachmentImage(width: 2_100, height: 12, type: .jpeg, orientation: 6)
        let png = try XCTUnwrap(ComposerAttachment.pngForCopy(.init(mimeType: "image/jpeg", data: jpg)))
        let raster = try XCTUnwrap(NSBitmapImageRep(data: png))
        XCTAssertEqual(raster.pixelsWide, 12)
        XCTAssertEqual(raster.pixelsHigh, 2_100)
    }

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

    func testOffscreenPreviewKeepsDraftAndQueuedCollectionsSeparate() async throws {
        let fixture = try Fixture()
        let model = fixture.open()
        try model.applySettings(ModelSettings(provider: .local, model: "image-fixture", localImages: true),
                                in: .workspace, newKey: "", removeKey: false)
        try model.openProject(fixture.root)
        fixture.worker.onEvent?(.ready([], supportsImages: true))
        let projectID = try XCTUnwrap(model.project?.id)
        let threadID = try XCTUnwrap(model.conversation?.id)
        let target = model.attachmentTarget(for: threadID)
        let png = try makeAttachmentImage(width: 16, height: 16, type: .png)
        let jpg = try makeAttachmentImage(width: 24, height: 16, type: .jpeg)
        model.draft = "Active turn"
        model.send()
        let prompt = try XCTUnwrap(fixture.worker.prompt)
        fixture.worker.onEvent?(.history([ChatMessage(id: "active", role: .user, text: prompt.text)]))
        let files = try ["first", "second"].map { directory in
            let folder = fixture.root.appendingPathComponent(directory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent("same.png")
            try png.write(to: file)
            return file
        }
        XCTAssertTrue(model.attach([.file(files[0]), .pastedText("Text file"), .file(files[1])], to: target))
        model.queueDraft()
        let queue = try XCTUnwrap(model.queuedMessages.first)
        let queuedImages = try XCTUnwrap(queue.attachments).filter { $0.payload?.isImage == true }
        XCTAssertEqual(queuedImages.map(\.name), ["same.png", "same.png"])
        XCTAssertTrue(model.attach([.image(jpg, .jpeg)], to: target))
        let draftImage = try XCTUnwrap(model.composerAttachments.first)
        let ui = OffscreenPreviewWorkspace(model)
        defer { ui.close() }

        let opener = "preview-queued-attachment-\(queue.id)-\(queuedImages[0].id)"
        try await ui.press(opener)
        try await ui.visible("expanded-attachment-\(queuedImages[0].id)")
        let copiedQueuedImage = try await ui.copyImage("expanded-attachment-\(queuedImages[0].id)")
        XCTAssertEqual(copiedQueuedImage, png)
        try await ui.focused("close-image-preview")
        try await ui.press("previous-image-preview")
        try await ui.visible("expanded-attachment-\(queuedImages[1].id)")
        try ui.key(kVK_RightArrow, "\u{f703}")
        try await ui.visible("expanded-attachment-\(queuedImages[0].id)")
        try ui.key(kVK_ANSI_Equal, "=")
        try ui.key(kVK_ANSI_Equal, "=")
        try ui.key(kVK_RightArrow, "\u{f703}")
        try await ui.visible("expanded-attachment-\(queuedImages[0].id)")
        try ui.key(kVK_ANSI_0, "0")
        try await ui.press("next-image-preview")
        try await ui.visible("expanded-attachment-\(queuedImages[1].id)")
        try ui.key(kVK_Escape, "\u{1b}")
        try await ui.hidden("attachment-image-preview")
        try await ui.focused(opener)

        try await ui.press("preview-attachment-\(draftImage.id)")
        try await ui.visible("expanded-attachment-\(draftImage.id)")
        XCTAssertNil(ui.element("previous-image-preview"))
        XCTAssertNil(ui.element("next-image-preview"))
        try await ui.press("close-image-preview")
        try await ui.hidden("attachment-image-preview")
        try await ui.focused("preview-attachment-\(draftImage.id)")

        model.editQueuedMessage(queue.id)
        try await ui.press("preview-attachment-\(queuedImages[0].id)")
        try await ui.visible("expanded-attachment-\(queuedImages[0].id)")
        model.cancelQueuedMessageEdit()
        try await ui.hidden("attachment-image-preview")

        try await ui.press(opener)
        try await ui.visible("expanded-attachment-\(queuedImages[0].id)")
        model.removeQueuedMessage(queue.id)
        try await ui.hidden("attachment-image-preview")
        XCTAssertNil(ui.element(opener))
        XCTAssertEqual(model.composerAttachments.map(\.id), [draftImage.id])

        try await ui.press("preview-attachment-\(draftImage.id)")
        try await ui.visible("expanded-attachment-\(draftImage.id)")
        fixture.worker.onEvent?(.finished(turnID: prompt.turnID, [], error: nil))
        model.addConversation()
        XCTAssertNotEqual(model.conversation?.id, threadID)
        try await ui.hidden("attachment-image-preview")
        XCTAssertNil(ui.element("preview-attachment-\(draftImage.id)"))
        model.selectConversation(threadID, in: projectID)
        try await ui.visible("preview-attachment-\(draftImage.id)")
        try await ui.press("preview-attachment-\(draftImage.id)")
        try await ui.visible("expanded-attachment-\(draftImage.id)")
        model.removeAttachment(draftImage.id, in: model.attachmentTarget(for: threadID))
        try await ui.hidden("attachment-image-preview")
    }

    func testOffscreenTextPreviewRemovesOnlyTheSelectedDraftOrQueueAttachment() async throws {
        let fixture = try Fixture()
        let model = fixture.open()
        try model.openProject(fixture.root)
        fixture.worker.onEvent?(.ready([]))
        let thread = try XCTUnwrap(model.conversation?.id)
        let target = model.attachmentTarget(for: thread)
        model.draft = "Active turn"
        model.send()
        let active = try XCTUnwrap(fixture.worker.prompt)
        fixture.worker.onEvent?(.history([ChatMessage(id: "active", role: .user, text: active.text)]))
        let text = ["\u{feff}  First 日本語 👩🏽‍💻 e\u{0301}\r\nLast line\n\n", "Second file\r\n\n  Tail"]
        let files = try sameNamedTextFiles(text, in: fixture.root)
        XCTAssertTrue(model.attach(files.map(ComposerAttachmentInput.file), to: target))
        let draftFiles = model.composerAttachments
        XCTAssertNotEqual(draftFiles[0].id, draftFiles[1].id)
        let ui = OffscreenPreviewWorkspace(model)
        defer { ui.close() }

        let first = "preview-attachment-\(draftFiles[0].id)"
        try await ui.press(first)
        try await ui.checkFileText(text[0])
        try await ui.focused("close-file-preview")
        try ui.key(kVK_Escape, "\u{1b}")
        try await ui.hidden("attachment-file-preview")
        try await ui.focused(first)
        try await ui.press("preview-attachment-\(draftFiles[1].id)")
        try await ui.checkFileText(text[1])
        try await ui.press("remove-file-preview")
        try await ui.hidden("attachment-file-preview")
        XCTAssertEqual(model.composerAttachments.map(\.id), [draftFiles[0].id])
        XCTAssertTrue(model.attach([.file(files[1])], to: target))
        model.draft = "Queued caption"
        model.queueDraft()
        let queued = try XCTUnwrap(model.queuedMessages.first)
        let queuedFiles = try XCTUnwrap(queued.attachments)
        XCTAssertTrue(model.attach([.pastedText("Independent draft")], to: model.attachmentTarget(for: thread)))
        let independent = model.composerAttachments

        let queuedOpener = "preview-queued-attachment-\(queued.id)-\(queuedFiles[1].id)"
        try await ui.press(queuedOpener)
        try await ui.checkFileText(text[1])
        XCTAssertNil(ui.element("remove-file-preview"))
        try await ui.press("close-file-preview")
        try await ui.focused(queuedOpener)
        model.editQueuedMessage(queued.id)
        try await ui.press("preview-attachment-\(queuedFiles[0].id)")
        try await ui.checkFileText(text[0])
        model.cancelQueuedMessageEdit()
        try await ui.hidden("attachment-file-preview")
        XCTAssertEqual(model.queuedMessages.first?.attachments, queuedFiles)

        model.editQueuedMessage(queued.id)
        try await ui.press("preview-attachment-\(queuedFiles[0].id)")
        try await ui.press("remove-file-preview")
        try await ui.hidden("attachment-file-preview")
        try await ui.press("queue-update")
        XCTAssertEqual(model.queuedMessages.first?.id, queued.id)
        XCTAssertEqual(model.queuedMessages.first?.attachments, [queuedFiles[1]])
        XCTAssertEqual(model.composerAttachments, independent)

        let missing = fixture.root.appendingPathComponent("missing.txt")
        XCTAssertTrue(model.attach([.file(missing)], to: model.attachmentTarget(for: thread)))
        let unavailable = try XCTUnwrap(model.composerAttachments.last)
        try await ui.visible("reattach-attachment-\(unavailable.id)")
        XCTAssertNil(ui.element("preview-attachment-\(unavailable.id)"))
        try await ui.press("remove-attachment-\(unavailable.id)")
        XCTAssertEqual(model.composerAttachments, independent)

        let legacy = SentAttachment(id: UUID(), name: "legacy.txt", mimeType: "text/plain", hasImage: false)
        fixture.worker.onEvent?(.history([ChatMessage(id: "legacy", role: .user, text: "", attachments: [legacy])]))
        try await ui.visible("sent-attachment-\(legacy.id)")
        XCTAssertEqual(ui.element("sent-attachment-\(legacy.id)")?.accessibilityRole?(), .staticText)
        XCTAssertNil(ui.element("download-sent-attachment-\(legacy.id)"))
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
        let stashID: UUID
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
            XCTAssertTrue(model.stashCurrentPrompt())
            stashID = try XCTUnwrap(model.stashedPrompts.first?.id)
            XCTAssertTrue(model.composerAttachments.isEmpty)
            XCTAssertTrue(model.terminate())
        }

        let user: ChatMessage
        let added: UUID
        let projectID: UUID
        do {
            let model = open()
            model.start()
            await wait(for: .ready, in: model)
            XCTAssertEqual(model.conversation?.id, threadID)
            XCTAssertTrue(model.restoreStashedPrompt(stashID, to: try XCTUnwrap(model.draftProjectScope)))
            XCTAssertEqual(model.composerAttachments.map(\.id).prefix(2), [removed, kept])
            model.removeAttachment(removed, in: model.attachmentTarget(for: threadID))
            XCTAssertEqual(model.composerAttachments.map(\.name), ["same.png", "note.txt"])
            XCTAssertEqual(model.composerAttachments.first?.id, kept)
            XCTAssertTrue(model.attach([.file(first)], to: model.attachmentTarget(for: threadID)))
            added = try XCTUnwrap(model.composerAttachments.last?.id)
            XCTAssertNotEqual(added, removed)
            XCTAssertTrue(model.canSend)
            model.send()
            XCTAssertEqual(model.phase, .running)
            await wait(for: .ready, in: model)
            XCTAssertNil(model.error)
            XCTAssertEqual(model.messages.last?.text, "Attachment fixture received.")
            user = try XCTUnwrap(model.messages.first)
            XCTAssertEqual(user.attachments?.map(\.name), ["same.png", "note.txt", "same.png"])
            XCTAssertEqual(user.attachments?.first?.id, kept)
            XCTAssertEqual(user.attachments?.map(\.hasImage), [true, false, true])
            XCTAssertNotNil(user.submissionID)
            XCTAssertTrue(model.composerAttachments.isEmpty)

            projectID = try XCTUnwrap(model.project?.id)
            XCTAssertTrue(model.terminate())
        }

        let model = open()
        defer { _ = model.terminate() }
        model.start()
        model.selectConversation(threadID, in: projectID)
        await wait(for: .ready, in: model)
        XCTAssertEqual(model.conversation?.id, threadID)
        let sentIDs = try XCTUnwrap(user.attachments).map(\.id)
        XCTAssertEqual(model.messages.first?.id, user.id)
        XCTAssertEqual(model.messages.first?.attachments?.map(\.id), sentIDs)
        let blue = await model.readSentImage(threadID: threadID, messageID: user.id, attachmentID: kept)
        let red = await model.readSentImage(threadID: threadID, messageID: user.id, attachmentID: added)
        XCTAssertEqual(blue?.data, try Data(contentsOf: second))
        XCTAssertEqual(red?.data, try Data(contentsOf: first))
        let removedImage = await model.readSentImage(threadID: threadID, messageID: user.id, attachmentID: removed)
        XCTAssertNil(removedImage)
        do {
            let ui = OffscreenPreviewWorkspace(model)
            defer { ui.close() }
            try await ui.press("sent-attachment-\(added)")
            try await ui.visible("expanded-attachment-\(added)")
            let copiedRed = try await ui.copyImage("expanded-attachment-\(added)")
            XCTAssertEqual(copiedRed, try Data(contentsOf: first))
            try ui.key(kVK_RightArrow, "\u{f703}")
            try await ui.visible("expanded-attachment-\(kept)")
            let copiedBlue = try await ui.copyImage("expanded-attachment-\(kept)")
            XCTAssertEqual(copiedBlue, try Data(contentsOf: second))
            try await ui.press("close-image-preview")
            try await ui.hidden("attachment-image-preview")
        }

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
        model.attach([.file(first)], to: model.attachmentTarget(for: threadID))
        XCTAssertFalse(model.supportsImageInput)
        XCTAssertFalse(model.canSend)
        XCTAssertNotNil(model.attachmentSendError)
        XCTAssertEqual(model.composerAttachments.map(\.name), ["same.png"])
    }

    func testOffscreenPreviewShowsUnreadableSentImageAndKeepsTheGalleryUsable() async throws {
        let fixture = try Fixture()
        let model = fixture.open()
        try model.openProject(fixture.root)
        fixture.worker.onEvent?(.ready([]))
        model.draft = "Fixture"
        model.send()
        let prompt = try XCTUnwrap(fixture.worker.prompt)
        let broken = SentAttachment(id: UUID(), name: "broken.png", mimeType: "image/png", hasImage: true)
        let valid = SentAttachment(id: UUID(), name: "valid.jpg", mimeType: "image/jpeg", hasImage: true)
        let missing = SentAttachment(id: UUID(), name: "missing.png", mimeType: "image/png", hasImage: false)
        fixture.worker.sentImages[broken.id] = .init(mimeType: "image/png", data: Data("Unreadable".utf8))
        fixture.worker.sentImages[valid.id] = .init(mimeType: "image/jpeg",
                                                    data: try makeAttachmentImage(width: 16, height: 16, type: .jpeg))
        let message = ChatMessage(id: "sent", role: .user, text: prompt.text, attachments: [broken, valid, missing])
        fixture.worker.onEvent?(.finished(turnID: prompt.turnID, [message], error: nil))
        let ui = OffscreenPreviewWorkspace(model)
        defer { ui.close() }

        try await ui.press("sent-attachment-\(broken.id)")
        try await ui.visible("image-preview-unavailable")
        XCTAssertNil(ui.element("expanded-attachment-\(broken.id)"))
        try await ui.press("next-image-preview")
        try await ui.visible("expanded-attachment-\(valid.id)")
        try await ui.copyImage("expanded-attachment-\(valid.id)")
        try await ui.press("next-image-preview")
        try await ui.visible("image-preview-unavailable")
        try await ui.press("close-image-preview")
        try await ui.focused("sent-attachment-\(broken.id)")
        try await ui.visible("sent-attachment-\(missing.id)")
        XCTAssertEqual(ui.element("sent-attachment-\(missing.id)")?.accessibilityRole?(), .staticText)
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

    func testTextPreviewAndSaveUseExactBytesFromReopenedPiSession() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let endpoint = environment["PI_ATTACHMENT_TEST_ENDPOINT"],
              let executable = environment["PI_ATTACHMENT_TEST_NODE"],
              let worker = environment["PI_ATTACHMENT_TEST_WORKER"] else {
            throw XCTSkip("Run scripts/verify-attachments.mjs for the loopback integration.")
        }
        let fixture = try Fixture()
        let settings = ModelSettings(provider: .local, model: "attachment-file-fixture", endpoint: endpoint)
        func open() -> WorkspaceModel {
            WorkspaceModel(root: fixture.workspace, keychainService: "dev.piworkspace.attachment-tests",
                           readCredential: { _ in "attachment-fixture-key" }) { config, cwd in
                try PiProcess(config: config, cwd: cwd, executable: URL(fileURLWithPath: executable),
                              arguments: [worker])
            }
        }
        let text = ["\u{feff}  First 日本語 👩🏽‍💻 e\u{0301}\r\nLast line\n\n", "Second file\r\n\n  Tail"]
        let files = try sameNamedTextFiles(text, in: fixture.root)
        let data = text.map { Data($0.utf8) }
        let thread: UUID
        let project: UUID
        let sent: [ChatMessage]
        let ids: [UUID]
        do {
            let model = open()
            try model.applySettings(settings, in: .workspace, newKey: "", removeKey: false)
            try model.openProject(fixture.root)
            await wait(for: .ready, in: model)
            thread = try XCTUnwrap(model.conversation?.id)
            project = try XCTUnwrap(model.project?.id)
            XCTAssertTrue(model.attach(files.map(ComposerAttachmentInput.file), to: model.attachmentTarget(for: thread)))
            ids = model.composerAttachments.map(\.id)
            model.send()
            await wait(for: .ready, in: model)
            XCTAssertNil(model.error)
            model.draft = "Second owner"
            XCTAssertTrue(model.attach([.file(files[0])], to: model.attachmentTarget(for: thread)))
            model.send()
            await wait(for: .ready, in: model)
            XCTAssertNil(model.error)
            sent = model.messages.filter { $0.role == .user }
            XCTAssertEqual(sent.count, 2)
            XCTAssertTrue(model.terminate())
        }
        for file in files { try FileManager.default.removeItem(at: file) }
        let history = WorkspaceStore.historyComponents(project: project, conversation: thread).reduce(fixture.workspace) {
            $0.appendingPathComponent($1, isDirectory: true)
        }
        let session = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: history, includingPropertiesForKeys: nil)
            .first { $0.pathExtension == "jsonl" })
        let records = try String(contentsOf: session, encoding: .utf8).split(separator: "\n").map {
            try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }
        let entry = try XCTUnwrap(records.first { $0?["id"] as? String == sent[0].id } ?? nil)
        let message = try XCTUnwrap(entry["message"] as? [String: Any])
        let receipt = try XCTUnwrap(message["workspaceInput"] as? [String: Any])
        let metadata = try XCTUnwrap(receipt["attachments"] as? [[String: String]])
        XCTAssertEqual(metadata.compactMap { $0["id"] }, ids.map(\.uuidString))
        XCTAssertEqual(metadata.compactMap { $0["textData"].flatMap { Data(base64Encoded: $0) } }, data)

        let model = open()
        defer { _ = model.terminate() }
        if let error = model.startupFailure { throw error }
        model.start()
        model.selectConversation(thread, in: project)
        await wait(for: .ready, in: model)
        XCTAssertEqual(model.conversation?.id, thread)
        XCTAssertEqual(model.messages.first?.attachments?.map(\.id), ids)
        let wrongOwner = await model.readSentFile(threadID: thread, messageID: sent[1].id, attachmentID: ids[0])
        XCTAssertNil(wrongOwner)
        let wrongThread = await model.readSentFile(threadID: UUID(), messageID: sent[0].id, attachmentID: ids[0])
        XCTAssertNil(wrongThread)
        let ui = OffscreenPreviewWorkspace(model)
        defer { ui.close() }
        for (id, contents) in zip(ids, text) {
            let opener = "sent-attachment-\(id)"
            try await ui.press(opener)
            try await ui.checkFileText(contents)
            XCTAssertNil(ui.element("remove-file-preview"))
            try await ui.press("close-file-preview")
            try await ui.focused(opener)
        }

        let destination = fixture.root.appendingPathComponent("exports", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let download = "download-sent-attachment-\(ids[0])"
        try await ui.press(download)
        let cancelled = try await ui.saveRequest()
        XCTAssertEqual(cancelled.name, "same.txt")
        ui.finishSaveRequest(to: nil)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
        try await ui.focused(download)
        for (index, id) in ids.enumerated() {
            try await ui.press("download-sent-attachment-\(id)")
            let request = try await ui.saveRequest()
            XCTAssertEqual(request.name, "same.txt")
            let url = destination.appendingPathComponent("export-\(index).txt")
            ui.finishSaveRequest(to: url)
            XCTAssertEqual(try Data(contentsOf: url), data[index])
        }

        try await ui.press("sent-attachment-\(ids[0])")
        try await ui.checkFileText(text[0])
        try await ui.press("save-file-preview")
        let stale = try await ui.saveRequest()
        model.addConversation()
        XCTAssertNotEqual(model.conversation?.id, thread)
        try await ui.hidden("attachment-file-preview")
        try await ui.saveRequestClosed()
        let staleURL = destination.appendingPathComponent("stale.txt")
        stale.complete(.success(staleURL))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staleURL.path))
        model.selectConversation(thread, in: project)
        await wait(for: .ready, in: model)
        try await ui.press(download)
        _ = try await ui.saveRequest()
        ui.finishSaveRequest(to: nil)
    }

    private func sameNamedTextFiles(_ contents: [String], in root: URL) throws -> [URL] {
        try contents.enumerated().map { index, text in
            let folder = root.appendingPathComponent("source-\(index)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent("same.txt")
            try Data(text.utf8).write(to: file)
            return file
        }
    }

    private final class Worker: PiConnection {
        var onEvent: ((PiEvent) -> Void)?
        var onClose: (() -> Void)?
        var prompt: SendPrompt?
        var steer: SendQueuedInput?
        var sentImages: [UUID: ComposerAttachment.Payload] = [:]

        func send(_ command: any Encodable) throws {
            if let command = command as? SendPrompt { prompt = command }
            if let command = command as? SendQueuedInput { steer = command }
            if let command = command as? ReadSentAttachment, command.type == .readSentImage {
                onEvent?(.sentAttachment(requestID: command.requestID, sentImages[command.attachmentID]))
            }
        }

        func close() {}
    }
}

@MainActor
private final class OffscreenPreviewWorkspace {
    private let app = NSApplication.shared
    private let policy: NSApplication.ActivationPolicy
    private let window: NSPanel
    private let host: NSHostingView<WorkspaceView>
    private let pasteboard = NSPasteboard.withUniqueName()
    private let savePicker = OffscreenSavePicker()

    init(_ model: WorkspaceModel) {
        policy = app.activationPolicy()
        app.setActivationPolicy(.prohibited)
        app.finishLaunching()
        let origin = NSPoint(x: (NSScreen.screens.map(\.frame.minX).min() ?? 0) - 2200, y: 0)
        window = ImagePreviewOffscreenPanel(contentRect: NSRect(origin: origin, size: NSSize(width: 1100, height: 720)),
                                            styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        host = NSHostingView(rootView: WorkspaceView(model: model, chatWidthMode: .comfortable,
                                                     workspacePasteboard: pasteboard,
                                                     attachmentSavePicker: savePicker.picker))
        window.contentView = host
        window.setFrameOrigin(origin)
        XCTAssertTrue(NSScreen.screens.allSatisfy { !$0.frame.intersects(window.frame) })
        window.orderBack(nil)
    }

    func close() {
        window.contentView = nil
        window.close()
        pasteboard.releaseGlobally()
        app.setActivationPolicy(policy)
    }

    private func find(in root: AnyObject, matching: (AnyObject) -> Bool) -> AnyObject? {
        var visited = Set<ObjectIdentifier>()
        func find(_ node: AnyObject) -> AnyObject? {
            guard visited.insert(ObjectIdentifier(node)).inserted else { return nil }
            if matching(node) { return node }
            for child in node.accessibilityChildren?() ?? [] {
                if let found = find(child as AnyObject) { return found }
            }
            return nil
        }
        return find(root)
    }

    func element(_ id: String) -> AnyObject? {
        func matches(_ node: AnyObject) -> Bool { node.accessibilityIdentifier?() == id }
        return find(in: host, matching: matches) ?? find(in: window, matching: matches)
    }

    func press(_ id: String) async throws {
        try await visible(id)
        XCTAssertEqual(element(id)?.accessibilityPerformPress?(), true, id)
    }

    func visible(_ id: String) async throws { try await waitFor(id) { self.element(id) != nil } }
    func hidden(_ id: String) async throws { try await waitFor(id) { self.element(id) == nil } }
    func focused(_ id: String) async throws {
        try await waitFor("focus on \(id)") { self.element(id)?.isAccessibilityFocused?() == true }
    }

    func checkFileText(_ expected: String) async throws {
        try await visible("file-preview-contents")
        let field = element("file-preview-contents") as? NSAccessibilityProtocol
        let value = try XCTUnwrap(field?.accessibilityValue() as? String)
        XCTAssertEqual(Data(value.utf8), Data(expected.utf8))
    }

    func saveRequest() async throws -> OffscreenSavePicker.Request {
        try await waitFor("attachment save destination request") { self.savePicker.request != nil }
        XCTAssertFalse(app.isActive)
        return try XCTUnwrap(savePicker.request)
    }

    func finishSaveRequest(to url: URL?) {
        savePicker.finish(with: url)
    }

    func saveRequestClosed() async throws {
        try await waitFor("attachment save request to close") { self.savePicker.request == nil }
    }

    @discardableResult
    func copyImage(_ id: String) async throws -> Data {
        pasteboard.clearContents()
        let actions = try XCTUnwrap(element(id)?.accessibilityCustomActions?())
        let action = try XCTUnwrap(actions.first { $0.name == "Copy Image" })
        XCTAssertEqual(action.handler?(), true)
        try await waitFor("PNG on the isolated pasteboard") { self.pasteboard.data(forType: .png) != nil }
        return try XCTUnwrap(pasteboard.data(forType: .png))
    }

    private func waitFor(_ id: String, _ predicate: () -> Bool) async throws {
        for _ in 0..<80 {
            host.layoutSubtreeIfNeeded()
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        let message = "Timed out waiting for the expected visibility of \(id)."
        XCTFail(message)
        throw WorkspaceError(message)
    }

    func key(_ code: Int, _ characters: String) throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                  windowNumber: window.windowNumber, context: nil, characters: characters,
                                                  charactersIgnoringModifiers: characters, isARepeat: false, keyCode: UInt16(code)))
        app.sendEvent(event)
    }
}

private final class ImagePreviewOffscreenPanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class OffscreenSavePicker {
    struct Request {
        let id = UUID()
        let name: String
        let complete: ChatFileSavePicker.Completion
    }

    private(set) var request: Request?

    var picker: ChatFileSavePicker {
        ChatFileSavePicker { [weak self] window, name, complete in
            XCTAssertTrue(NSScreen.screens.allSatisfy { !$0.frame.intersects(window.frame) })
            let request = Request(name: name, complete: complete)
            self?.request = request
            return { [weak self] in
                if self?.request?.id == request.id { self?.request = nil }
            }
        }
    }

    func finish(with url: URL?) {
        let request = request
        self.request = nil
        request?.complete(.success(url))
    }
}
