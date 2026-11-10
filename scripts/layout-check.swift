import Foundation
import CoreGraphics

@main struct LayoutChecks {
    static func main() {
        for count in 1...12 {
            let ids = (0..<count).map { _ in UUID() }
            for preset in SnapPreset.allCases {
                let tree = PaneTree.make(ids, preset: preset)!
                check(tree, ids)
                for source in ids {
                    for target in ids {
                        for edge in SnapEdge.allCases { check(tree.docking(source, beside: target, edge: edge), ids) }
                    }
                    if count > 1 { check(tree.removing(source)!, ids.filter { $0 != source }) }
                }
                for divider in tree.geometry().dividers {
                    check(tree.settingRatio(divider.id, to: -10), ids)
                    check(tree.settingRatio(divider.id, to: 10), ids)
                }
                let updated = Array(ids.dropFirst()) + [UUID()]
                check(tree.reconciled(with: updated)!, updated)
                assert(tree.reconciled(with: []) == nil)
            }
        }
        let a = UUID(), b = UUID()
        let tree = PaneTree.make([a,b], preset: .columns)!
        assert(tree.docking(a, beside: b, edge: .center).leaves == [b,a])
        let rect = CGRect(x: 0, y: 0, width: 100, height: 100)
        assert(SnapTarget.edge(at: CGPoint(x: 50,y: 50), in: rect) == .center)
        assert(SnapTarget.edge(at: CGPoint(x: 2,y: 50), in: rect) == .left)
        assert(SnapTarget.edge(at: CGPoint(x: 98,y: 50), in: rect) == .right)
        assert(SnapTarget.edge(at: CGPoint(x: 50,y: 2), in: rect) == .top)
        assert(SnapTarget.edge(at: CGPoint(x: 50,y: 98), in: rect) == .bottom)
        print("Layout checks passed: presets, docking, swapping, removal, reconciliation, resizing, hit targets and geometry (1–12 panes).")
    }
    static func check(_ tree: PaneTree, _ ids: [UUID]) {
        assert(tree.leaves.count == ids.count && Set(tree.leaves) == Set(ids))
        let rects = Array(tree.geometry().panes.values)
        assert(abs(rects.reduce(0) { $0 + $1.width * $1.height } - 1) < 0.00001)
        for (i, r) in rects.enumerated() {
            assert(r.width > 0 && r.height > 0 && r.minX >= -0.00001 && r.minY >= -0.00001 && r.maxX <= 1.00001 && r.maxY <= 1.00001)
            for other in rects.dropFirst(i+1) {
                let intersection = r.intersection(other)
                assert(intersection.isNull || intersection.width * intersection.height < 0.00001)
            }
        }
    }
}
