import Foundation
import Observation

@MainActor @Observable
final class WorkspaceFileSaves {
    private var sessions: [WorkspaceFileTarget: WorkspaceFileSaveSession] = [:]
    @ObservationIgnored private var pdfPositions: [(WorkspaceFileTarget, WorkspacePDFPosition)] = []

    func pdfPosition(for target: WorkspaceFileTarget) -> WorkspacePDFPosition? {
        pdfPositions.last { $0.0 == target }?.1
    }

    func rememberPDFPosition(_ position: WorkspacePDFPosition, for target: WorkspaceFileTarget) {
        pdfPositions.removeAll { $0.0 == target }
        if pdfPositions.count == 50 { pdfPositions.removeFirst() }
        pdfPositions.append((target, position))
    }

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

    func pendingFiles(for threadID: UUID) -> [WorkspaceFileSaveSession] {
        sessions.values.filter { $0.target.location.threadID == threadID && $0.draft != nil }
            .sorted { ($0.target.location.directory, $0.target.path) < ($1.target.location.directory, $1.target.path) }
    }

    func recoverMovedDrafts(in location: WorkspaceFilesLocation) {
        let candidates = pendingFiles(for: location.threadID).filter { $0.target.location != location }
        guard !candidates.isEmpty,
              let checkout = try? WorkspaceFiles(directory: location.directory).directoryIdentity() else { return }
        for session in candidates {
            let target = WorkspaceFileTarget(location: location, path: session.target.path)
            guard let draft = session.draft, draft.original.checkout == checkout, sessions[target] == nil else { continue }
            sessions[session.target] = nil
            sessions[target] = session
            session.move(draft, to: target)
        }
    }

    func hasDraft(for target: WorkspaceFileTarget) -> Bool { sessions[target]?.draft != nil }

    func flushAll() -> String? {
        var firstFailure: String?
        for session in Array(sessions.values) {
            if let error = session.flush(), firstFailure == nil {
                let target = session.target
                firstFailure = "Couldn’t save \(target.path) in \(target.location.directory). \(error.localizedDescription) " +
                    "To recover the edits, open Files in that thread and choose Folder Actions > Unsaved Files."
            }
        }
        return firstFailure
    }

    private func removeIfIdle(_ session: WorkspaceFileSaveSession) {
        if session.leases == 0, session.draft == nil, sessions[session.target] === session {
            sessions[session.target] = nil
        }
    }
}

@MainActor @Observable
final class WorkspaceFileSaveSession {
    struct EditorSource {
        fileprivate let original: WorkspaceFileText
        fileprivate let generation: Int

        var text: String { original.text }
    }

    private(set) var target: WorkspaceFileTarget
    private(set) var preview: Result<WorkspaceFilePreview, Error>?
    private(set) var draft: WorkspaceFileDraft?
    private(set) var saveError: Error?
    private var editorGeneration = 0
    @ObservationIgnored fileprivate var leases = 0
    @ObservationIgnored private var readRequest: UUID?
    @ObservationIgnored private var pending: Task<Void, Never>?
    private let draftCleared: (WorkspaceFileSaveSession) -> Void

    fileprivate init(target: WorkspaceFileTarget, draftCleared: @escaping (WorkspaceFileSaveSession) -> Void) {
        self.target = target
        self.draftCleared = draftCleared
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

    fileprivate func move(_ draft: WorkspaceFileDraft, to destination: WorkspaceFileTarget) {
        readRequest = nil
        target = destination
        self.draft = WorkspaceFileDraft(target: destination, original: draft.original, text: draft.text)
        flush()
    }

    func discard() {
        clearDraft()
        preview = nil
        readRequest = nil
        draftCleared(self)
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
            draftCleared(self)
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
