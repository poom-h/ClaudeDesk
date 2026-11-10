import SwiftUI

/// Random UUIDs give agents varied colors without changing them on every launch.
func agentColor(_ id: UUID) -> Color {
    let palette: [Color] = [
        Color(red: 0.85, green: 0.48, blue: 0.34),
        Color(red: 0.72, green: 0.58, blue: 0.27),
        Color(red: 0.40, green: 0.65, blue: 0.45),
        Color(red: 0.28, green: 0.65, blue: 0.63),
        Color(red: 0.39, green: 0.60, blue: 0.85),
        Color(red: 0.65, green: 0.52, blue: 0.84),
        Color(red: 0.80, green: 0.48, blue: 0.65),
        Color(red: 0.78, green: 0.57, blue: 0.43)
    ]
    // Unlike hashValue, this mapping is stable between processes.
    let seed = id.uuidString.utf8.reduce(UInt64(5381)) { ($0 &* 33) &+ UInt64($1) }
    return palette[Int(seed % UInt64(palette.count))]
}

func sessionColor(_ index: Int) -> Color {
    let colors: [Color] = [.orange, .cyan, .purple, .green, .pink, .yellow, .blue, .mint]
    return colors[index % colors.count]
}

/// A small Claude-style sunburst used as a session identifier.
struct ClaudeSessionMark: View {
    let color: Color
    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            for i in 0..<12 {
                let angle = Double(i) * .pi / 6
                let radius = min(size.width, size.height) * (i % 3 == 0 ? 0.48 : 0.40)
                var path = Path()
                path.move(to: center)
                path.addLine(to: CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius))
                context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            }
        }.accessibilityHidden(true)
    }
}

/// Pixel mascot inspired by the little creature in the Claude Code terminal.
struct ClaudeMascot: View {
    var color: Color = .orange
    private let pixels = [
        "0011111111100",
        "0011111111100",
        "1110111011111",
        "1110111011111",
        "1111111111111",
        "0011111111100",
        "0011111111100",
        "0011000110000",
        "0110000011000"
    ]
    var body: some View {
        Canvas { context, size in
            let unit = min(size.width / 13, size.height / 9)
            let origin = CGPoint(x: (size.width - unit * 13) / 2, y: (size.height - unit * 9) / 2)
            var path = Path()
            for (y, row) in pixels.enumerated() {
                for (x, pixel) in row.enumerated() where pixel == "1" {
                    path.addRect(CGRect(x: origin.x + CGFloat(x) * unit, y: origin.y + CGFloat(y) * unit, width: unit, height: unit))
                }
            }
            context.fill(path, with: .color(color))
        }.accessibilityHidden(true)
    }
}
