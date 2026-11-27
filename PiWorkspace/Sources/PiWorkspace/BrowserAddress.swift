import Darwin
import Foundation
import Network

struct BrowserSearchSettings: Equatable {
    enum Engine: String, CaseIterable {
        case duckDuckGo = "DuckDuckGo"
        case google = "Google"
        case bing = "Bing"
        case brave = "Brave Search"
        case kagi = "Kagi"
        case ecosia = "Ecosia"
        case custom = "Custom"

        var template: String {
            switch self {
            case .duckDuckGo, .custom: "https://duckduckgo.com/?q=%s"
            case .google: "https://www.google.com/search?q=%s"
            case .bing: "https://www.bing.com/search?q=%s"
            case .brave: "https://search.brave.com/search?q=%s"
            case .kagi: "https://kagi.com/search?q=%s"
            case .ecosia: "https://www.ecosia.org/search?q=%s"
            }
        }
    }

    private static let defaultsKey = "browserSearchSettings"
    static let maximumTemplateLength = 2048

    enum TemplateIssue: String {
        case incomplete = "Enter an HTTP or HTTPS URL containing %s. Searches use DuckDuckGo until then."
        case tooLong = "Use up to 2,048 characters for the search URL."
        case credentials = "Remove the username and password from the search URL."
    }

    var engine: Engine = .duckDuckGo
    var customURL = ""

    private var trimmedCustomURL: String {
        customURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var templateIssue: TemplateIssue? {
        let template = trimmedCustomURL
        guard template.utf16.count <= Self.maximumTemplateLength else { return .tooLong }
        let example = template.replacingOccurrences(of: "%s", with: "a")
        if let parts = URLComponents(string: example), parts.user != nil || parts.password != nil {
            return .credentials
        }
        return BrowserAddress.isValidSearchTemplate(template) ? nil : .incomplete
    }

    var canSave: Bool {
        guard engine == .custom, let issue = templateIssue else { return true }
        return issue == .incomplete
    }

    var searchTemplate: String {
        engine == .custom && templateIssue == nil ? trimmedCustomURL : engine.template
    }

    static func load(from defaults: UserDefaults = .standard) -> Self {
        let saved = defaults.dictionary(forKey: defaultsKey)
        let engine = (saved?["engine"] as? String).flatMap(Engine.init(rawValue:)) ?? .duckDuckGo
        return Self(engine: engine, customURL: saved?["customURL"] as? String ?? "")
    }

    @discardableResult
    func save(to defaults: UserDefaults = .standard) -> Bool {
        guard canSave else { return false }
        let template = trimmedCustomURL
        let useEditedTemplate = engine == .custom || template.isEmpty || BrowserAddress.isValidSearchTemplate(template)
        let savedTemplate = useEditedTemplate ? template : Self.load(from: defaults).customURL
        defaults.set([
            "engine": engine.rawValue,
            "customURL": savedTemplate
        ], forKey: Self.defaultsKey)
        return true
    }
}

enum BrowserAddress {
    private static let nonWebSchemes: Set<String> = [
        "about", "blob", "chrome", "data", "file", "ftp", "javascript", "mailto", "sms",
        "ssh", "tel", "view-source", "ws", "wss"
    ]
    private static let queryCharacters = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()"
    )
    private static let invalidHostCharacters = CharacterSet.whitespacesAndNewlines
        .union(.controlCharacters)
        .union(CharacterSet(charactersIn: "/\\?#@"))

    static func resolve(_ rawInput: String, searchSettings: BrowserSearchSettings) -> URL? {
        let input = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return nil }
        let scheme = input.range(of: #"^[a-zA-Z][a-zA-Z0-9+.-]*:"#, options: .regularExpression)
        if let scheme {
            let name = input[scheme].dropLast().lowercased()
            if name == "http" || name == "https" { return webURL(input) }
            if nonWebSchemes.contains(name) || input[scheme.upperBound...].hasPrefix("//") { return nil }
        }

        if !input.contains(where: \.isWhitespace) {
            let hasPort = input.range(of: #"^[^/?#:@]+:[0-9]+(?:[/?#]|$)"#, options: .regularExpression) != nil
            if scheme != nil && !hasPort { return nil }
            let authority = input.prefix { !"/?#".contains($0) }
            let host = authority.split(separator: "@", omittingEmptySubsequences: false).last?
                .replacingOccurrences(of: #":[0-9]+$"#, with: "", options: .regularExpression) ?? ""
            if hasPort || host.lowercased() == "localhost"
                || host.range(of: #"^\[[0-9a-fA-F:.]+\]$|^[^.]+(?:\.[^.]+)+\.?$"#, options: .regularExpression) != nil {
                guard let candidate = webURL("https://\(input)"), let parsedHost = candidate.host() else { return nil }
                return isLocalHost(parsedHost) ? webURL("http://\(input)") : candidate
            }
        }

        guard let query = input.addingPercentEncoding(withAllowedCharacters: queryCharacters) else { return nil }
        return webURL(searchSettings.searchTemplate.replacingOccurrences(of: "%s", with: query))
    }

    static func isValidSearchTemplate(_ template: String) -> Bool {
        guard template.utf16.count <= BrowserSearchSettings.maximumTemplateLength, template.contains("%s"),
              let url = webURL(template.replacingOccurrences(of: "%s", with: "a")),
              let other = webURL(template.replacingOccurrences(of: "%s", with: "b")) else { return false }
        return url.host() == other.host() && url.port == other.port
    }

    static func isWebURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = components.host, !host.isEmpty,
              host.rangeOfCharacter(from: invalidHostCharacters) == nil,
              url.user() == nil, url.password() == nil else { return false }
        guard components.rangeOfPort != nil else { return true }
        return url.port.map { (1...65535).contains($0) } ?? false
    }

    private static func webURL(_ input: String) -> URL? {
        guard let url = URL(string: input), isWebURL(url) else { return nil }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.percentEncodedPath.isEmpty else { return url }
        components.percentEncodedPath = "/"
        return components.url
    }

    private static func isLocalHost(_ host: String) -> Bool {
        let normalized = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if normalized == "localhost" || normalized == "0.0.0.0" { return true }
        if let address = IPv6Address(normalized) { return address == .loopback || address == .any }
        var address = in_addr()
        return inet_aton(normalized, &address) == 1 && UInt32(bigEndian: address.s_addr) >> 24 == 127
    }
}
