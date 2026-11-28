import AppKit
import Foundation
import SwiftUI
import Vision
import XCTest
@testable import PiWorkspace

final class WorkspaceUsageTests: XCTestCase {
    func testPastDayIncludesOnlyTheLast1440CompletedMinutes() {
        let minute = Date(timeIntervalSince1970: 1_800_000_000)
        let now = minute.addingTimeInterval(45)
        let window = UsagePeriod.pastDay.window(at: now, calendar: .current)
        let first = minute.addingTimeInterval(-86_400)
        XCTAssertFalse(window.contains(first.addingTimeInterval(-0.001)))
        XCTAssertTrue(window.contains(first))
        XCTAssertTrue(window.contains(minute.addingTimeInterval(-0.001)))
        XCTAssertFalse(window.contains(minute))
        XCTAssertFalse(window.contains(now))
    }

    func testMissingForkMakesItsProjectIncompleteUntilTheFileReturns() async throws {
        let fixture = try UsageFixture()
        let fork = fixture.ids.forkFile
        let moved = fixture.root.appendingPathComponent("removed-history.jsonl")
        try FileManager.default.moveItem(at: fork, to: moved)
        let missing = try await fixture.snapshot()
        XCTAssertEqual(missing.incompleteHistories(in: .project(fixture.ids.alpha)), 1)
        XCTAssertEqual(missing.incompleteHistories(in: .project(fixture.ids.beta)), 0)
        XCTAssertEqual(missing.readout(period: .month, project: nil).total.tokens[.total]?.sum, 420)
        try FileManager.default.moveItem(at: moved, to: fork)
        let restored = try await fixture.snapshot()
        XCTAssertEqual(restored.incompleteHistories(in: nil), 0)
        XCTAssertEqual(restored.readout(period: .month, project: nil).total.tokens[.total]?.sum, 480)
    }

    func testPiAccountingAcrossPeriodsProjectsProvidersAndCopies() async throws {
        let fixture = try UsageFixture()
        let snapshot = try await fixture.snapshot()
        func totals(_ period: UsagePeriod, project: UsageProject? = nil) -> UsageTotals {
            snapshot.readout(period: period, project: project).total
        }
        for (period, tokens, responses) in [
            (UsagePeriod.pastDay, 310, 6), (.week, 350, 7), (.month, 480, 8), (.quarter, 720, 9)
        ] {
            let total = totals(period)
            XCTAssertEqual(total.tokens[.total]?.sum, Decimal(tokens), period.title)
            XCTAssertEqual(total.tokens[.total]?.recorded, responses - 2, period.title)
            XCTAssertEqual(total.responses, responses, period.title)
        }
        XCTAssertEqual(snapshot.providers, ["openai", "anthropic", "local"])
        XCTAssertEqual(snapshot.incompleteHistories(in: nil), 0)

        let alpha = totals(.month, project: .project(fixture.ids.alpha))
        XCTAssertEqual(alpha.tokens[.total]?.sum, 330)
        XCTAssertEqual(alpha.cost.sum, Decimal(string: "0.0082"))
        XCTAssertEqual(alpha.cost.recorded, 4)
        XCTAssertEqual(alpha.reportedCosts, 1)
        let beta = totals(.month, project: .project(fixture.ids.beta))
        XCTAssertEqual(beta.tokens[.total]?.sum, 150)
        XCTAssertEqual(beta.cost.sum, 0)
        XCTAssertEqual(beta.cost.recorded, 1)
        XCTAssertEqual(beta.reportedCosts, 1)

        let hosted = snapshot.readout(period: .month, project: nil, hiddenProviders: ["local"])
        XCTAssertEqual(hosted.total.tokens[.total]?.sum, 340)
        XCTAssertEqual(hosted.total.tokens[.total]?.recorded, hosted.total.responses)
        XCTAssertEqual(hosted.total.cost.recorded, hosted.total.responses)
        XCTAssertEqual(hosted.models.count, 2)

        let model = UsageModel(provider: "openai", model: "usage-shared-model")
        let detail = snapshot.readout(period: .pastDay, project: .project(fixture.ids.alpha), model: model)
        XCTAssertEqual(detail.total.tokens[.input]?.sum, 90)
        XCTAssertEqual(detail.total.tokens[.output]?.sum, 50)
        XCTAssertEqual(detail.total.tokens[.cacheRead]?.sum, 15)
        XCTAssertEqual(detail.total.tokens[.cacheWrite]?.sum, 5)
        XCTAssertEqual(detail.times.values.compactMap { $0.tokens[.total]?.sum }.sorted(), [60, 100])
        XCTAssertEqual(snapshot.readout(period: .month, project: .scratch).total.responses, 0)
        XCTAssertEqual(try Data(contentsOf: fixture.index), fixture.initialIndex)
    }

