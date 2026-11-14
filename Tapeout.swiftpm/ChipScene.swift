import SceneKit
import CoreText
import simd

/// Builds and animates the 3D chip for a `Netlist`.
///
/// The layout mirrors how real chips are routed: logic cells sit in columns,
/// and wires run on three stacked metal layers (out of a cell on metal 1,
/// across on metal 2, into the next cell on metal 3) joined by vias, so
/// wires on the same layer never cross.
final class ChipScene {
    let scene = SCNScene()
    let cameraNode = SCNNode()
    /// The point the camera orbits around.
    private(set) var focus = SIMD3<Float>(0, 0, 0)

    private let chipRoot = SCNNode()
    private var netMaterials: [Signal: SCNMaterial] = [:]
    private var netLevel: [Signal: Int] = [:]
    private var netState: [Signal: Bool] = [:]
    private var generation = 0
    private var netNodes: [Signal: [SCNNode]] = [:]
    private var currentNet: Signal?

    // Layout constants (scene units)
    private let colSpacing: Float = 2.6
    private let slot: Float = 1.25
    private let dieTop: Float = 0.06
    private var yM1: Float { dieTop + 0.022 }
    private var yM2: Float { dieTop + 0.075 }
    private var yM3: Float { dieTop + 0.128 }
    private var yM4: Float { dieTop + 0.181 }
    /// Extra thickness for the wire being drawn, so buses stand taller than single wires.
    private var busBoost: Float = 0

    init() {
        scene.background.contents = Palette.background
        scene.lightingEnvironment.contents = Self.environmentImage()
        scene.lightingEnvironment.intensity = 1.1
        scene.rootNode.addChildNode(chipRoot)

        let camera = SCNCamera()
        camera.fieldOfView = 36
        camera.projectionDirection = .horizontal
        camera.zNear = 0.1
        camera.zFar = 200
        camera.wantsHDR = true
        camera.bloomThreshold = 0.9
        camera.bloomIntensity = 0.55
        camera.bloomBlurRadius = 10
        cameraNode.camera = camera
        scene.rootNode.addChildNode(cameraNode)

        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.intensity = 180
        let ambientNode = SCNNode()
        ambientNode.light = ambient
        scene.rootNode.addChildNode(ambientNode)

        let key = SCNLight()
        key.type = .directional
        key.intensity = 950
        key.color = CGColor(gray: 1, alpha: 1)
        key.castsShadow = true
        key.shadowMode = .deferred
        key.shadowRadius = 6
        key.shadowSampleCount = 16
        key.shadowMapSize = CGSize(width: 2048, height: 2048)
        key.shadowColor = CGColor(gray: 0, alpha: 0.55)
        key.orthographicScale = 14
        let keyNode = SCNNode()
        keyNode.light = key
        keyNode.simdPosition = SIMD3(-6, 12, 7)
        keyNode.simdLook(at: SIMD3(0, 0, 0))
        scene.rootNode.addChildNode(keyNode)

        let rim = SCNLight()
        rim.type = .directional
        rim.intensity = 260
        rim.color = CGColor(gray: 0.85, alpha: 1)
        let rimNode = SCNNode()
        rimNode.light = rim
        rimNode.simdPosition = SIMD3(7, 6, -8)
        rimNode.simdLook(at: SIMD3(0, 0, 0))
        scene.rootNode.addChildNode(rimNode)

        setLayout(nil)
    }

    // MARK: - Signal values

