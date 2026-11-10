import SwiftUI

/// Adjustable parts of a Cockpit theme. Later, folder-based variations will override these without code.
struct CockpitThemeSettings {
    var background: Color
    var text: Color
    var secondaryText: Color
    var accent: Color
    var good: Color
    var warning: Color
    var danger: Color
    var glassFill: Color
    var glassStroke: Color
    var starColor: Color
    var constellationColor: Color
    var starDensity: Int
}

/// A complete look for the Cockpit: its background, how memory is drawn, and widget styling.
protocol CockpitTheme {
    var id: String { get }
    var name: String { get }
    var settings: CockpitThemeSettings { get }
    func background(graph: VaultGraph, layout: ConstellationLayout, view: GraphViewport, pulses: [String: Date], reads: [String: VaultRead],
                    reduceMotion: Bool, hovered: String?) -> AnyView
}

/// How the memory graph is framed and coloured on screen.
struct GraphViewport {
    var zoom: CGFloat = 1
    var pan: CGSize = .zero
    var colors: [String: Color] = [:]   // node id -> cluster colour
    var emphasis: Double = 1.4
    /// Width of the clear middle between the side columns; the graph is sized to fit it, centred in the window.
    var fitWidth: CGFloat?
    /// Where the camera is gliding from (search focus); `zoom` and `pan` are where it's heading.
    var glide: Glide?
    /// An active quick search: matches stand out, everything else fades.
    var search: GraphSearch?
    /// How the graph is laid out: flat constellation, 3D sphere, or orbits.
    var mode: GraphMode = .flat
    /// Sphere view orientation, in radians: turn left/right, and tilt.
    var yaw: Double = 0
    var pitch: Double = 0.35
    /// Switching views morphs every star from where it was in `from` to where it belongs now.
    var morph: Morph?

    struct Morph: Equatable {
        var from: GraphMode
        var start: Double
    }
    static let morphDuration = 1.1

    /// Where a node lands on screen, and how near it is: 1 is normal; in the sphere, nearer is above 1, farther below.
    struct Projection {
        var point: CGPoint
        var depth: CGFloat
    }

    struct Glide: Equatable {
        var pan: CGSize
        var zoom: CGFloat
        var start: Double
    }
    static let glideDuration = 0.85

    /// Zoom and pan at `time`, eased along any glide.
    func camera(at time: Double) -> (zoom: CGFloat, pan: CGSize) {
        guard let glide else { return (zoom, pan) }
        let t = min(1, max(0, (time - glide.start) / Self.glideDuration))
        let eased = CGFloat(t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2)
        return (glide.zoom + (zoom - glide.zoom) * eased,
                CGSize(width: glide.pan.width + (pan.width - glide.pan.width) * eased, height: glide.pan.height + (pan.height - glide.pan.height) * eased))
    }

    func isGliding(at time: Double) -> Bool { glide.map { time - $0.start < Self.glideDuration } ?? false }

    /// How far a view switch has got, eased, 0…1; 1 when there's none.
    func morphProgress(at time: Double) -> Double {
        guard let morph else { return 1 }
        let t = min(1, max(0, (time - morph.start) / Self.morphDuration))
        return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
    }

    /// Screen position of a node, shared by drawing and hit testing.
    func point(_ id: String, layout: ConstellationLayout, size: CGSize, time: Double) -> CGPoint? {
        project(id, layout: layout, size: size, time: time)?.point
    }

    func project(_ id: String, layout: ConstellationLayout, size: CGSize, time: Double) -> Projection? {
        guard let current = place(id, in: mode, layout: layout, size: size, time: time) else { return nil }
        let progress = morphProgress(at: time)
        guard progress < 1, let morph, let from = place(id, in: morph.from, layout: layout, size: size, time: time) else { return current }
        let k = CGFloat(progress)
        return Projection(point: CGPoint(x: from.point.x + (current.point.x - from.point.x) * k, y: from.point.y + (current.point.y - from.point.y) * k),
                          depth: from.depth + (current.depth - from.depth) * k)
    }

    /// Size of the graph on screen: it fits the clear middle and the window's height.
    func scale(in size: CGSize, time: Double) -> CGFloat {
        // Nodes reach ±0.92 of the scale, stretched 1.35× horizontally, so the width limit divides by about 2.5.
        min(fitWidth.map { $0 / 2.5 } ?? size.width * 0.42, size.height * 0.42) * camera(at: time).zoom
    }