    func testRefreshAndIncompleteHistoryKeepKnownUsage() async throws {
        let fixture = try UsageFixture()
        let first = try await fixture.snapshot()
        let root = fixture.root
        let beta = UsageProject.project(fixture.ids.beta)
        let file = try FileHandle(forWritingTo: fixture.ids.betaFile)
        try file.seekToEnd()
        try file.write(contentsOf: Data("{invalid session line}\n".utf8))
        let lines = try String(contentsOf: fixture.ids.betaFile, encoding: .utf8).split(separator: "\n")
        let previous = try XCTUnwrap(lines.first { $0.contains("\"totalTokens\":140") })
        var entry = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(previous.utf8)) as? [String: Any])
        entry["id"] = "new-entry"
        let added = try JSONSerialization.data(withJSONObject: entry)
        try file.write(contentsOf: added + Data([0x0a]))
        try file.close()

        let refreshed = try await fixture.snapshot()
        XCTAssertEqual(first.readout(period: .pastDay, project: beta).total.tokens[.total]?.sum, 150)
        XCTAssertEqual(refreshed.readout(period: .pastDay, project: beta).total.tokens[.total]?.sum, 290)
        XCTAssertEqual(refreshed.incompleteHistories(in: beta), 1)
        XCTAssertEqual(refreshed.incompleteHistories(in: .project(fixture.ids.alpha)), 0)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("workspace.json")), fixture.initialIndex)
    }

    @MainActor
    func testUsageSettingsCanRenderOffscreenWithoutChangingScopeOrCredentials() async throws {
        let fixture = try UsageFixture()
        let suite = "WorkspaceUsageTests.\(fixture.ids.beta.uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = WorkspaceModel(root: fixture.root, keychainService: suite, readCredential: { _ in
            XCTFail("Usage should not read credentials.")
            return nil
        }, makeProcess: { _, _ in
            XCTFail("Usage should not launch Pi.")
            throw WorkspaceError("Unexpected Pi launch.")
        })
        model.openSettings(.usage)
        let request = try XCTUnwrap(model.settingsRequest)
        XCTAssertEqual(request.projectID, fixture.ids.beta)
        // SwiftUI publishes its accessibility tree once the app has finished launching.
        NSApplication.shared.finishLaunching()
        let host = NSHostingView(rootView: SettingsView(model: model, appearance: AppearanceSettings(defaults: defaults),
                                                       browserDefaults: defaults, request: request, openWelcome: {})
            .defaultAppStorage(defaults))
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 784, height: 474),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = host
        window.orderBack(nil)
        try XCTSkipIf(window.windowNumber <= 0, "Offscreen settings need an AppKit window number.")
        // Segmented controls are drawn in SwiftUI; accessibility exposes one native segment per option.
        func segments(_ id: String) -> Int? {
            var visited = Set<ObjectIdentifier>()
            func find(_ node: AnyObject) -> AnyObject? {
                guard visited.insert(ObjectIdentifier(node)).inserted else { return nil }
                if node.accessibilityIdentifier?() == id { return node }
                for child in node.accessibilityChildren?() ?? [] {
                    if let match = find(child as AnyObject) { return match }
                }
                return nil
            }
            return find(window).map { $0.accessibilityChildren?()?.count ?? 0 }
        }
        let deadline = ContinuousClock.now + .seconds(3)
        repeat {
            host.layoutSubtreeIfNeeded()
            if segments("usage-breakdown") == 2 { break }
            try await Task.sleep(for: .milliseconds(25))
        } while ContinuousClock.now < deadline
        XCTAssertEqual(segments("usage-period"), UsagePeriod.allCases.count)
        XCTAssertEqual(segments("usage-metric"), 3)
        XCTAssertEqual(segments("usage-breakdown"), 2)

        let rendered = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rendered)
        let requestText = VNRecognizeTextRequest()
        try VNImageRequestHandler(cgImage: XCTUnwrap(rendered.cgImage)).perform([requestText])
        let renderedText = requestText.results?.compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
        XCTAssertTrue(renderedText?.contains("480 tokens + unreported") == true, renderedText ?? "No settings text rendered")
        XCTAssertEqual(model.project?.id, fixture.ids.beta)
        XCTAssertEqual(model.effectiveModel.model, "usage-local")
        XCTAssertEqual(model.conversation?.composerText, "Preserve this usage fixture draft.")
        XCTAssertEqual(try Data(contentsOf: fixture.index), fixture.initialIndex)
    }

}

