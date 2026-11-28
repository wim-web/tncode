import SwiftUI

struct ProjectIconView: View {
    let icon: ProjectIcon?
    var size: CGFloat = 16
    var fallback = "folder"
    /// With a name, an unset icon shows T3 Code's derived monogram instead of the fallback symbol.
    var projectName: String? = nil
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        artwork
            .frame(width: size, height: size)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(icon?.summary ?? String(localized: "Default project icon"))
            .accessibilityAddTraits(.isImage)
    }

    @ViewBuilder
    private var artwork: some View {
        switch icon {
        case .symbol(let symbol, let tint):
            Image(systemName: symbol.rawValue)
                .font(.system(size: size * 0.78, weight: .medium))
                .foregroundStyle(tint.color)
        case .emoji(let emoji):
            Text(emoji).font(.system(size: size * 0.82))
        case .monogram(let letters, let tint):
            Text(letters)
                .font(.system(size: size * 0.54, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.65)
                .foregroundStyle(tint.color)
                .frame(width: size, height: size)
                .background(tint.color.opacity(0.15), in: RoundedRectangle(cornerRadius: size * 0.22))
        case .image(let png):
            if let image = ProjectIcon.bitmap(from: png) {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFit()
            } else {
                fallbackImage
            }
        case nil:
            if let projectName {
                T3ProjectMonogram(name: projectName, size: size, dark: colorScheme == .dark)
            } else {
                fallbackImage
            }
        }
    }

    private var fallbackImage: some View {
        Image(systemName: fallback).font(.system(size: size * 0.78, weight: .medium))
    }
}

extension ProjectIcon.Tint {
    fileprivate var color: Color {
        switch self {
        case .gray: .secondary
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .teal: .teal
        case .cyan: .cyan
        case .blue: .blue
        case .indigo: .indigo
        case .purple: .purple
        case .pink: .pink
        }
    }
}

struct ProjectIconPicker: View {
    private enum Mode: String, CaseIterable {
        case icons = "Icons"
        case emoji = "Emoji"
        case monogram = "Monogram"
    }

    private static let emojis = ["💻", "🛠️", "🚀", "🤖", "✨", "⚡", "🌐", "📱", "☁️", "📦", "📚", "🧪",
                                 "🔒", "🎮", "🎵", "🎬", "🖼️", "🔥", "💡", "🧩", "📊", "🐙", "🌱", "🌈"]
    let save: (ProjectIcon) throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var mode: Mode = .icons
    @State private var symbol: ProjectIcon.Symbol = .folder
    @State private var tint: ProjectIcon.Tint = .gray
    @State private var letters: String
    @State private var emoji = "💻"
    @State private var customEmoji = ""
    @State private var error: String?

    init(project: Project, save: @escaping (ProjectIcon) throws -> Void) {
        self.save = save
        let initials = String(project.title.filter { $0.isLetter || $0.isNumber }.prefix(2))
        _letters = State(initialValue: ProjectIcon.monogramText(initials) ?? "P")
        switch project.icon {
        case .symbol(let symbol, let tint):
            _symbol = State(initialValue: symbol)
            _tint = State(initialValue: tint)
        case .emoji(let emoji):
            _mode = State(initialValue: .emoji)
            _emoji = State(initialValue: emoji)
            _customEmoji = State(initialValue: Self.emojis.contains(emoji) ? "" : emoji)
        case .monogram(let letters, let tint):
            _mode = State(initialValue: .monogram)
            _letters = State(initialValue: letters)
            _tint = State(initialValue: tint)
        case .image, nil:
            break
        }
    }