    func origin(in size: CGSize, time: Double) -> CGPoint {
        let camera = camera(at: time)
        return CGPoint(x: size.width / 2 + camera.pan.width, y: size.height / 2 + camera.pan.height)
    }

    private func place(_ id: String, in mode: GraphMode, layout: ConstellationLayout, size: CGSize, time: Double) -> Projection? {
        let scale = scale(in: size, time: time), origin = origin(in: size, time: time)
        switch mode {
        case .flat:
            guard let p = layout.positions[id] else { return nil }
            let rotation = CGFloat(time * 0.0015)
            let x = p.x * cos(rotation) - p.y * sin(rotation), y = p.x * sin(rotation) + p.y * cos(rotation)
            return Projection(point: CGPoint(x: origin.x + x * scale * 1.35, y: origin.y + y * scale), depth: 1)
        case .sphere:
            guard let p = layout.positions3D[id] else { return nil }
            return sphere(p, scale: scale, origin: origin, time: time)
        case .orbit:
            guard let p = layout.orbitPosition(id, time: time) else { return nil }
            return Projection(point: CGPoint(x: origin.x + p.x * scale * 1.3, y: origin.y + p.y * scale * 1.3), depth: 1)
        }
    }

    /// A point in the sphere view: turned by `yaw` (plus a very slow drift) and tilted by `pitch`, with perspective.
    func sphere(_ p: SIMD3<Double>, scale: CGFloat, origin: CGPoint, time: Double) -> Projection {
        let turn = yaw + time * 0.002
        let x1 = p.x * cos(turn) - p.z * sin(turn), z1 = p.x * sin(turn) + p.z * cos(turn)
        let y2 = p.y * cos(pitch) - z1 * sin(pitch), z2 = p.y * sin(pitch) + z1 * cos(pitch)
        let perspective = CGFloat(2.4 / (2.4 + z2))
        return Projection(point: CGPoint(x: origin.x + CGFloat(x1) * scale * 0.95 * perspective, y: origin.y + CGFloat(y2) * scale * 0.95 * perspective),
                          depth: perspective)
    }
}

/// The ways the memory graph can be laid out.
enum GraphMode: String, CaseIterable, Identifiable {
    case flat, sphere, orbit
    var id: String { rawValue }
    var title: String { ["flat": "Constellation", "sphere": "Sphere", "orbit": "Orbits"][rawValue]! }
    var label: String { ["flat": "2D", "sphere": "3D", "orbit": "ORBIT"][rawValue]! }
}

/// What a quick search shows on the graph: the matches by rank, the one in focus, and when the query last changed.
struct GraphSearch: Equatable {
    var matches: [String: Int]
    var focused: String?
    var changed: Double
}

enum CockpitThemes {
    static let all: [CockpitTheme] = [SpaceTheme()]
    static func named(_ id: String) -> CockpitTheme { all.first { $0.id == id } ?? all[0] }
}

private struct CockpitThemeKey: EnvironmentKey { static let defaultValue: CockpitThemeSettings = SpaceTheme().settings }
extension EnvironmentValues {
    var cockpitStyle: CockpitThemeSettings {
        get { self[CockpitThemeKey.self] }
        set { self[CockpitThemeKey.self] = newValue }
    }
}

// MARK: - Futuristic space

struct SpaceTheme: CockpitTheme {
    let id = "space"
    let name = "Futuristic space"
    let settings = CockpitThemeSettings(
        background: Color(red: 0.035, green: 0.043, blue: 0.09),
        text: Color(red: 0.91, green: 0.93, blue: 0.98),
        secondaryText: Color(red: 0.62, green: 0.67, blue: 0.80),
        accent: Color(red: 0.55, green: 0.66, blue: 1.0),
        good: Color(red: 0.49, green: 0.89, blue: 0.72),
        warning: Color(red: 1.0, green: 0.82, blue: 0.48),
        danger: Color(red: 1.0, green: 0.48, blue: 0.48),
        glassFill: Color.white.opacity(0.055),
        glassStroke: Color.white.opacity(0.13),
        starColor: .white,
        constellationColor: Color(red: 0.62, green: 0.70, blue: 1.0),
        starDensity: 260)

