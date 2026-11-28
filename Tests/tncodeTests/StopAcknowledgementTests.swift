import XCTest
@testable import tncode

@MainActor
final class StopAcknowledgementTests: XCTestCase {
    func testRetryStopsTheSameStreamingHelperAfterTenSeconds() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let receipts = root.appendingPathComponent("commands.jsonl")
        let store = root.appendingPathComponent("store")
        try WorkspaceStore(root: store).save(.init(model: ModelSettings(provider: .openai)))
        let model = WorkspaceModel(root: store, keychainService: UUID().uuidString,
                                   readCredential: { _ in "fixture-key" }, makeProcess: { config, cwd in
            try PiProcess(config: config, cwd: cwd, executable: URL(fileURLWithPath: "/usr/bin/python3"),
                          arguments: ["-u", "-c", Self.helper, receipts.path])
        })
        defer { model.shutdown() }
        try model.openProject(folder)
        try await waitUntil { model.phase == .ready }
        model.draft = "Hold this turn"
        model.send()
        try await waitUntil { model.partial == "Started" }
        let thread = try XCTUnwrap(model.conversation?.id)
        model.draft = "Keep queued"
        model.queueDraft()
        model.draft = "Unsent draft"
        let start = ContinuousClock.now
        model.cancel()
        model.cancel()
        try await waitUntil { model.partial == "Still streaming" }
        XCTAssertEqual(model.phase, .stopping)
        XCTAssertFalse(model.phase.canStop)
        XCTAssertFalse(model.canChooseComposerModel)
        try await waitUntil(timeout: .seconds(13)) { model.phase.canStop }
        XCTAssertFalse(model.canChooseComposerModel)
        XCTAssertGreaterThanOrEqual(start.duration(to: .now), .seconds(10))
        try await waitUntil { model.partial == "Still streaming after timeout" }
        XCTAssertTrue(model.queuePaused)
        XCTAssertFalse(model.canSend)
        XCTAssertFalse(model.canQueueDraft)
        model.send()
        model.cancel()
        XCTAssertEqual(model.phase, .stopping)
        model.cancel()
        try await waitUntil { model.phase == .ready }
        XCTAssertEqual(model.messages.map(\.text), ["Hold this turn", "Still streaming after timeout"])
        XCTAssertEqual(model.queuedMessages.map(\.text), ["Keep queued"])
        XCTAssertTrue(model.queuePaused)
        XCTAssertEqual(model.draft, "Unsent draft")
        XCTAssertEqual(model.conversation?.id, thread)

        let commands = try String(contentsOf: receipts, encoding: .utf8).split(separator: "\n").map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
        XCTAssertEqual(commands.compactMap { $0["type"] as? String }, ["open", "prompt", "cancel", "cancel"])
        XCTAssertEqual(commands.first?["threadID"] as? String, thread.uuidString)
        let turnIDs = commands.compactMap { $0["turnID"] as? String }
        XCTAssertEqual(turnIDs.count, 3)
        XCTAssertEqual(Set(turnIDs).count, 1)
    }

    private func waitUntil(timeout: Duration = .seconds(4), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else { throw WorkspaceError("Timed out waiting for the helper.") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private static let helper = #"""
    import json, sys
    from threading import Timer
    def emit(**event):
        print(json.dumps(event))
    cancels = 0
    for line in sys.stdin:
        command = json.loads(line)
        with open(sys.argv[1], "a") as receipts:
            receipts.write(line)
        if command["type"] == "open":
            emit(type="ready", messages=[])
        elif command["type"] == "prompt":
            turn = command["turnID"]
            history = [dict(id=turn, role="user", text=command["text"])]
            emit(type="history", messages=history)
            emit(type="partial", text="Started")
        elif command["type"] == "cancel" and command["turnID"] == turn:
            cancels += 1
            if cancels == 1:
                emit(type="partial", text="Still streaming")
                Timer(10.1, lambda: emit(type="partial", text="Still streaming after timeout")).start()
            else:
                history.append(dict(id="reply", role="assistant", text="Still streaming after timeout"))
                emit(type="finished", turnID=turn, messages=history)
    """#
}