    private var selection: ProjectIcon? {
        switch mode {
        case .icons: .symbol(symbol, tint)
        case .emoji: .emoji(emoji)
        case .monogram: ProjectIcon.monogramText(letters).map { .monogram($0, tint) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Choose project icon").font(.headline).accessibilityAddTraits(.isHeader)
            Picker("Icon type", selection: $mode) {
                ForEach(Mode.allCases, id: \.self) { mode in
                    Text(localized: mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityIdentifier("project-icon-type")
            if mode != .emoji {
                HStack {
                    Text("Color")
                    ForEach(ProjectIcon.Tint.allCases, id: \.self) { tint in
                        Button { self.tint = tint } label: {
                            Circle().fill(tint.color).frame(width: 13, height: 13)
                                .padding(3)
                                .background {
                                    if self.tint == tint { Circle().strokeBorder(.primary, lineWidth: 1) }
                                }
                        }
                        .buttonStyle(.plain)
                        .help(tint.title)
                        .accessibilityLabel(tint.title)
                        .accessibilityIdentifier("project-icon-color-\(tint.rawValue)")
                        .accessibilityAddTraits(self.tint == tint ? .isSelected : [])
                    }
                }
            }
            choices
                .frame(height: 155, alignment: .topLeading)
            if let error {
                Text(error).foregroundStyle(.red).accessibilityIdentifier("project-icon-save-error")
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("project-icon-cancel")
                Button("Save icon") {
                    guard let selection else { return }
                    do {
                        try save(selection)
                        dismiss()
                    } catch {
                        self.error = error.localizedDescription
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selection == nil)
                .accessibilityIdentifier("project-icon-save")
            }
        }
        .padding(20)
        .frame(width: 402)
    }

    @ViewBuilder
    private var choices: some View {
        switch mode {
        case .icons:
            grid(ProjectIcon.Symbol.allCases) { option in
                optionButton(.symbol(option, tint), label: option.title, id: "symbol-\(option.rawValue)",
                             isSelected: symbol == option) { symbol = option }
            }
        case .emoji:
            VStack(alignment: .leading, spacing: 8) {
                grid(Self.emojis) { option in
                    optionButton(.emoji(option), label: option, id: "emoji-\(option)", isSelected: emoji == option) {
                        emoji = option
                        customEmoji = ""
                    }
                }
                HStack {
                    TextField("Paste an emoji", text: $customEmoji)
                        .accessibilityIdentifier("project-icon-custom-emoji")
                        .onChange(of: customEmoji) { _, value in
                            if let emoji = ProjectIcon.firstEmoji(in: value) { self.emoji = emoji }
                        }
                    if !Self.emojis.contains(emoji) {
                        ProjectIconView(icon: .emoji(emoji), size: 22)
                    }
                }
            }
        case .monogram:
            HStack(alignment: .top, spacing: 12) {
                ProjectIconView(icon: selection, size: 36)
                VStack(alignment: .leading, spacing: 5) {
                    TextField("Letters", text: $letters)
                        .accessibilityIdentifier("project-icon-letters")
                    Text("One or two letters or numbers.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func grid<Item: Hashable, Content: View>(_ items: [Item], @ViewBuilder content: @escaping (Item) -> Content) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 8), spacing: 4) {
            ForEach(items, id: \.self, content: content)
        }
    }

    private func optionButton(_ icon: ProjectIcon, label: String, id: String,
                              isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ProjectIconView(icon: icon, size: 24)
                .accessibilityHidden(true)
                .frame(maxWidth: .infinity, minHeight: 32)
                .background(isSelected ? Color.accentColor.opacity(0.15) : .clear,
                            in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityIdentifier("project-icon-\(id)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// T3 Code's default project mark (ProjectMonogram.tsx, projectIdentity.ts, projectMonogram.ts).
struct T3ProjectMonogram: View {
    let name: String
    let size: CGFloat
    let dark: Bool

    private static let colors: [(dark: UInt32, light: UInt32)] = [
        (0x99A1AF, 0x4A5565), (0xFF6467, 0xE7000B), (0xFF8904, 0xF54900), (0xFFB900, 0xE17100),
        (0xFDC700, 0xD08700), (0x9AE600, 0x5EA500), (0x05DF72, 0x00A63E), (0x00D492, 0x009966),
        (0x00D5BE, 0x009689), (0x00D3F2, 0x0092B8), (0x00BCFF, 0x0084D1), (0x51A2FF, 0x155DFC),
        (0x7C86FF, 0x4F39F6), (0xA684FF, 0x7F22FE), (0xC27AFF, 0x9810FA), (0xED6AFF, 0xC800DE),
        (0xFB64B6, 0xE60076), (0xFF637E, 0xEC003F)
    ]

    static func colorIndex(for name: String) -> Int {
        let normalized = name.precomposedStringWithCompatibilityMapping.trimmingCharacters(in: .whitespacesAndNewlines)
        let seed = normalized.isEmpty ? "project" : normalized.lowercased(with: Locale(identifier: "en_US"))
        var index = 0
        for scalar in seed.unicodeScalars {
            index = (index * 31 + Int(scalar.value)) % colors.count
        }
        return index
    }

    static func letters(for name: String) -> String {
        let normalized = name.precomposedStringWithCompatibilityMapping.trimmingCharacters(in: .whitespacesAndNewlines)
        var words: [[Character]] = []
        var current: [Character] = []
        for character in normalized {
            if character.isLetter || character.isNumber {
                current.append(character)
            } else if !current.isEmpty {
                words.append(current)
                current = []
            }
        }
        if !current.isEmpty { words.append(current) }
        guard let firstWord = words.first, let first = firstWord.first else { return "PR" }
        if first.unicodeScalars.first.map({ (0x3040...0x30FF).contains($0.value) || (0x4E00...0x9FFF).contains($0.value) ||
            (0xAC00...0xD7AF).contains($0.value) || (0x3400...0x4DBF).contains($0.value) }) == true {
            return String(first)
        }
        let second = firstWord.dropFirst().first(where: \.isNumber)
            ?? (words.count > 1 ? words[words.count - 1].first : firstWord.last) ?? first
        return String(String([first, second]).uppercased().prefix(2))
    }

    var body: some View {
        let pair = Self.colors[Self.colorIndex(for: name)]
        let tint = Color(hex: dark ? pair.dark : pair.light)
        let text = Self.letters(for: name)
        let glyphs = text.count
        let fontSize = size * 8.25 / 16
        Text(verbatim: text)
            .font(.system(size: fontSize, weight: .bold, design: .monospaced))
            .foregroundStyle(tint)
            .fixedSize()
            .scaleEffect(x: (size * (glyphs == 1 ? 6 : 12) / 16) / (fontSize * 0.6 * CGFloat(max(glyphs, 1))), y: 1)
            .frame(width: size, height: size)
            .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: size * 0.25))
            .accessibilityHidden(true)
    }
}