    func background(graph: VaultGraph, layout: ConstellationLayout, view: GraphViewport, pulses: [String: Date], reads: [String: VaultRead],
                    reduceMotion: Bool, hovered: String?) -> AnyView {
        AnyView(SpaceBackground(graph: graph, layout: layout, viewport: view, pulses: pulses, reads: reads, reduceMotion: reduceMotion, settings: settings, hovered: hovered))
    }
}

/// Positions for the vault graph, settled once per graph with a small force layout. Home sits at the centre.
final class ConstellationLayout {
    private(set) var positions: [String: CGPoint] = [:]   // in -1...1 space
    /// The same graph spread through 3D space, inside a sphere of radius about 0.9, for the Sphere view.
    private(set) var positions3D: [String: SIMD3<Double>] = [:]
    /// For the Orbits view: what each node circles, how far out, where it starts, and how fast it turns.
    private(set) var orbits: [String: Orbit] = [:]
    private var signature = ""

    struct Orbit {
        var parent: String?        // nil: circles the centre
        var radius: Double
        var phase: Double
        var speed: Double          // radians per second
    }

    /// Where a node is in the Orbits view at `time`, in -1...1 space: maps circle Home, notes circle their map.
    func orbitPosition(_ id: String, time: Double) -> CGPoint? {
        guard let orbit = orbits[id] else { return nil }
        let centre = orbit.parent.flatMap { orbitPosition($0, time: time) } ?? .zero
        let angle = orbit.phase + orbit.speed * time
        return CGPoint(x: centre.x + orbit.radius * cos(angle), y: centre.y + orbit.radius * sin(angle))
    }

    func update(_ graph: VaultGraph) {
        let key = graph.nodes.map(\.id).sorted().joined(separator: "|") + "#" + String(graph.edges.count)
        guard key != signature else { return }
        signature = key
        var points: [String: CGPoint] = [:]
        for node in graph.nodes {
            if node.kind == .home { points[node.id] = .zero; continue }
            var hasher = Hasher(); hasher.combine(node.id)
            let seed = UInt64(bitPattern: Int64(hasher.finalize()))
            let angle = Double(seed % 6283) / 1000, radius = node.kind == .map ? 0.35 : 0.65
            points[node.id] = positions[node.id] ?? CGPoint(x: cos(angle) * radius, y: sin(angle) * radius)
        }
        let ids = Array(points.keys)
        for step in 0..<220 {
            let cooling = 0.03 * (1 - Double(step) / 220)
            var force: [String: CGVector] = Dictionary(uniqueKeysWithValues: ids.map { ($0, .zero) })
            for (i, a) in ids.enumerated() {
                for b in ids[(i + 1)...] {
                    let pa = points[a]!, pb = points[b]!
                    let dx = pa.x - pb.x, dy = pa.y - pb.y, distance = max(0.04, sqrt(dx * dx + dy * dy))
                    let push = 0.012 / (distance * distance)
                    force[a]!.dx += dx / distance * push; force[a]!.dy += dy / distance * push
                    force[b]!.dx -= dx / distance * push; force[b]!.dy -= dy / distance * push
                }
            }
            for (a, b) in graph.edges {
                guard let pa = points[a], let pb = points[b] else { continue }
                let dx = pb.x - pa.x, dy = pb.y - pa.y
                force[a]!.dx += dx * 0.08; force[a]!.dy += dy * 0.08
                force[b]!.dx -= dx * 0.08; force[b]!.dy -= dy * 0.08
            }
            for id in ids {
                guard let node = graph.nodes.first(where: { $0.id == id }), node.kind != .home, var p = points[id] else { continue }
                p.x += max(-cooling, min(cooling, force[id]!.dx)); p.y += max(-cooling, min(cooling, force[id]!.dy))
                let length = sqrt(p.x * p.x + p.y * p.y)
                if length > 0.92 { p.x *= 0.92 / length; p.y *= 0.92 / length }
                points[id] = p
            }
        }
        positions = points
        positions3D = Self.layout3D(graph, from: points)
        orbits = Self.orbits(graph)
    }
}

