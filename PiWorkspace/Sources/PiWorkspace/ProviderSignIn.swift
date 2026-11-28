import AppKit
import Combine
import Foundation

struct ProviderLoginPrompt: Decodable, Equatable, Identifiable {
    enum Kind: String, Decodable { case text, secret, manual_code, select }
    struct Option: Decodable, Equatable, Identifiable {
        let id: String
        let label: String
    }
    let id: Int
    let kind: Kind
    let message: String
    let placeholder: String?
    let options: [Option]?
}

enum ProviderLoginEvent: Decodable {
    case codexStatus(CodexAccountStatus)
    case browser(String), device(String, String), prompt(ProviderLoginPrompt), dismissPrompt(Int)
    case progress, complete, error(String?)

    private enum Field: CodingKey { case type, state, step, url, code, id, message }
    private enum Step: String, Decodable { case browser, device, prompt, dismissPrompt, progress, complete, error }

    init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: Field.self)
        if try fields.decode(String.self, forKey: .type) == "codexStatus" {
            self = .codexStatus(try fields.decode(CodexAccountStatus.self, forKey: .state))
            return
        }
        switch try fields.decode(Step.self, forKey: .step) {
        case .browser: self = .browser(try fields.decode(String.self, forKey: .url))
        case .device: self = .device(try fields.decode(String.self, forKey: .url), try fields.decode(String.self, forKey: .code))
        case .prompt: self = .prompt(try ProviderLoginPrompt(from: decoder))
        case .dismissPrompt: self = .dismissPrompt(try fields.decode(Int.self, forKey: .id))
        case .progress: self = .progress
        case .complete: self = .complete
        case .error: self = .error(try fields.decodeIfPresent(String.self, forKey: .message))
        }
    }
}

@MainActor
final class ProviderSignIn: ObservableObject {
    struct Instructions {
        var url: URL?
        var deviceCode: String?
        var prompt: ProviderLoginPrompt?
    }

    private struct Start: Encodable {
        let type = "login"
        let provider: String
        let deviceID: UUID
        let method: String
    }
    private struct Answer: Encodable {
        let type = "answer"
        let id: Int
        let value: String
    }

    typealias Helper = PiJSONProcess<ProviderLoginEvent>
    private let makeHelper: @MainActor (URL) throws -> Helper
    private let makeCodexHelper: @MainActor (URL) throws -> Helper
    private let openBrowser: (URL) -> Bool
    private let deviceID: () -> UUID
    private var helper: Helper?
    @Published private(set) var instructions: Instructions?
    @Published private(set) var error: String?

    init(makeHelper: @escaping @MainActor (URL) throws -> Helper = { directory in
             try Helper(config: directory, cwd: directory.path, loginDirectory: directory, script: "login.mjs")
         }, makeCodexHelper: @escaping @MainActor (URL) throws -> Helper = { directory in
             try Helper(config: directory, cwd: directory.path, script: "codex-login.mjs")
         }, openBrowser: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) },
         deviceID: @escaping () -> UUID = {
             let key = "providerSignInDeviceID"
             if let saved = UserDefaults.standard.string(forKey: key), let id = UUID(uuidString: saved) { return id }
             let id = UUID()
             UserDefaults.standard.set(id.uuidString, forKey: key)
             return id
         }) {
        self.makeHelper = makeHelper
        self.makeCodexHelper = makeCodexHelper
        self.openBrowser = openBrowser
        self.deviceID = deviceID
    }

    func start(_ provider: Provider, logins: PiSavedLogins, codexWorkspace: URL? = nil, useCode: Bool = false,
               completed: @escaping (ModelSettings) -> Void) {
        guard helper == nil, let id = provider == .codexAgent ? provider.rawValue : provider.piProviderID else { return }
        error = nil
        do {
            let helper: Helper
            if provider == .codexAgent {
                guard let codexWorkspace else { throw WorkspaceError("Open a workspace to connect Codex.") }
                helper = try makeCodexHelper(codexWorkspace)
            } else {
                helper = try makeHelper(logins.directory)
            }
            self.helper = helper
            instructions = Instructions()
            helper.onClose = { [weak self, weak helper] in
                guard let self, let helper, self.helper === helper else { return }
                finish(error: String(localized: "Sign-in ended before it finished. Try again."))
            }
            helper.onEvent = { [weak self, weak helper] event in
                guard let self, let helper, self.helper === helper else { return }
                switch event {
                case .codexStatus: break
                case let .browser(url): showBrowser(url, code: nil)
                case let .device(url, code): showBrowser(url, code: code)
                case let .prompt(prompt): instructions?.prompt = prompt
                case let .dismissPrompt(id):
                    if instructions?.prompt?.id == id { instructions?.prompt = nil }
                case .progress: break
                case .complete:
                    if provider == .codexAgent {
                        finish()
                        completed(.codex)
                        return
                    }
                    guard let profile = logins.profiles().first(where: { $0.provider == provider }) else {
                        finish(error: String(localized: "Could not read the newly saved account. Try again."))
                        return
                    }
                    finish()
                    completed(profile)
                case .error(let message):
                    let description = switch message {
                    case "not_installed", "codex_not_found", "codex_not_installed": CodexAccountStatus.notInstalled.label
                    case "callback_unavailable": String(localized: "The browser callback is busy. Close the other sign-in and try again.")
                    case "credential_store_failed": String(localized: "Couldn’t save this account. Check write access to your account settings and try again.")
                    default: String(localized: "Couldn’t complete sign-in. Try again.")
                    }
                    finish(error: description)
                }
            }
            try helper.send(Start(provider: id, deviceID: deviceID(), method: useCode ? "code" : "browser"))
        } catch {
            finish(error: String(localized: "Could not start sign-in. Check the app installation and try again."))
        }
    }

    private func showBrowser(_ address: String, code: String?) {
        guard let url = URL(string: address), url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else {
            finish(error: String(localized: "The service returned an invalid sign-in address."))
            return
        }
        let alreadyOpened = instructions?.url == url
        instructions?.url = url
        instructions?.deviceCode = code
        if !alreadyOpened { reopenBrowser() }
    }

    func reopenBrowser() {
        guard let url = instructions?.url else { return }
        error = openBrowser(url) ? nil : String(localized: "Could not open the browser. Try opening the sign-in page again.")
    }

    func answer(_ prompt: ProviderLoginPrompt, with value: String) {
        guard let helper, instructions?.prompt == prompt else { return }
        do {
            try helper.send(Answer(id: prompt.id, value: value))
            instructions?.prompt = nil
        } catch {
            finish(error: String(localized: "Sign-in ended before it finished. Try again."))
        }
    }

    func cancel() {
        if let helper { try? helper.send(["type": "cancel"]) }
        finish()
    }

    private func finish(error: String? = nil) {
        helper?.close()
        helper = nil
        instructions = nil
        self.error = error
    }
}
