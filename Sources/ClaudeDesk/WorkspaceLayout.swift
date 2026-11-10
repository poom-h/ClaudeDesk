import Foundation
import CoreGraphics

enum SnapEdge: String, CaseIterable {
    case left, right, top, bottom, center
}

enum SnapPreset: String, CaseIterable, Identifiable {
    case balanced = "Balanced", columns = "Columns", rows = "Rows", mainLeft = "Main + stack"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .balanced: return "rectangle.split.2x2"
        case .columns: return "rectangle.split.2x1"
        case .rows: return "rectangle.split.1x2"
        case .mainLeft: return "sidebar.right"
        }
    }
}

indirect enum PaneTree: Equatable {
    case leaf(UUID)
    case split(id: UUID, horizontal: Bool, ratio: Double, first: PaneTree, second: PaneTree)

    var leaves: [UUID] {
        switch self {
        case .leaf(let id): return [id]
        case .split(_, _, _, let first, let second): return first.leaves + second.leaves
        }
    }

    func removing(_ id: UUID) -> PaneTree? {
        switch self {
        case .leaf(let current): return current == id ? nil : self
        case .split(let splitID, let horizontal, let ratio, let first, let second):
            let a = first.removing(id), b = second.removing(id)
            if let a, let b { return .split(id: splitID, horizontal: horizontal, ratio: ratio, first: a, second: b) }
            return a ?? b
        }
    }

    func replacing(_ id: UUID, with replacement: PaneTree) -> PaneTree {
        switch self {
        case .leaf(let current): return current == id ? replacement : self
        case .split(let splitID, let horizontal, let ratio, let first, let second):
            return .split(id: splitID, horizontal: horizontal, ratio: ratio,
                          first: first.replacing(id, with: replacement), second: second.replacing(id, with: replacement))
        }
    }

    func settingRatio(_ id: UUID, to value: Double) -> PaneTree {
        switch self {
        case .leaf: return self
        case .split(let splitID, let horizontal, let ratio, let first, let second):
            return .split(id: splitID, horizontal: horizontal, ratio: splitID == id ? min(0.8, max(0.2, value)) : ratio,
                          first: first.settingRatio(id, to: value), second: second.settingRatio(id, to: value))
        }
    }

    func docking(_ source: UUID, beside target: UUID, edge: SnapEdge) -> PaneTree {
        guard source != target, leaves.contains(source), leaves.contains(target) else { return self }
        if edge == .center {
            let temporary = UUID()
            return replacing(source, with: .leaf(temporary)).replacing(target, with: .leaf(source)).replacing(temporary, with: .leaf(target))
        }
        guard let remaining = removing(source) else { return self }
        let leading = edge == .left || edge == .top
        let replacement = PaneTree.split(id: UUID(), horizontal: edge == .left || edge == .right, ratio: 0.5,
                                         first: .leaf(leading ? source : target), second: .leaf(leading ? target : source))
        return remaining.replacing(target, with: replacement)
    }

    static func make(_ ids: [UUID], preset: SnapPreset) -> PaneTree? {
        guard let first = ids.first else { return nil }
        if ids.count == 1 { return .leaf(first) }
        if preset == .mainLeft {
            return .split(id: UUID(), horizontal: true, ratio: 0.64, first: .leaf(first), second: make(Array(ids.dropFirst()), preset: .rows)!)
        }
        let horizontal: Bool
        let cut: Int
        switch preset {
        case .columns: horizontal = true; cut = 1
        case .rows: horizontal = false; cut = 1
        case .balanced: horizontal = true; cut = (ids.count + 1) / 2
        case .mainLeft: fatalError("Handled above")
        }
        let next: SnapPreset = (preset == .balanced) ? .rows : preset
        return .split(id: UUID(), horizontal: horizontal,
                      ratio: preset == .columns || preset == .rows ? 1 / Double(ids.count) : 0.5,
                      first: make(Array(ids.prefix(cut)), preset: next)!, second: make(Array(ids.dropFirst(cut)), preset: next)!)
    }

    func reconciled(with ids: [UUID]) -> PaneTree? {
        var result: PaneTree? = self
        for id in leaves where !ids.contains(id) { result = result?.removing(id) }
        for id in ids where !(result?.leaves.contains(id) ?? false) {
            if let tree = result { result = .split(id: UUID(), horizontal: true, ratio: 0.6, first: tree, second: .leaf(id)) }
            else { result = .leaf(id) }
        }
        return result
    }

    // Coordinates are normalized to the canvas, keeping layout independent of window size.
    func geometry(in rect: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)) -> PaneGeometry {
        switch self {
        case .leaf(let id): return PaneGeometry(panes: [id: rect], dividers: [])
        case .split(let id, let horizontal, let ratio, let first, let second):
            let a: CGRect, b: CGRect
            if horizontal {
                a = CGRect(x: rect.minX, y: rect.minY, width: rect.width * ratio, height: rect.height)
                b = CGRect(x: a.maxX, y: rect.minY, width: rect.width - a.width, height: rect.height)
            } else {
                a = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height * ratio)
                b = CGRect(x: rect.minX, y: a.maxY, width: rect.width, height: rect.height - a.height)
            }
            let left = first.geometry(in: a), right = second.geometry(in: b)
            return PaneGeometry(panes: left.panes.merging(right.panes) { old, _ in old },
                                dividers: left.dividers + right.dividers + [PaneDivider(id: id, horizontal: horizontal, ratio: ratio, rect: rect)])
        }
    }
}

struct PaneDivider: Identifiable {
    let id: UUID
    let horizontal: Bool
    let ratio: Double
    let rect: CGRect
}

struct PaneGeometry {
    var panes: [UUID: CGRect]
    var dividers: [PaneDivider]
}

enum SnapTarget {
    static func edge(at point: CGPoint, in rect: CGRect) -> SnapEdge {
        let x = (point.x - rect.minX) / max(1, rect.width)
        let y = (point.y - rect.minY) / max(1, rect.height)
        if x > 0.28 && x < 0.72 && y > 0.28 && y < 0.72 { return .center }
        let distances: [(SnapEdge, Double)] = [(.left, x), (.right, 1-x), (.top, y), (.bottom, 1-y)]
        return distances.min { $0.1 < $1.1 }!.0
    }
    static func preview(_ rect: CGRect, edge: SnapEdge) -> CGRect {
        switch edge {
        case .left: return CGRect(x: rect.minX, y: rect.minY, width: rect.width/2, height: rect.height)
        case .right: return CGRect(x: rect.midX, y: rect.minY, width: rect.width/2, height: rect.height)
        case .top: return CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height/2)
        case .bottom: return CGRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height/2)
        case .center: return rect
        }
    }
}