extension ConstellationLayout {
    /// A small 3D force layout: linked notes pull together, all push apart, everything stays inside the sphere.
    static func layout3D(_ graph: VaultGraph, from flat: [String: CGPoint]) -> [String: SIMD3<Double>] {
        var points: [String: SIMD3<Double>] = [:]
        for node in graph.nodes {
            guard node.kind != .home, let p = flat[node.id] else { points[node.id] = .zero; continue }
            var hasher = Hasher(); hasher.combine(node.id); hasher.combine("z")
            let seed = Double(UInt64(bitPattern: Int64(hasher.finalize())) % 2000) / 1000 - 1
            points[node.id] = SIMD3(Double(p.x), Double(p.y), seed * 0.7)
        }
        let ids = Array(points.keys)
        let home = graph.nodes.first { $0.kind == .home }?.id
        for step in 0..<160 {
            let cooling = 0.03 * (1 - Double(step) / 160)
            var force: [String: SIMD3<Double>] = Dictionary(uniqueKeysWithValues: ids.map { ($0, .zero) })
            for (i, a) in ids.enumerated() {
                for b in ids[(i + 1)...] {
                    let delta = points[a]! - points[b]!
                    let distance = max(0.05, (delta * delta).sum().squareRoot())
                    let push = delta / distance * (0.014 / (distance * distance))
                    force[a]! += push; force[b]! -= push
                }
            }
            for (a, b) in graph.edges {
                guard let pa = points[a], let pb = points[b] else { continue }
                let pull = (pb - pa) * 0.07
                force[a]! += pull; force[b]! -= pull
            }
            for id in ids where id != home {
                var p = points[id]! + force[id]!.clamped(lowerBound: SIMD3(repeating: -cooling), upperBound: SIMD3(repeating: cooling))
                let length = (p * p).sum().squareRoot()
                if length > 0.92 { p *= 0.92 / length }
                points[id] = p
            }
        }
        return points
    }

    /// Orbits: maps circle Home on one ring; each note circles the first map (by name) that links to it;
    /// notes no map links to circle on an outer ring.
    static func orbits(_ graph: VaultGraph) -> [String: Orbit] {
        var result: [String: Orbit] = [:]
        let maps = graph.nodes.filter { $0.kind == .map }.map(\.id).sorted()
        let mapSet = Set(maps)
        for node in graph.nodes where node.kind == .home { result[node.id] = Orbit(parent: nil, radius: 0, phase: 0, speed: 0) }
        for (index, id) in maps.enumerated() {
            result[id] = Orbit(parent: nil, radius: 0.46, phase: 2 * .pi * Double(index) / Double(max(1, maps.count)), speed: 0.006)
        }
        var moons: [String: [String]] = [:], outer: [String] = []
        for node in graph.nodes.filter({ $0.kind == .note }).sorted(by: { $0.id < $1.id }) {
            let linkedMaps = graph.edges.compactMap { a, b -> String? in
                if a == node.id, mapSet.contains(b) { return b }
                if b == node.id, mapSet.contains(a) { return a }
                return nil
            }.sorted()
            if let map = linkedMaps.first { moons[map, default: []].append(node.id) } else { outer.append(node.id) }
        }
        for (mapIndex, map) in maps.enumerated() {
            let notes = moons[map] ?? []
            let radius = min(0.24, 0.1 + 0.012 * Double(notes.count))
            for (index, id) in notes.enumerated() {
                // Neighbouring systems turn in opposite directions.
                result[id] = Orbit(parent: map, radius: radius, phase: 2 * .pi * Double(index) / Double(max(1, notes.count)),
                                   speed: (mapIndex.isMultiple(of: 2) ? 1 : -1) * 0.035)
            }
        }
        for (index, id) in outer.enumerated() {
            result[id] = Orbit(parent: nil, radius: 0.86, phase: 2 * .pi * Double(index) / Double(max(1, outer.count)), speed: -0.004)
        }
        return result
    }
}

/// The starfield, drifting nebula glow, and the Memory Vault drawn as constellations.
struct SpaceBackground: View {
    let graph: VaultGraph
    let layout: ConstellationLayout
    var viewport = GraphViewport()
    let pulses: [String: Date]
    var reads: [String: VaultRead] = [:]
    let reduceMotion: Bool
    let settings: CockpitThemeSettings
    var hovered: String?

