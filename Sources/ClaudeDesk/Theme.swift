import SwiftUI
import AppKit

enum DeskTheme: String, CaseIterable, Identifiable {
    case space = "Space", claude = "Claude Dark", light = "Warm Light", midnight = "Midnight"
    var id: String { rawValue }
    var dark: Bool { self != .light }
    /// Space matches the Cockpit: the Studio gets the starfield, glass panels, and the same status strip.
    var isSpace: Bool { self == .space }
    var background: NSColor {
        switch self {
        case .space: return NSColor(hex: 0x0A0C18)
        case .claude: return NSColor(hex: 0x242321)
        case .light: return NSColor(hex: 0xFAF7F2)
        case .midnight: return NSColor(hex: 0x101216)
        }
    }
    var panel: Color {
        switch self {
        case .space: return Color(nsColor: NSColor(hex: 0x11152A))
        case .claude: return Color(nsColor: NSColor(hex: 0x2D2B28))
        case .light: return Color(nsColor: NSColor(hex: 0xF0EBE3))
        case .midnight: return Color(nsColor: NSColor(hex: 0x1B1F27))
        }
    }
    var foreground: NSColor { NSColor(hex: self == .space ? 0xE6EAF7 : dark ? 0xE8E3DB : 0x302C27) }
    var accent: Color {
        // Space uses the Cockpit's accent (SpaceTheme), written out so this file stands alone.
        self == .space ? Color(red: 0.55, green: 0.66, blue: 1.0) : Color(nsColor: NSColor(hex: self == .midnight ? 0xDCA879 : 0xD48265))
    }
    var summary: String {
        switch self {
        case .space: return "Deep space · glass · matches the Cockpit"
        case .claude: return "Warm charcoal · terracotta · terminal first"
        case .light: return "Cream · warm ink · daylight reading"
        case .midnight: return "Deep graphite · amber · high contrast"
        }
    }
}

private struct DeskThemeKey: EnvironmentKey { static let defaultValue = DeskTheme.space }
extension EnvironmentValues {
    var deskTheme: DeskTheme {
        get { self[DeskThemeKey.self] }
        set { self[DeskThemeKey.self] = newValue }
    }
}

extension NSColor {
    convenience init(hex: Int) {
        self.init(red: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
                  blue: CGFloat(hex & 255) / 255, alpha: 1)
    }
}

struct ThemeChooser: View {
    @AppStorage("deskTheme") private var selection = DeskTheme.space.rawValue
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose your workspace").font(.headline)
            ForEach(DeskTheme.allCases) { theme in
                Button { selection = theme.rawValue } label: {
                    HStack(spacing: 14) {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 3) {
                                Circle().fill(theme.accent).frame(width: 5, height: 5)
                                Text("claude").font(.system(size: 9, design: .monospaced))
                            }
                            Text("❯ ready").font(.system(size: 10, design: .monospaced))
                        }.foregroundStyle(Color(nsColor: theme.foreground)).padding(10)
                            .frame(width: 90, height: 55).background(Color(nsColor: theme.background), in: RoundedRectangle(cornerRadius: 7))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(theme.rawValue).font(.headline)
                            Text(theme.summary).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if selection == theme.rawValue { Image(systemName: "checkmark.circle.fill").foregroundStyle(theme.accent) }
                    }.padding(8).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }.padding(16).frame(width: 390)
    }
}