    func setValues(_ values: [Signal: UInt64], animated: Bool) {
        let generation = self.generation
        for (signal, material) in netMaterials {
            var on = (values[signal] ?? 0) != 0
            if case .const(let c) = signal { on = c != 0 }
            guard netState[signal] != on else { continue }
            netState[signal] = on
            let apply = { [weak self] in
                guard let self, self.generation == generation else { return }
                SCNTransaction.begin()
                SCNTransaction.animationDuration = animated ? 0.22 : 0
                Self.style(material, on: on)
                SCNTransaction.commit()
            }
            if animated {
                // Signals ripple through the chip one logic level at a time.
                let delay = Double(netLevel[signal] ?? 0) * 0.09
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: apply)
            } else {
                apply()
            }
        }
    }

    private static func style(_ material: SCNMaterial, on: Bool) {
        material.diffuse.contents = on ? Palette.signalOn : Palette.copper
        material.emission.contents = on ? Palette.signalGlow : Palette.black
        material.emission.intensity = on ? 0.85 : 0
    }

    private func material(for signal: Signal) -> SCNMaterial {
        if let m = netMaterials[signal] { return m }
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.metalness.contents = NSNumber(value: 0.85)
        m.roughness.contents = NSNumber(value: 0.38)
        Self.style(m, on: false)
        netMaterials[signal] = m
        return m
    }

    // MARK: - Highlighting

    /// Dims everything except the given signals (a cone of influence, or the critical path).
    func setHighlight(_ signals: Set<Signal>?) {
        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0.25
        for (signal, nodes) in netNodes {
            let lit = signals?.contains(signal) ?? true
            nodes.forEach { $0.opacity = lit ? 1 : 0.12 }
        }
        SCNTransaction.commit()
    }

    // MARK: - Building

    func setLayout(_ layout: ChipLayout?) {
        generation += 1
        chipRoot.childNodes.forEach { $0.removeFromParentNode() }
        netMaterials = [:]
        netLevel = [:]
        netState = [:]
        netNodes = [:]

        guard let layout else {
            buildPackage(dieW: 6.8, dieD: 4.2, name: "")
            frameCamera(width: 6.8 + 1.7, depth: 4.2 + 1.7)
            return
        }
        netLevel = layout.level
        buildPackage(dieW: layout.dieW, dieD: layout.dieD, name: layout.name)

        for pad in layout.pads {
            currentNet = pad.signal
            let node = self.pad(name: pad.name, at: pad.center, lamp: material(for: pad.signal), isInput: pad.isInput)
            chipRoot.addChildNode(node)
            netNodes[pad.signal, default: []].append(node)
        }
        for cell in layout.cells {
            let node = self.cell(cell)
            chipRoot.addChildNode(node)
            if let signal = cell.signal { netNodes[signal, default: []].append(node) }
        }
        let heights: [Float] = [dieTop, yM1, yM2, yM3, yM4]
        for w in layout.wires {
            currentNet = w.net
            busBoost = w.bits > 1 ? 0.02 : 0
            let mat = material(for: w.net)
            if w.isHorizontal {
                wire(fromX: w.a.x, toX: w.b.x, z: w.a.y, y: heights[w.layer], material: mat)
            } else {
                wire(x: w.a.x, fromZ: w.a.y, toZ: w.b.y, y: heights[w.layer], material: mat)
            }
        }
        for v in layout.vias {
            currentNet = v.net
            via(x: v.at.x, z: v.at.y, from: heights[v.from], to: heights[v.to], material: material(for: v.net))
        }
        currentNet = nil
        busBoost = 0
        frameCamera(width: layout.dieW + 1.7, depth: layout.dieD + 1.7)
    }

    private func frameCamera(width: Float, depth: Float) {
        let distance = max(width * 1.9, depth * 2.0)
        focus = SIMD3(0, 0, depth * 0.04)
        cameraNode.simdPosition = focus + SIMD3(0, distance * 0.78, distance * 0.63)
        cameraNode.simdLook(at: focus)
    }

    // MARK: - Parts

    private func buildPackage(dieW: Float, dieD: Float, name: String) {
        let border: Float = 0.85
        let w = dieW + border * 2
        let d = dieD + border * 2
        let bodyH: Float = 0.5

        // Circuit board underneath, to catch the shadow.
        let board = box(w + 2.6, 0.2, d + 2.6, chamfer: 0.1,
                        material: pbr(Palette.board, metalness: 0.0, roughness: 0.85))
        board.simdPosition = SIMD3(0, -bodyH - 0.16, 0)
        board.castsShadow = false
        chipRoot.addChildNode(board)

        let body = box(w, bodyH, d, chamfer: 0.09,
                       material: pbr(Palette.package, metalness: 0.05, roughness: 0.62))
        body.simdPosition = SIMD3(0, -bodyH / 2, 0)
        chipRoot.addChildNode(body)

        // The silicon die, with a faint cell grid.
        let silicon = pbr(Palette.silicon, metalness: 0.55, roughness: 0.34)
        silicon.diffuse.contents = Self.gridImage()
        silicon.diffuse.wrapS = .repeat
        silicon.diffuse.wrapT = .repeat
        silicon.diffuse.contentsTransform = SCNMatrix4(simd_float4x4(diagonal: SIMD4(dieW / 2, dieD / 2, 1, 1)))
        let edge = pbr(Palette.siliconEdge, metalness: 0.5, roughness: 0.4)
        let die = SCNNode(geometry: SCNBox(width: CGFloat(dieW), height: CGFloat(dieTop), length: CGFloat(dieD), chamferRadius: 0))
        die.geometry?.materials = [edge, edge, edge, edge, silicon, edge]
        die.simdPosition = SIMD3(0, dieTop / 2, 0)
        chipRoot.addChildNode(die)

        // Gold legs around the package.
        let gold = pbr(Palette.gold, metalness: 1.0, roughness: 0.32)
        let pitch: Float = 0.62
        func legs(along length: Float, place: (Float) -> (SIMD3<Float>, Bool)) {
            let count = max(2, Int((length - 0.8) / pitch))
            for i in 0..<count {
                let offset = (Float(i) - Float(count - 1) / 2) * pitch
                let (position, alongX) = place(offset)
                let leg = box(alongX ? 0.55 : 0.26, 0.1, alongX ? 0.26 : 0.55, chamfer: 0.03, material: gold)
                leg.simdPosition = position
                chipRoot.addChildNode(leg)
            }
        }
        let legY = -bodyH + 0.06
        legs(along: w) { (SIMD3($0, legY, d / 2 + 0.16), false) }
        legs(along: w) { (SIMD3($0, legY, -d / 2 - 0.16), false) }
        legs(along: d) { (SIMD3(w / 2 + 0.16, legY, $0), true) }
        legs(along: d) { (SIMD3(-w / 2 - 0.16, legY, $0), true) }

        // Pin-1 marker and the module name, laser-etched on the package.
        let dot = SCNNode(geometry: SCNCylinder(radius: 0.11, height: 0.012))
        dot.geometry?.firstMaterial = pbr(Palette.etch, metalness: 0, roughness: 0.9)
        dot.simdPosition = SIMD3(-w / 2 + 0.42, 0.004, d / 2 - 0.42)
        chipRoot.addChildNode(dot)

        if !name.isEmpty, let image = Self.textImage(name.uppercased(), fontSize: 54, color: Palette.etchText, tracking: 6) {
            let height: Float = 0.26
            let width = min(height * Float(image.width) / Float(image.height), w - 2.2)
            let plane = SCNPlane(width: CGFloat(width), height: CGFloat(width * Float(image.height) / Float(image.width)))
            let m = SCNMaterial()
            m.lightingModel = .constant
            m.diffuse.contents = image
            m.blendMode = .alpha
            m.writesToDepthBuffer = false
            plane.firstMaterial = m
            let label = SCNNode(geometry: plane)
            label.simdEulerAngles = SIMD3(-.pi / 2, 0, 0)
            label.simdPosition = SIMD3(w / 2 - width / 2 - 0.42, 0.004, d / 2 - 0.42)
            label.castsShadow = false
            chipRoot.addChildNode(label)
        }
    }

    private func cell(_ cell: ChipLayout.Cell) -> SCNNode {
        let size = SIMD3<Float>(cell.size.x, 0.3, cell.size.y)
        let side = pbr(Palette.cellSide, metalness: 0.25, roughness: 0.42)
        let top = pbr(Palette.cellTop, metalness: 0.2, roughness: 0.5)
        top.diffuse.contents = Self.cellImage(cell.label, aspect: CGFloat(size.z / size.x))
        let geometry = SCNBox(width: CGFloat(size.x), height: CGFloat(size.y), length: CGFloat(size.z), chamferRadius: 0.045)
        geometry.materials = [side, side, side, side, top, side]
        let node = SCNNode(geometry: geometry)
        node.simdPosition = SIMD3(cell.center.x, dieTop + size.y / 2, cell.center.y)
        guard let signal = cell.signal else { return node }
        if case .gate(let id) = signal { node.name = "gate:\(id)" }

        // A light bar on the output edge shows what the cell is driving.
        let bar = box(0.05, 0.02, size.z - 0.34, chamfer: 0.008, material: material(for: signal))
        bar.simdPosition = SIMD3(size.x / 2 - 0.11, size.y / 2 + 0.008, 0)
        bar.castsShadow = false
        node.addChildNode(bar)
        return node
    }

    private func pad(name: String, at p: SIMD2<Float>, lamp: SCNMaterial, isInput: Bool) -> SCNNode {
        let node = SCNNode()
        node.name = isInput ? "input:\(name)" : "output:\(name)"
        node.simdPosition = SIMD3(p.x, dieTop, p.y)

        let base = box(0.6, 0.04, 0.6, chamfer: 0.015, material: pbr(Palette.gold, metalness: 1.0, roughness: 0.3))
        base.simdPosition = SIMD3(0, 0.02, 0)
        node.addChildNode(base)

        if isInput {
            let key = box(0.36, 0.07, 0.36, chamfer: 0.03, material: lamp)
            key.simdPosition = SIMD3(0, 0.07, 0)
            node.addChildNode(key)
        } else {
            let dome = SCNNode(geometry: SCNSphere(radius: 0.19))
            dome.geometry?.firstMaterial = lamp
            dome.simdScale = SIMD3(1, 0.62, 1)
            dome.simdPosition = SIMD3(0, 0.05, 0)
            node.addChildNode(dome)
        }

        if let image = Self.tagImage(name) {
            let height: Float = 0.3
            let plane = SCNPlane(width: CGFloat(height * Float(image.width) / Float(image.height)), height: CGFloat(height))
            let m = SCNMaterial()
            m.lightingModel = .constant
            m.diffuse.contents = image
            m.blendMode = .alpha
            m.writesToDepthBuffer = false
            m.isDoubleSided = true
            plane.firstMaterial = m
            let tag = SCNNode(geometry: plane)
            tag.simdPosition = SIMD3(0, 0.62, 0)
            tag.constraints = [SCNBillboardConstraint()]
            tag.castsShadow = false
            tag.renderingOrder = 10
            node.addChildNode(tag)
        }
        return node
    }

    private let wireWidth: Float = 0.06
    private let wireHeight: Float = 0.024

    private func wire(fromX a: Float, toX b: Float, z: Float, y: Float, material: SCNMaterial) {
        let length = abs(b - a)
        guard length > 0.001 else { return }
        let node = box(length + wireWidth, wireHeight + busBoost, wireWidth, chamfer: 0, material: material)
        node.simdPosition = SIMD3((a + b) / 2, y + busBoost / 2, z)
        node.castsShadow = false
        chipRoot.addChildNode(node)
        if let net = currentNet { netNodes[net, default: []].append(node) }
    }

    private func wire(x: Float, fromZ a: Float, toZ b: Float, y: Float, material: SCNMaterial) {
        let length = abs(b - a)
        guard length > 0.001 else { return }
        let node = box(wireWidth, wireHeight + busBoost, length + wireWidth, chamfer: 0, material: material)
        node.simdPosition = SIMD3(x, y + busBoost / 2, (a + b) / 2)
        node.castsShadow = false
        chipRoot.addChildNode(node)
        if let net = currentNet { netNodes[net, default: []].append(node) }
    }

    private func via(x: Float, z: Float, from y0: Float, to y1: Float, material: SCNMaterial) {
        let height = abs(y1 - y0) + wireHeight
        let geometry = SCNCylinder(radius: 0.052, height: CGFloat(height))
        geometry.radialSegmentCount = 16
        geometry.firstMaterial = material
        let node = SCNNode(geometry: geometry)
        node.simdPosition = SIMD3(x, (y0 + y1) / 2, z)
        node.castsShadow = false
        chipRoot.addChildNode(node)
        if let net = currentNet { netNodes[net, default: []].append(node) }
    }

    private func box(_ w: Float, _ h: Float, _ d: Float, chamfer: Float, material: SCNMaterial) -> SCNNode {
        let geometry = SCNBox(width: CGFloat(w), height: CGFloat(h), length: CGFloat(d), chamferRadius: CGFloat(chamfer))
        geometry.firstMaterial = material
        return SCNNode(geometry: geometry)
    }

    private func pbr(_ color: CGColor, metalness: Float, roughness: Float) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = color
        m.metalness.contents = NSNumber(value: metalness)
        m.roughness.contents = NSNumber(value: roughness)
        return m
    }

    // MARK: - Textures (drawn with Core Graphics so nothing ships as an asset)

    private static func context(_ width: Int, _ height: Int) -> CGContext? {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    private static func line(_ text: String, fontSize: CGFloat, color: CGColor, tracking: CGFloat = 0, mono: Bool = false) -> CTLine {
        let base = CTFontCreateUIFontForLanguage(mono ? .userFixedPitch : .emphasizedSystem, fontSize, nil)
            ?? CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): base,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
            NSAttributedString.Key(kCTKernAttributeName as String): tracking,
        ]
        return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
    }

    private static func draw(_ line: CTLine, centeredIn rect: CGRect, context: CGContext) {
        let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
        context.textPosition = CGPoint(x: rect.midX - bounds.width / 2 - bounds.minX,
                                       y: rect.midY - bounds.height / 2 - bounds.minY)
        CTLineDraw(line, context)
    }

    /// Plain text on a transparent background.
    private static func textImage(_ text: String, fontSize: CGFloat, color: CGColor, tracking: CGFloat) -> CGImage? {
        let l = line(text, fontSize: fontSize, color: color, tracking: tracking)
        let bounds = CTLineGetBoundsWithOptions(l, .useOpticalBounds)
        let size = CGSize(width: ceil(bounds.width) + 16, height: ceil(fontSize * 1.4))
        guard let ctx = context(Int(size.width), Int(size.height)) else { return nil }
        draw(l, centeredIn: CGRect(origin: .zero, size: size), context: ctx)
        return ctx.makeImage()
    }

    /// A small rounded name tag that floats above a pad.
    private static func tagImage(_ text: String) -> CGImage? {
        let l = line(text, fontSize: 50, color: Palette.tagText, mono: true)
        let bounds = CTLineGetBoundsWithOptions(l, .useOpticalBounds)
        let size = CGSize(width: max(ceil(bounds.width) + 56, 96), height: 88)
        guard let ctx = context(Int(size.width), Int(size.height)) else { return nil }
        let rect = CGRect(origin: .zero, size: size).insetBy(dx: 3, dy: 3)
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 24, cornerHeight: 24, transform: nil))
        ctx.setFillColor(Palette.tagFill)
        ctx.fillPath()
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 24, cornerHeight: 24, transform: nil))
        ctx.setStrokeColor(Palette.tagStroke)
        ctx.setLineWidth(2)
        ctx.strokePath()
        draw(l, centeredIn: rect, context: ctx)
        return ctx.makeImage()
    }

    private static var cellImages: [String: CGImage] = [:]

    /// The printed top face of a cell. `aspect` is its depth over its width.
    private static func cellImage(_ label: String, aspect: CGFloat) -> CGImage? {
        let key = "\(label)|\(Int(aspect * 100))"
        if let cached = cellImages[key] { return cached }
        let w = 352, h = max(Int(352 * aspect), 120)
        guard let ctx = context(w, h) else { return nil }
        ctx.setFillColor(Palette.cellTop)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setStrokeColor(Palette.cellInset)
        ctx.setLineWidth(3)
        ctx.addPath(CGPath(roundedRect: CGRect(x: 22, y: 22, width: w - 44, height: h - 44),
                           cornerWidth: 16, cornerHeight: 16, transform: nil))
        ctx.strokePath()
        let fontSize = min(70, CGFloat(w - 110) / (0.7 * CGFloat(max(label.count, 1))))
        draw(line(label, fontSize: fontSize, color: Palette.cellText, tracking: 4),
             centeredIn: CGRect(x: 0, y: 0, width: w - 30, height: h), context: ctx)
        let image = ctx.makeImage()
        cellImages[key] = image
        return image
    }

    private static func gridImage() -> CGImage? {
        let n = 256
        guard let ctx = context(n, n) else { return nil }
        ctx.setFillColor(Palette.silicon)
        ctx.fill(CGRect(x: 0, y: 0, width: n, height: n))
        ctx.setStrokeColor(Palette.siliconGrid)
        ctx.setLineWidth(1.5)
        for i in stride(from: 0, through: n, by: 64) {
            ctx.move(to: CGPoint(x: i, y: 0)); ctx.addLine(to: CGPoint(x: i, y: n))
            ctx.move(to: CGPoint(x: 0, y: i)); ctx.addLine(to: CGPoint(x: n, y: i))
        }
        ctx.strokePath()
        return ctx.makeImage()
    }

    /// A soft studio gradient used for reflections on the metal.
    private static func environmentImage() -> CGImage? {
        let (w, h) = (64, 256)
        guard let ctx = context(w, h) else { return nil }
        let colors = [CGColor(gray: 0.03, alpha: 1), CGColor(gray: 0.16, alpha: 1),
                      CGColor(gray: 0.64, alpha: 1), CGColor(gray: 0.95, alpha: 1)] as CFArray
        guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: colors,
                                        locations: [0, 0.45, 0.8, 1]) else { return nil }
        ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: h), options: [])
        return ctx.makeImage()
    }
}

/// Scene colours: black and dark gray, with white reserved for live signals.
enum Palette {
    static func hex(_ v: UInt32, alpha: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                blue: CGFloat(v & 0xFF) / 255, alpha: alpha)
    }
    static let background = hex(0x000000)
    static let black = hex(0x000000)
    static let board = hex(0x0D0D0D)
    static let package = hex(0x1A1A1A)
    static let etch = hex(0x2A2A2A)
    static let etchText = hex(0x9A9A9A, alpha: 0.55)
    static let silicon = hex(0x0B0B0B)
    static let siliconGrid = hex(0x1A1A1A)
    static let siliconEdge = hex(0x080808)
    static let gold = hex(0x7C7C80)        // pins and pads: brushed steel
    static let copper = hex(0x77777C)      // idle wire
    static let signalOn = hex(0xFFFFFF)
    static let signalGlow = hex(0xFFFFFF)
    static let cellSide = hex(0x242424)
    static let cellTop = hex(0x2E2E2E)
    static let cellInset = hex(0x444444)
    static let cellText = hex(0xE8E8E8)
    static let tagFill = hex(0x000000, alpha: 0.82)
    static let tagStroke = hex(0xFFFFFF, alpha: 0.18)
    static let tagText = hex(0xE8E8E8)
}