    var body: some View {
        ZStack {
            // The starfield and nebula are drawn once; only the constellations animate, and slowly.
            Canvas { canvas, size in
                canvas.fill(Path(CGRect(origin: .zero, size: size)), with: .color(settings.background))
                for glow in [(0.25, 0.3, Color(red: 0.25, green: 0.15, blue: 0.55)), (0.78, 0.65, Color(red: 0.08, green: 0.25, blue: 0.5))] {
                    let center = CGPoint(x: size.width * glow.0, y: size.height * glow.1)
                    let radius = max(size.width, size.height) * 0.45
                    canvas.fill(Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)),
                                with: .radialGradient(Gradient(colors: [glow.2.opacity(0.28), .clear]), center: center, startRadius: 0, endRadius: radius))
                }
                for star in 0..<settings.starDensity {
                    let x = Self.noise(star, 1) * size.width, y = Self.noise(star, 2) * size.height
                    let radius = 0.4 + Self.noise(star, 5) * 0.9
                    canvas.fill(Path(ellipseIn: CGRect(x: x, y: y, width: radius * 2, height: radius * 2)),
                                with: .color(settings.starColor.opacity(0.25 + 0.5 * Self.noise(star, 4))))
                }
            }
            // The drift is very slow, so a repaint each second looks continuous. Motion (glides, sweeps, flares,
            // pulses) gets full frame rate until it ends, then everything settles and it's once a second again.
            if !reduceMotion && motionEnds > Date() {
                TimelineView(GraphFrames(fastUntil: motionEnds, steady: false)) { context in
                    Canvas { canvas, size in drawConstellations(in: &canvas, size: size, time: context.date.timeIntervalSinceReferenceDate) }
                }
            } else {
                TimelineView(.periodic(from: .now, by: reduceMotion ? 3600 : 1)) { context in
                    Canvas { canvas, size in
                        drawConstellations(in: &canvas, size: size, time: reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate)
                    }
                }
            }
        }
        .accessibilityHidden(true)
    }

    /// When the last running effect finishes: change pulses, read flares, the camera glide, and the search sweep.
    private var motionEnds: Date {
        var ends = pulses.values.map { $0.addingTimeInterval(3) } + reads.values.map { $0.date.addingTimeInterval(Self.flareDuration) }
        if let glide = viewport.glide { ends.append(Date(timeIntervalSinceReferenceDate: glide.start + GraphViewport.glideDuration)) }
        if let morph = viewport.morph { ends.append(Date(timeIntervalSinceReferenceDate: morph.start + GraphViewport.morphDuration)) }
        // The sweep, plus time for the last star's ping to fade.
        if let search = viewport.search { ends.append(Date(timeIntervalSinceReferenceDate: search.changed + Self.sweepDuration + 0.9)) }
        return ends.max() ?? .distantPast
    }

    private func drawConstellations(in canvas: inout GraphicsContext, size: CGSize, time: Double) {
        let emphasis = viewport.emphasis
        // Keep the graph in the clear middle: it fades out where the side columns begin, so zooming in
        // never puts stars and labels behind the widgets.
        if let middle = viewport.fitWidth, middle < size.width {
            let inset = (size.width - middle) / 2, fade = min(60, inset * 0.5)
            canvas.clipToLayer { mask in
                mask.fill(Path(CGRect(origin: .zero, size: size)), with: .linearGradient(
                    Gradient(stops: [.init(color: .clear, location: (inset - fade) / size.width),
                                     .init(color: .black, location: (inset + fade * 0.4) / size.width),
                                     .init(color: .black, location: (size.width - inset - fade * 0.4) / size.width),
                                     .init(color: .clear, location: (size.width - inset + fade) / size.width)]),
                    startPoint: .zero, endPoint: CGPoint(x: size.width, y: 0)))
            }
        }
        func point(_ id: String) -> CGPoint? { viewport.point(id, layout: layout, size: size, time: time) }
        func depth(_ id: String) -> CGFloat { viewport.project(id, layout: layout, size: size, time: time)?.depth ?? 1 }
        // Far stars fade into fog in the sphere; elsewhere depth is 1 and nothing changes.
        func fog(_ d: CGFloat) -> Double { Double(min(1, max(0.18, (d - 0.62) / 0.55))) }
        drawViewGuides(in: &canvas, size: size, time: time)
        func color(_ id: String) -> Color { viewport.colors[id] ?? settings.constellationColor }
        let search = viewport.search
        let clock = Date().timeIntervalSinceReferenceDate   // for search effects, which run even when the drift is frozen
        let camera = viewport.camera(at: time)
        let center = CGPoint(x: size.width / 2 + camera.pan.width, y: size.height / 2 + camera.pan.height)
        let sweepReach = hypot(size.width, size.height) * 0.6
        let sweepAge = search.map { clock - $0.changed } ?? .infinity
        // How much the search effects still move: 1 while the sweep runs, easing to 0 as it ends, so halos and the
        // reticle come to rest instead of animating for as long as the search stays open.
        let motionEnd = motionEnds.timeIntervalSinceReferenceDate
        let liveness = reduceMotion ? 0 : max(0, min(1, (motionEnd - clock) / 0.8))
        for (a, b) in graph.edges {
            guard let pa = point(a), let pb = point(b) else { continue }
            var line = Path(); line.move(to: pa); line.addLine(to: pb)
            if let search {
                // Links between two matches light up; the rest nearly vanish.
                let lit = search.matches[a] != nil && search.matches[b] != nil
                canvas.stroke(line, with: .color(lit ? Self.searchColor.opacity(0.55) : color(b).opacity(0.04)), lineWidth: lit ? 1.1 : 0.5)
                continue
            }
            let highlighted = hovered == a || hovered == b
            let near = (depth(a) + depth(b)) / 2
            canvas.stroke(line, with: .color(color(b).opacity((highlighted ? 0.7 : 0.22) * emphasis * fog(near))),
                          lineWidth: (highlighted ? 1.2 : 0.6) * near)
        }
        // Sonar: a ring sweeps out from the centre each time the query changes; matches ping as it passes.
        if search != nil, !reduceMotion, sweepAge < Self.sweepDuration {
            let progress = sweepAge / Self.sweepDuration, ring = sweepReach * progress, fade = 1 - progress
            canvas.stroke(Path(ellipseIn: CGRect(x: center.x - ring, y: center.y - ring, width: ring * 2, height: ring * 2)),
                          with: .color(Self.searchColor.opacity(0.75 * fade)), lineWidth: 1.6)
            let trail = max(0, ring - 26)
            canvas.stroke(Path(ellipseIn: CGRect(x: center.x - trail, y: center.y - trail, width: trail * 2, height: trail * 2)),
                          with: .color(Self.searchColor.opacity(0.18 * fade)), lineWidth: 14)
        }
        let now = Date()
        // Far to near, so nearer stars are drawn over farther ones in the sphere.
        let placed = graph.nodes.compactMap { node in viewport.project(node.id, layout: layout, size: size, time: time).map { (node, $0) } }
            .sorted { $0.1.depth < $1.1.depth }
        for (node, projection) in placed {
            let p = projection.point, nearness = projection.depth
            let base: CGFloat = node.kind == .home ? 6 : node.kind == .map ? 4.2 : 2.4
            var radius = base * min(1.6, max(0.8, camera.zoom)) * (hovered == node.id ? 1.5 : 1) * nearness
            let tint = node.kind == .home ? Color.white : color(node.id)
            if let search {
                if let rank = search.matches[node.id] {
                    drawMatch(node, at: p, radius: radius, rank: rank, focused: search.focused == node.id,
                              clock: min(clock, motionEnd), liveness: liveness,
                              ping: sweepAge - Double(hypot(p.x - center.x, p.y - center.y) / sweepReach) * Self.sweepDuration, in: &canvas)
                } else {
                    canvas.fill(Path(ellipseIn: CGRect(x: p.x - radius * 0.8, y: p.y - radius * 0.8, width: radius * 1.6, height: radius * 1.6)),
                                with: .color(tint.opacity(0.14)))
                }
                continue
            }
            // An agent just read or searched this note: a warm light flares up, then fades.
            let readAge = reads[node.id].map { now.timeIntervalSince($0.date) }
            let reading = !reduceMotion && (readAge ?? .infinity) < Self.flareDuration
            if reading, let age = readAge {
                let strength = 1 - age / Self.flareDuration
                let flare = radius * (3 + 9 * min(1, age / 0.5))
                canvas.fill(Path(ellipseIn: CGRect(x: p.x - flare, y: p.y - flare, width: flare * 2, height: flare * 2)),
                            with: .radialGradient(Gradient(colors: [Self.flareColor.opacity(0.6 * strength), Self.flareColor.opacity(0.18 * strength), .clear]),
                                                  center: p, startRadius: 0, endRadius: flare))
                radius *= 1 + 0.9 * strength
            }
            let haze = fog(nearness)
            canvas.fill(Path(ellipseIn: CGRect(x: p.x - radius * 3.5, y: p.y - radius * 3.5, width: radius * 7, height: radius * 7)),
                        with: .radialGradient(Gradient(colors: [tint.opacity(0.32 * emphasis * haze), .clear]), center: p, startRadius: 0, endRadius: radius * 3.5))
            canvas.fill(Path(ellipseIn: CGRect(x: p.x - radius, y: p.y - radius, width: radius * 2, height: radius * 2)),
                        with: .color(reading ? Self.flareColor : tint.opacity(0.95 * haze)))
            if let pulse = pulses[node.id] {
                let age = now.timeIntervalSince(pulse)
                if age < 3 {
                    let ring = radius + CGFloat(age) * 18
                    canvas.stroke(Path(ellipseIn: CGRect(x: p.x - ring, y: p.y - ring, width: ring * 2, height: ring * 2)),
                                  with: .color(tint.opacity(0.85 * (1 - age / 3))), lineWidth: 1.3)
                }
            }
            if reading, let read = reads[node.id], let age = readAge {
                // Name the note and who read it while the light is up.
                let label = Text(node.title + (read.agent.isEmpty ? "" : "  · " + read.agent))
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                    .foregroundColor(Self.flareColor.opacity(1 - age / Self.flareDuration * 0.6))
                canvas.draw(label, at: CGPoint(x: p.x + radius + 6, y: p.y), anchor: .leading)
            } else if (node.kind != .note || hovered == node.id || viewport.zoom > 1.6) && (nearness > 0.9 || node.kind == .home || hovered == node.id) {
                let label = Text(node.kind == .note ? node.title : node.title.uppercased())
                    .font(.system(size: node.kind == .note ? 10 : 10.5, weight: node.kind == .note ? .regular : .semibold, design: .monospaced))
                    .foregroundColor(tint.opacity((hovered == node.id || node.kind != .note ? 0.95 : 0.7) * haze))
                canvas.draw(label, at: CGPoint(x: p.x + radius + 5, y: p.y), anchor: .leading)
            }
        }
    }

    /// Faint guides that show the shape of the view: a wireframe globe for the sphere, rings for orbits. They fade in
    /// as a view switch completes.
    private func drawViewGuides(in canvas: inout GraphicsContext, size: CGSize, time: Double) {
        let fade = viewport.morphProgress(at: time) * (viewport.search == nil ? 1 : 0.35)
        guard fade > 0.01, viewport.mode != .flat else { return }
        let scale = viewport.scale(in: size, time: time), origin = viewport.origin(in: size, time: time)
        let guide = settings.constellationColor
        switch viewport.mode {
        case .sphere:
            // Equator, two latitudes, and four meridians on a sphere just outside the stars.
            func circle(_ point: (Double) -> SIMD3<Double>) {
                var path = Path()
                for step in 0...72 {
                    let p = viewport.sphere(point(Double(step) / 72 * 2 * .pi), scale: scale, origin: origin, time: time).point
                    if step == 0 { path.move(to: p) } else { path.addLine(to: p) }
                }
                canvas.stroke(path, with: .color(guide.opacity(0.09 * fade)), lineWidth: 0.6)
            }
            let r = 0.98
            for latitude in [-0.5, 0.0, 0.5] {
                let ring = r * cos(latitude), height = r * sin(latitude)
                circle { SIMD3(ring * cos($0), height, ring * sin($0)) }
            }
            for meridian in 0..<4 {
                let angle = Double(meridian) * .pi / 4
                circle { SIMD3(r * cos($0) * cos(angle), r * sin($0), r * cos($0) * sin(angle)) }
            }
        case .orbit:
            func ring(_ centre: CGPoint, _ radius: Double, _ opacity: Double) {
                let r = CGFloat(radius) * scale * 1.3
                canvas.stroke(Path(ellipseIn: CGRect(x: centre.x - r, y: centre.y - r, width: r * 2, height: r * 2)),
                              with: .color(guide.opacity(opacity * fade)), style: StrokeStyle(lineWidth: 0.7, dash: [2, 5]))
            }
            var drawn = Set<String>()
            for orbit in layout.orbits.values where orbit.radius > 0 {
                let centre = orbit.parent.flatMap { layout.orbitPosition($0, time: time) }
                    .map { CGPoint(x: origin.x + $0.x * scale * 1.3, y: origin.y + $0.y * scale * 1.3) } ?? origin
                let key = (orbit.parent ?? "centre") + String(format: "%.3f", orbit.radius)
                if drawn.insert(key).inserted { ring(centre, orbit.radius, orbit.parent == nil ? 0.14 : 0.1) }
            }
        case .flat: break
        }
    }

    /// A search match: a pulsing cyan halo and label; the focused one also gets a rotating targeting reticle.
    private func drawMatch(_ node: VaultNode, at p: CGPoint, radius: CGFloat, rank: Int, focused: Bool, clock: Double, liveness: Double,
                           ping: Double, in canvas: inout GraphicsContext) {
        let cyan = Self.searchColor
        let beat = 0.5 + 0.5 * sin(clock * 3 + Double(rank) * 0.7) * liveness
        let r = radius * (focused ? 1.7 : 1.3)
        let glow = r * (4 + 1.5 * CGFloat(beat))
        canvas.fill(Path(ellipseIn: CGRect(x: p.x - glow, y: p.y - glow, width: glow * 2, height: glow * 2)),
                    with: .radialGradient(Gradient(colors: [cyan.opacity(focused ? 0.55 : 0.35), .clear]), center: p, startRadius: 0, endRadius: glow))
        let halo = r * (2.2 + 0.6 * CGFloat(beat))
        canvas.stroke(Path(ellipseIn: CGRect(x: p.x - halo, y: p.y - halo, width: halo * 2, height: halo * 2)),
                      with: .color(cyan.opacity(0.35 + 0.3 * beat)), lineWidth: 1)
        canvas.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)), with: .color(.white))
        if ping > 0 && ping < 0.8 && !reduceMotion {
            let ring = r + CGFloat(ping) * 46
            canvas.stroke(Path(ellipseIn: CGRect(x: p.x - ring, y: p.y - ring, width: ring * 2, height: ring * 2)),
                          with: .color(cyan.opacity(0.9 * (1 - ping / 0.8))), lineWidth: 1.8)
        }
        var labelX = p.x + halo + 6
        if focused {
            // Four brackets turning around the star, with crosshair ticks.
            // `clock` stops at the end of the motion, so the reticle comes to rest where it is instead of jumping.
            let size = r * 4.6 + 6 + 1.5 * CGFloat(sin(clock * 4) * liveness)
            let turn = reduceMotion ? 0 : clock * 0.9
            for k in 0..<4 {
                let angle = turn + Double(k) * .pi / 2
                var arc = Path()
                arc.addArc(center: p, radius: size, startAngle: .radians(angle), endAngle: .radians(angle + 0.55), clockwise: false)
                canvas.stroke(arc, with: .color(cyan), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                let tick = CGFloat(Double(k) * .pi / 2)
                var line = Path()
                line.move(to: CGPoint(x: p.x + cos(tick) * (size + 4), y: p.y + sin(tick) * (size + 4)))
                line.addLine(to: CGPoint(x: p.x + cos(tick) * (size + 11), y: p.y + sin(tick) * (size + 11)))
                canvas.stroke(line, with: .color(cyan.opacity(0.8)), lineWidth: 1.2)
            }
            labelX = p.x + size + 14
        }
        let label = Text(node.title)
            .font(.system(size: focused ? 13 : 10.5, weight: focused ? .bold : .semibold, design: .monospaced))
            .foregroundColor(focused ? .white : cyan)
        canvas.draw(label, at: CGPoint(x: labelX, y: p.y), anchor: .leading)
    }

    static let sweepDuration: TimeInterval = 1.4
    static let searchColor = Color(red: 0.42, green: 0.9, blue: 1.0)
    static let flareDuration: TimeInterval = 4
    static let flareColor = Color(red: 1.0, green: 0.88, blue: 0.58)

    static func noise(_ index: Int, _ salt: Int) -> Double {
        let value = sin(Double(index) * 12.9898 + Double(salt) * 78.233) * 43758.5453
        return value - floor(value)
    }
}

/// Frame times for the memory graph: every 1/60 s until `fastUntil`, then 30 fps while `steady`, otherwise once a
/// second. In the background (low-frequency mode) it's always once a second.
struct GraphFrames: TimelineSchedule {
    let fastUntil: Date
    let steady: Bool

    func entries(from start: Date, mode: TimelineScheduleMode) -> AnyIterator<Date> {
        var next = start
        return AnyIterator {
            let current = next
            let interval: TimeInterval = mode == .lowFrequency ? 1 : current < fastUntil ? 1.0 / 60 : steady ? 1.0 / 30 : 1
            next = current.addingTimeInterval(interval)
            return current
        }
    }
}