private struct UsageFixture {
    struct IDs: Decodable {
        let alpha: UUID
        let beta: UUID
        let now: Date
        let betaFile: URL
        let forkFile: URL

        private enum Field: String, CodingKey { case alpha, beta, now, betaFile, forkFile }

        init(from decoder: Decoder) throws {
            let fields = try decoder.container(keyedBy: Field.self)
            alpha = try fields.decode(UUID.self, forKey: .alpha)
            beta = try fields.decode(UUID.self, forKey: .beta)
            let timestamp = try fields.decode(String.self, forKey: .now)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions.insert(.withFractionalSeconds)
            now = try XCTUnwrap(formatter.date(from: timestamp))
            betaFile = URL(fileURLWithPath: try fields.decode(String.self, forKey: .betaFile))
            forkFile = URL(fileURLWithPath: try fields.decode(String.self, forKey: .forkFile))
        }
    }

    private final class Directory {
        let url = FileManager.default.temporaryDirectory.appending(path: "pi-usage-\(UUID().uuidString)")
        deinit { try? FileManager.default.removeItem(at: url) }
    }

    private let directory = Directory()
    var root: URL { directory.url }
    var index: URL { root.appendingPathComponent("workspace.json") }
    let ids: IDs
    let workspace: Workspace
    let initialIndex: Data

    init() throws {
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let sidecar = package.appendingPathComponent("Sidecar")
        try XCTSkipUnless(FileManager.default.fileExists(
            atPath: sidecar.appendingPathComponent("node_modules/@earendil-works/pi-coding-agent/package.json").path
        ), "Install PiWorkspace/Sidecar dependencies to run the Pi session fixture.")

        let node = Process()
        let output = Pipe()
        node.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        node.arguments = ["node", package.appendingPathComponent("scripts/fixtures/usage.mjs").path, directory.url.path]
        node.standardOutput = output
        try node.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        node.waitUntilExit()
        XCTAssertEqual(node.terminationStatus, 0)
        ids = try JSONDecoder().decode(IDs.self, from: data)
        let root = directory.url
        initialIndex = try Data(contentsOf: root.appendingPathComponent("workspace.json"))
        workspace = try WorkspaceStore(root: root).load()
    }

    func snapshot() async throws -> WorkspaceUsage {
        try await WorkspaceUsage.load(root: root, projects: workspace.projects, now: ids.now)
    }
}
