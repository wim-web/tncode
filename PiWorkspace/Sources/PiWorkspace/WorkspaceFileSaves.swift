import Foundation
import Observation

@MainActor @Observable
final class WorkspaceFileSaves {
    private var sessions: [WorkspaceFileTarget: WorkspaceFileSaveSession] = [:]

    func acquire(_ target: WorkspaceFileTarget) -> WorkspaceFileSaveSession {
        if let session = sessions[target] {
            session.leases += 1
            return session
        }
        let session = WorkspaceFileSaveSession(target: target) { [weak self] session in
            self?.removeIfIdle(session)
        }
        session.leases = 1
        sessions[target] = session
        return session
    }

    func release(_ session: WorkspaceFileSaveSession) {
        session.leases -= 1
        guard session.leases == 0 else { return }
        session.flush()
        removeIfIdle(session)
    }

    func paths(in location: WorkspaceFilesLocation) -> [String] {
        sessions.values.compactMap { session in
            session.target.location == location && session.draft != nil ? session.target.path : nil
        }.sorted()
    }

    func hasDraft(for target: WorkspaceFileTarget) -> Bool { sessions[target]?.draft != nil }

    func flushAll() -> String? {
        var firstFailure: String?
        for session in Array(sessions.values) {
            if let error = session.flush(), firstFailure == nil {
                let target = session.target
                firstFailure = "Couldn’t save \(target.path) in \(target.location.directory). \(error.localizedDescription)"
            }
        }
        return firstFailure
    }

    private func removeIfIdle(_ session: WorkspaceFileSaveSession) {
        if session.leases == 0, session.draft == nil { sessions[session.target] = nil }
    }
}

@MainActor @Observable
final class WorkspaceFileSaveSession {
    struct EditorSource {
        fileprivate let original: WorkspaceFileText
        fileprivate let generation: Int

        var text: String { original.text }
    }

    let target: WorkspaceFileTarget
    private(set) var preview: Result<WorkspaceFilePreview, Error>?
    private(set) var draft: WorkspaceFileDraft?
    private(set) var saveError: Error?
    private var editorGeneration = 0
    @ObservationIgnored fileprivate var leases = 0
    @ObservationIgnored private var readRequest: UUID?
    @ObservationIgnored private var pending: Task<Void, Never>?
    private let didSave: (WorkspaceFileSaveSession) -> Void

    fileprivate init(target: WorkspaceFileTarget, didSave: @escaping (WorkspaceFileSaveSession) -> Void) {
        self.target = target
        self.didSave = didSave
    }

    var diskText: WorkspaceFileText? {
        if case .success(.text(let text)) = preview { return text }
        return nil
    }

    var editorSource: EditorSource? {
        (draft?.original ?? diskText).map { EditorSource(original: $0, generation: editorGeneration) }
    }

    var isReadOnly: Bool {
        if saveError?.deniesFileAccess == true { return true }
        if draft != nil, case .failure(let error) = preview, error.deniesFileAccess { return true }
        return diskText?.writable == false
    }

    var changedOnDisk: Bool {
        guard let draft else { return false }
        switch saveError as? WorkspaceFileError {
        case .changed, .missing, .unsupportedPath: return true
        default: break
        }
        if case .failure(let error) = preview, error.deniesFileAccess { return false }
        return preview != nil && diskText?.matches(draft.original) != true
    }

    var isEditable: Bool { diskText?.writable == true && !isReadOnly && !changedOnDisk }

    func refresh() async {
        let request = UUID()
        readRequest = request
        let target = target
        let result: Result<WorkspaceFilePreview, Error>
        do {
            result = .success(try await loadWorkspaceFiles {
                try WorkspaceFiles(directory: target.location.directory).preview(target.path)
            })
        } catch {
            result = .failure(error)
        }
        guard !Task.isCancelled, readRequest == request else { return }
        if draft == nil { editorGeneration += 1 }
        preview = result
        if saveError != nil, pending == nil { flush() }
    }

    func edit(_ text: String, from source: EditorSource) {
        guard leases > 0 else { return }
        // A successful save advances the baseline even before SwiftUI updates the editor.
        // A separate disk refresh must leave edits from the previous display based on that display.
        let current = source.generation == editorGeneration ? diskText : nil
        let edited = WorkspaceFileDraft(target: target, original: draft?.original ?? current ?? source.original, text: text)
        if edited.isEdited {
            draft = edited
            schedule()
        } else {
            clearDraft()
        }
    }

    func discard() {
        clearDraft()
        preview = nil
        readRequest = nil
    }

    @discardableResult
    func flush() -> Error? {
        pending?.cancel()
        pending = nil
        guard let draft else { return nil }
        do {
            let saved = try draft.save()
            readRequest = nil
            preview = .success(.text(saved))
            clearDraft()
            didSave(self)
            return nil
        } catch {
            saveError = error
            if error.deniesFileAccess { schedule() }
            return error
        }
    }

    private func clearDraft() {
        pending?.cancel()
        pending = nil
        draft = nil
        saveError = nil
    }

    private func schedule() {
        pending?.cancel()
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(500))
        pending = Task { [weak self] in
            do { try await Task.sleep(until: deadline, clock: .continuous) }
            catch { return }
            guard let self, !Task.isCancelled else { return }
            pending = nil
            flush()
        }
    }
}

private extension Error {
    var deniesFileAccess: Bool {
        if self as? WorkspaceFileError == .readOnly { return true }
        switch (self as? POSIXError)?.code {
        case .EACCES, .EPERM, .EROFS: return true
        default: return false
        }
    }
}

func loadWorkspaceFiles<Value: Sendable>(_ operation: @escaping @Sendable () throws -> Value) async throws -> Value {
    let task = Task.detached(priority: .userInitiated, operation: operation)
    return try await withTaskCancellationHandler {
        try await task.value
    } onCancel: {
        task.cancel()
    }
}
