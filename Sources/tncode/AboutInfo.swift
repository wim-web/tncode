import Foundation

struct AboutInfo {
    let name: String
    let version: String?
    let build: String?

    init(bundle: Bundle = .main) {
        name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? ProcessInfo.processInfo.processName
        version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    }
}

struct DependencyNotice: Decodable, Identifiable {
    struct NoticeText: Decodable, Identifiable {
        let file: String
        let text: String

        var id: String { file }
    }

    static let piPackage = "@earendil-works/pi-coding-agent"

    let id: String
    let name: String
    let version: String?
    let license: String?
    let texts: [NoticeText]

    static func load(from bundle: Bundle = .main) -> [Self]? {
        guard let url = bundle.url(forResource: "ThirdPartyNotices", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([Self].self, from: data),
              !entries.isEmpty else { return nil }
        return entries
    }
}
