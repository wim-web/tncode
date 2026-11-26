import CoreTransferable
import Darwin
import Foundation
import XCTest
@testable import PiWorkspace

@MainActor
final class ProjectSourcesTests: XCTestCase {
    func testProjectStartPreferenceAndWelcomePreserveWorkspaceSelection() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let alphaFolder = root.appendingPathComponent("Alpha")
        let betaFolder = root.appendingPathComponent("Beta")
        let startFolder = root.appendingPathComponent("Project Fixtures")
        for folder in [alphaFolder, betaFolder, startFolder] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        }

        let alphaID: UUID
        let betaID: UUID
        let betaThread: UUID
        do {
            let model = workspace(in: root)
            XCTAssertTrue(model.showingWelcome)
            model.openFolder()
            XCTAssertEqual(model.projectPicker?.initialPath, "~/")
            model.projectPicker = nil
            XCTAssertTrue(model.showingWelcome)
            XCTAssertTrue(model.projects.isEmpty)
            try model.updateAddProjectBaseDirectory(startFolder.path)
            model.openFolder()
            XCTAssertEqual(model.projectPicker?.initialPath, startFolder.path + "/")
            model.projectPicker = nil
            model.finishWelcome()
            XCTAssertFalse(model.showingWelcome)

            try model.openProject(alphaFolder)
            alphaID = try XCTUnwrap(model.project?.id)
            model.draft = "Alpha's draft"
            try model.openProject(betaFolder)
            betaID = try XCTUnwrap(model.project?.id)
            betaThread = try XCTUnwrap(model.conversation?.id)
            model.draft = "Beta's unfinished message"

            model.openWelcome()
            XCTAssertTrue(model.showingWelcome)
            model.openFolder()
            XCTAssertEqual(model.projectPicker?.initialPath, startFolder.path + "/")
            XCTAssertEqual(model.projectPicker?.basePath, betaFolder.path)
            model.projectPicker = nil
            model.finishWelcome()
            XCTAssertFalse(model.showingWelcome)
            XCTAssertEqual(model.workspace.selectedProject, betaID)
            XCTAssertEqual(model.conversation?.id, betaThread)
            XCTAssertEqual(model.draft, "Beta's unfinished message")
            XCTAssertTrue(model.terminate())
        }

        let restored = workspace(in: root)
        restored.start()
        XCTAssertFalse(restored.showingWelcome)
        XCTAssertEqual(restored.workspace.addProjectBaseDirectory, startFolder.path)
        XCTAssertEqual(restored.workspace.selectedProject, betaID)
        XCTAssertEqual(restored.conversation?.id, betaThread)
        XCTAssertEqual(restored.draft, "Beta's unfinished message")
        restored.selectProject(alphaID)
        restored.openFolder()
        XCTAssertEqual(restored.projectPicker?.initialPath, startFolder.path + "/")
        XCTAssertEqual(restored.projectPicker?.basePath, alphaFolder.path)
        XCTAssertEqual(restored.draft, "Alpha's draft")
        restored.projectPicker = nil

        restored.openFolder(relinking: betaID)
        XCTAssertEqual(restored.projectPicker?.initialPath, betaFolder.path)
        restored.projectPicker = nil
        try restored.updateAddProjectBaseDirectory("  ")
        restored.openFolder()
        XCTAssertEqual(restored.projectPicker?.initialPath, "~/")
        XCTAssertEqual(restored.workspace.selectedProject, alphaID)
    }

    func testDiscardOnlyRemovesTheOwnedEmptyScratchDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = try WorkspaceStore(root: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let scratch = try store.makeScratchProject(for: Conversation(id: UUID(), title: "New thread"))
        let other = root.appendingPathComponent("unrelated")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: false)
        var stale = scratch
        stale.path = other.path
        store.discardEmptyScratchFolder(stale)
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path))
        store.discardEmptyScratchFolder(scratch)
        XCTAssertFalse(FileManager.default.fileExists(atPath: scratch.path))
    }

    func testRelativeFolderAndDropReuseTheSameProject() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("Project", isDirectory: true)
        let child = project.appendingPathComponent("Child #1", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        let alias = root.appendingPathComponent("Alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: child)
        let file = root.appendingPathComponent("notes")
        try Data().write(to: file)
        let dropped = root.appendingPathComponent("Dropped Folder", isDirectory: true)
        try FileManager.default.createDirectory(at: dropped, withIntermediateDirectories: false)
        let model = workspace(in: root)

        XCTAssertThrowsError(try ProjectFolder.resolve("Child #1", relativeTo: nil))
        try model.openProject(project)
        model.openFolder()
        let request = try XCTUnwrap(model.projectPicker)
        let badPath = try ProjectFolder.resolve("missing", relativeTo: request.basePath)
        XCTAssertThrowsError(try model.openProject(badPath, request: request))
        XCTAssertEqual(model.project?.path, project.path)

        let relative = try ProjectFolder.resolve("Child #1", relativeTo: request.basePath)
        try await model.openProject(.localFolder(relative), request: request)
        let selected = try XCTUnwrap(model.project)
        let draft = try XCTUnwrap(model.conversation)
        XCTAssertEqual(selected.path, child.path)
        XCTAssertEqual(draft.isDraft, true)

        XCTAssertFalse(try model.openDroppedProjects([file]))
        let provider = NSItemProvider(object: dropped as NSURL)
        let transferred = try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadTransferable(type: DroppedProjectFolder.self) { continuation.resume(with: $0) }
        }
        XCTAssertTrue(try model.openDroppedProjects([file, transferred.url]))
        XCTAssertEqual(model.project?.path, dropped.path)
        XCTAssertEqual(model.conversation?.isDraft, true)
        XCTAssertTrue(try model.openDroppedProjects([file, alias]))
        XCTAssertEqual(model.projects.count, 3)
        XCTAssertEqual(model.project?.id, selected.id)
        XCTAssertEqual(model.conversation?.id, draft.id)

        let data = try Data(contentsOf: root.appendingPathComponent("workspace/workspace.json"))
        let saved = try JSONDecoder().decode(Workspace.self, from: data)
        XCTAssertEqual(saved.selectedProject, selected.id)
        XCTAssertEqual(saved.projects.first { $0.id == selected.id }?.selectedConversation, draft.id)
    }

    func testNewProjectInitializesAnEmptyGitRepositoryAndOpensADraft() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = workspace(in: root)
        model.openFolder()
        let request = try XCTUnwrap(model.projectPicker)

        try await model.openProject(.newProject(name: "Fresh Repo", parent: root), request: request)

        let folder = root.appendingPathComponent("Fresh Repo", isDirectory: true)
        let state = try await GitWorkspace(path: folder.path).state()
        XCTAssertNotNil(state.branch)
        XCTAssertTrue(state.branches.isEmpty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [".git"])
        XCTAssertEqual(model.project?.path, folder.path)
        XCTAssertEqual(model.conversation?.isDraft, true)
        XCTAssertEqual(model.projects.count, 1)
    }

    func testCreationRejectsInvalidNamesAndLeavesExistingDestinationsUntouched() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let existing = root.appendingPathComponent("existing", isDirectory: true)
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: false)
        let marker = existing.appendingPathComponent("marker")
        let original = Data("keep".utf8)
        try original.write(to: marker)
        let empty = root.appendingPathComponent("empty", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: false)
        let file = root.appendingPathComponent("file")
        try original.write(to: file)
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: existing)
        let model = workspace(in: root)
        model.openFolder()
        let request = try XCTUnwrap(model.projectPicker)

        for name in ["  ", "..", "sub/folder", "existing", "empty", "file", "link"] {
            do {
                try await model.openProject(.newProject(name: name, parent: root), request: request)
                XCTFail("Accepted invalid or occupied name \(name.debugDescription)")
            } catch {}
        }

        XCTAssertTrue(model.projects.isEmpty)
        XCTAssertEqual(try Data(contentsOf: marker), original)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: empty.path).isEmpty)
        XCTAssertEqual(try Data(contentsOf: file), original)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), existing.path)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)),
                       ["existing", "empty", "file", "link", "workspace"])
    }

    func testRegistrationFailureKeepsTheNewRepository() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = workspace(in: root)
        model.openFolder()
        let request = try XCTUnwrap(model.projectPicker)
        let index = root.appendingPathComponent("workspace/workspace.json", isDirectory: true)
        try FileManager.default.createDirectory(at: index, withIntermediateDirectories: false)

        do {
            try await model.openProject(.newProject(name: "Recover", parent: root), request: request)
            XCTFail("Registered a project when the workspace index could not be written")
        } catch {}

        let folder = root.appendingPathComponent("Recover", isDirectory: true)
        let state = try await GitWorkspace(path: folder.path).state()
        XCTAssertNotNil(state.branch)
        XCTAssertTrue(model.projects.isEmpty)
        try FileManager.default.removeItem(at: index)
        try await model.openProject(.localFolder(folder), request: request)
        XCTAssertEqual(model.project?.path, folder.path)
    }

    func testCloneFromFileURLRegistersTheCheckoutAndReopensItsDraft() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try await makeCloneSource(in: root)
        let bare = root.appendingPathComponent("Fixture Remote.git")
        _ = try await git(["clone", "--bare", "--", source.path, bare.path], in: root)
        let remote = try ProjectCloneRemote(bare.absoluteString, relativeTo: nil)
        XCTAssertEqual(remote.suggestedName, "Fixture Remote")
        let destination = root.appendingPathComponent("missing/nested/Selected copy", isDirectory: true)
        let projectID: UUID
        let draftID: UUID
        do {
            let model = workspace(in: root)
            model.openFolder()
            let request = try XCTUnwrap(model.projectPicker)

            try await model.openProject(.clone(remote, destination: destination), request: request)

            let project = try XCTUnwrap(model.project)
            let draft = try XCTUnwrap(model.conversation)
            projectID = project.id
            draftID = draft.id
            XCTAssertEqual(project.title, "Selected copy")
            XCTAssertEqual(project.path, destination.path)
            XCTAssertEqual(draft.isDraft, true)
            XCTAssertEqual(model.workingDirectory, destination.path)
            XCTAssertTrue(model.terminate())
        }
        let sourceHead = try await git(["rev-parse", "HEAD"], in: source)
        let clonedHead = try await git(["rev-parse", "HEAD"], in: destination)
        let branch = try await git(["branch", "--show-current"], in: destination)
        let origin = try await git(["remote", "get-url", "origin"], in: destination)
        XCTAssertEqual(clonedHead, sourceHead)
        XCTAssertEqual(branch, "fixture-default")
        XCTAssertEqual(origin, remote.argument)
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("README.md")),
                       try Data(contentsOf: source.appendingPathComponent("README.md")))

        let reopened = workspace(in: root)
        XCTAssertNil(reopened.startupFailure)
        reopened.start()
        defer { reopened.terminate() }
        XCTAssertEqual(reopened.projects.map(\.id), [projectID])
        XCTAssertEqual(reopened.project?.id, projectID)
        XCTAssertEqual(reopened.conversation?.id, draftID)
        XCTAssertEqual(reopened.workingDirectory, destination.path)
    }

    func testCloneIntoEmptyDirectoryPreservesDirectoryAndRegisteredProject() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try await makeCloneSource(in: root)
        let bare = root.appendingPathComponent("remote.git")
        _ = try await git(["clone", "--bare", "--", source.path, bare.path], in: root)
        let remote = try ProjectCloneRemote(bare.absoluteString, relativeTo: nil)
        let files = FileManager.default
        let model = workspace(in: root)

        for registered in [false, true] {
            let target = root.appendingPathComponent(registered ? "Existing project" : "Empty folder", isDirectory: true)
            try files.createDirectory(at: target, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o750])
            let original = try files.attributesOfItem(atPath: target.path)
            if registered { try model.openProject(target) }
            let projects = model.projects.map(\.id)
            let draft = model.conversation?.id
            model.openFolder()
            let request = try XCTUnwrap(model.projectPicker)
            let ignoresCase = try root.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames == false
            let input = registered && ignoresCase ? root.appendingPathComponent("existing project") : target
            try await model.openProject(.clone(remote, destination: input), request: request)

            let after = try files.attributesOfItem(atPath: target.path)
            for key in [FileAttributeKey.systemFileNumber, .posixPermissions] {
                XCTAssertEqual(after[key] as? NSNumber, original[key] as? NSNumber)
            }
            let expected = try await git(["rev-parse", "HEAD"], in: bare)
            let actual = try await git(["rev-parse", "HEAD"], in: target)
            XCTAssertEqual(actual, expected)
            XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent("README.md")),
                           try Data(contentsOf: source.appendingPathComponent("README.md")))
            XCTAssertEqual(model.project?.path, target.path)
            if registered {
                XCTAssertEqual(model.projects.map(\.id), projects)
                XCTAssertEqual(model.conversation?.id, draft)
            }
        }
    }

    func testCloneRefusesOccupiedPathsAndAMissingRegisteredDestination() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try await makeCloneSource(in: root)
        let remote = try ProjectCloneRemote(source.absoluteString, relativeTo: nil)
        let destination = root.appendingPathComponent("Previous", isDirectory: true)
        let file = root.appendingPathComponent("File")
        try Data("keep".utf8).write(to: file)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        let model = workspace(in: root)
        try model.openProject(destination)
        let previous = try XCTUnwrap(model.project)
        let draft = try XCTUnwrap(model.conversation)
        try FileManager.default.moveItem(at: destination, to: root.appendingPathComponent("Moved"))
        let link = root.appendingPathComponent("Dangling")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: destination)
        let linkedFolder = root.appendingPathComponent("Link to empty folder")
        try FileManager.default.createSymbolicLink(at: linkedFolder, withDestinationURL: root.appendingPathComponent("Moved"))
        model.openFolder()
        let request = try XCTUnwrap(model.projectPicker)
        let entries = Set(try FileManager.default.contentsOfDirectory(atPath: root.path))

        for target in [source, file, file.appendingPathComponent("child"), link, linkedFolder, destination] {
            do {
                try await model.openProject(.clone(remote, destination: target), request: request)
                XCTFail("Accepted occupied destination \(target.lastPathComponent)")
            } catch {}
        }

        XCTAssertEqual(model.projects.map(\.id), [previous.id])
        XCTAssertEqual(model.project?.path, previous.path)
        XCTAssertEqual(model.conversation?.id, draft.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(try Data(contentsOf: file), Data("keep".utf8))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), destination.path)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)), entries)
    }

    func testCloneRefusesForeignAdditionsAndAReplacedEmptyDirectoryAtPublication() async throws {
        let root = try temporaryDirectory()
        let files = FileManager.default
        defer { try? files.removeItem(at: root) }
        let source = try await makeCloneSource(in: root)
        let folder = root.appendingPathComponent("Empty", isDirectory: true)
        try files.createDirectory(at: folder, withIntermediateDirectories: false)
        let marker = folder.appendingPathComponent(".foreign")
        let payload = Data("created after destination validation".utf8)
        let target = try GitWorkspace.CloneDestination(folder)
        try payload.write(to: marker)
        do {
            _ = try await GitWorkspace.cloneRepository(from: source.path, to: target)
            XCTFail("Published into a destination that became occupied")
        } catch {}
        XCTAssertEqual(try files.contentsOfDirectory(atPath: folder.path), [".foreign"])
        XCTAssertEqual(try Data(contentsOf: marker), payload)

        let moved = root.appendingPathComponent("Moved")
        try files.moveItem(at: folder, to: moved)
        try files.createDirectory(at: folder, withIntermediateDirectories: false)
        do {
            _ = try await GitWorkspace.cloneRepository(from: source.path, to: target)
            XCTFail("Published into a replacement directory")
        } catch {}
        XCTAssertTrue(try files.contentsOfDirectory(atPath: folder.path).isEmpty)
        XCTAssertEqual(try files.contentsOfDirectory(atPath: moved.path), [".foreign"])
        XCTAssertEqual(try Data(contentsOf: moved.appendingPathComponent(".foreign")), payload)
    }

    func testCloneFailureCleansTheStageAndCanBeRetried() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try await makeCloneSource(in: root)
        let missing = root.appendingPathComponent("missing.git")
        let destination = root.appendingPathComponent("Copy", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        let original = try FileManager.default.attributesOfItem(atPath: destination.path)
        let remote = try ProjectCloneRemote(missing.absoluteString, relativeTo: nil)
        let model = workspace(in: root)
        try model.openProject(repo)
        let project = try XCTUnwrap(model.project)
        let draft = try XCTUnwrap(model.conversation)
        model.openFolder()
        let request = try XCTUnwrap(model.projectPicker)
        let entries = Set(try FileManager.default.contentsOfDirectory(atPath: root.path))

        do {
            try await model.openProject(.clone(remote, destination: destination), request: request)
            XCTFail("Cloned a nonexistent repository")
        } catch {}

        XCTAssertEqual(model.projects.map(\.id), [project.id])
        XCTAssertEqual(model.project?.id, project.id)
        XCTAssertEqual(model.conversation?.id, draft.id)
        XCTAssertFalse(model.gitMutationInProgress)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)), entries)

        let after = try FileManager.default.attributesOfItem(atPath: destination.path)
        XCTAssertEqual(after[.systemFileNumber] as? NSNumber, original[.systemFileNumber] as? NSNumber)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
        try await model.openProject(.clone(try ProjectCloneRemote(repo.absoluteString, relativeTo: nil),
                                           destination: destination), request: request)
        XCTAssertEqual(model.project?.path, destination.path)
    }

    func testCancellingAnActiveCloneRemovesItsStageAndPreservesSelection() async throws {
        try await verifyActiveCloneCancellation(quitting: false)
    }

    func testQuittingCancelsTheCloneAndWaitsForCleanup() async throws {
        try await verifyActiveCloneCancellation(quitting: true)
    }

    private func verifyActiveCloneCancellation(quitting: Bool) async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try await makeCloneSource(in: root)
        let bare = root.appendingPathComponent("retry.git")
        if !quitting { _ = try await git(["clone", "--bare", "--", source.path, bare.path], in: root) }
        let head = try await git(["rev-parse", "HEAD"], in: source)
        let commit = source.appendingPathComponent(".git/objects/\(head.prefix(2))/\(head.dropFirst(2))")
        // The local upload-pack blocks opening this loose object until a writer opens the FIFO.
        try FileManager.default.removeItem(at: commit)
        XCTAssertEqual(mkfifo(commit.path, 0o600), 0)
        let model = workspace(in: root)
        try model.openProject(source)
        let project = try XCTUnwrap(model.project)
        let draft = try XCTUnwrap(model.conversation)
        model.openFolder()
        let request = try XCTUnwrap(model.projectPicker)
        let remote = try ProjectCloneRemote(source.absoluteString, relativeTo: nil)
        let destination = root.appendingPathComponent("Cancelled", isDirectory: true)
        if !quitting {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        }
        let entries = Set(try FileManager.default.contentsOfDirectory(atPath: root.path))

        let clone = Task { try await model.openProject(.clone(remote, destination: destination), request: request) }
        defer { clone.cancel() }
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(5)
        var launched = false
        while clock.now < deadline {
            let stageParent = quitting ? root : destination
            let contents = try FileManager.default.contentsOfDirectory(atPath: stageParent.path)
            if contents.contains(where: {
                $0.hasPrefix(".pi-workspace-") &&
                    FileManager.default.fileExists(atPath: stageParent.appendingPathComponent($0 + "/.git/HEAD").path)
            }) {
                launched = true
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(launched)
        XCTAssertTrue(model.gitMutationInProgress)
        let moved = root.appendingPathComponent("Moved during clone")
        let foreign = Data("written during clone".utf8)
        if !quitting {
            try foreign.write(to: destination.appendingPathComponent("README.md"))
            try FileManager.default.moveItem(at: destination, to: moved)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
            try foreign.write(to: destination.appendingPathComponent("replacement"))
        }
        let stopped = expectation(description: "Git and its transport stopped")
        Task {
            defer { stopped.fulfill() }
            do {
                try await clone.value
                XCTFail("A cancelled clone was registered")
            } catch is CancellationError {
            } catch {
                XCTFail("Expected cancellation, got \(error)")
            }
        }
        if quitting {
            let termination = try XCTUnwrap(model.cancelProjectCloneForQuit())
            if case .failure(let error) = await termination.result {
                XCTAssertTrue(error is CancellationError)
            } else {
                XCTFail("The clone finished before quit could cancel it")
            }
        } else {
            clone.cancel()
        }
        await fulfillment(of: [stopped], timeout: 5)
        if !quitting {
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: moved.path), ["README.md"])
            XCTAssertEqual(try Data(contentsOf: moved.appendingPathComponent("README.md")), foreign)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path), ["replacement"])
            XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("replacement")), foreign)
            try FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: moved, to: destination)
        }
        XCTAssertFalse(model.gitMutationInProgress)
        XCTAssertEqual(model.projects.map(\.id), [project.id])
        XCTAssertEqual(model.conversation?.id, draft.id)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)), entries)
        if !quitting {
            try FileManager.default.removeItem(at: destination.appendingPathComponent("README.md"))
            let retry = try ProjectCloneRemote(bare.absoluteString, relativeTo: nil)
            try await model.openProject(.clone(retry, destination: destination), request: request)
            XCTAssertEqual(model.project?.path, destination.path)
            let cloned = try await git(["rev-parse", "HEAD"], in: destination)
            XCTAssertEqual(cloned, head)
        }
    }

    func testFailedCloneRegistrationLeavesTheCompleteRepositoryForLocalFolder() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try await makeCloneSource(in: root)
        let remote = try ProjectCloneRemote(source.absoluteString, relativeTo: nil)
        let model = workspace(in: root)
        model.openFolder()
        let request = try XCTUnwrap(model.projectPicker)
        let index = root.appendingPathComponent("workspace/workspace.json", isDirectory: true)
        try FileManager.default.createDirectory(at: index, withIntermediateDirectories: false)
        let destination = root.appendingPathComponent("Recover", isDirectory: true)
        do {
            try await model.openProject(.clone(remote, destination: destination), request: request)
            XCTFail("Registered a clone when the workspace index could not be written")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains(destination.path))
            XCTAssertTrue(error.localizedDescription.contains("Local folder"))
        }
        let original = try await git(["rev-parse", "HEAD"], in: source)
        let cloned = try await git(["rev-parse", "HEAD"], in: destination)
        XCTAssertEqual(cloned, original)
        XCTAssertTrue(model.projects.isEmpty)

        try FileManager.default.removeItem(at: index)
        try await model.openProject(.localFolder(destination), request: request)
        XCTAssertEqual(model.project?.path, destination.path)
        XCTAssertEqual(model.conversation?.isDraft, true)
    }

    private func makeCloneSource(in root: URL) async throws -> URL {
        let source = root.appendingPathComponent("Fixture Source.git", isDirectory: true)
        _ = try await git(["init", "-b", "fixture-default", "--template=", source.path], in: root)
        try Data("Disposable clone fixture\n".utf8).write(to: source.appendingPathComponent("README.md"))
        _ = try await git(["add", "--", "README.md"], in: source)
        _ = try await git(["-c", "user.name=Clone Fixture", "-c", "user.email=fixture@example.invalid",
                           "commit", "--no-gpg-sign", "-m", "Fixture content"], in: source)
        return source
    }

    private func git(_ arguments: [String], in folder: URL) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", folder.path] + arguments
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        process.environment = environment
        let result = try await WorkspaceCommand.capture(process, outputLimit: 4 * 1024)
        guard result.status == 0 else { throw WorkspaceError(result.errorMessage) }
        return String(decoding: result.output.bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root.resolvingSymlinksInPath()
    }

    private func workspace(in root: URL) -> WorkspaceModel {
        WorkspaceModel(root: root.appendingPathComponent("workspace", isDirectory: true),
                       keychainService: "dev.piworkspace.project-sources-test",
                       readCredential: { _ in nil },
                       makeProcess: { _, _ in throw WorkspaceError("The project fixture does not open Pi.") })
    }
}
