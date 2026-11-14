import SwiftUI
import SceneKit

/// Hosts the SceneKit chip. Drag to orbit, pinch to zoom, tap an input pad to flip it, tap a gate to trace it.
struct ChipView: UIViewRepresentable {
    let layout: ChipLayout?
    /// Changes whenever `layout` does.
    let version: Int
    let signals: [Signal: UInt64]
    let highlight: Set<Signal>?
    let onToggle: (String) -> Void
    let onSelect: (Signal) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> SCNView {
        let coordinator = context.coordinator
        let view = SCNView()
        view.scene = coordinator.chip.scene
        view.pointOfView = coordinator.chip.cameraNode
        view.backgroundColor = UIColor(Theme.background)
        view.antialiasingMode = .multisampling4X
        view.allowsCameraControl = true
        view.defaultCameraController.interactionMode = .orbitTurntable
        view.defaultCameraController.minimumVerticalAngle = 12
        view.defaultCameraController.maximumVerticalAngle = 88
        view.defaultCameraController.inertiaEnabled = true
        view.addGestureRecognizer(UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.tapped(_:))))
        coordinator.view = view
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onToggle = onToggle
        coordinator.onSelect = onSelect
        if coordinator.version != version {
            coordinator.version = version
            coordinator.chip.setLayout(layout)
            view.pointOfView = coordinator.chip.cameraNode
            view.defaultCameraController.target = SCNVector3(coordinator.chip.focus)
            coordinator.chip.setValues(signals, animated: false)
            coordinator.highlight = nil
        } else {
            coordinator.chip.setValues(signals, animated: true)
        }
        if coordinator.highlight != highlight {
            coordinator.highlight = highlight
            coordinator.chip.setHighlight(highlight)
        }
    }

    final class Coordinator: NSObject {
        let chip = ChipScene()
        var version = -1
        var highlight: Set<Signal>?
        var onToggle: (String) -> Void = { _ in }
        var onSelect: (Signal) -> Void = { _ in }
        weak var view: SCNView?

        @objc func tapped(_ gesture: UITapGestureRecognizer) {
            guard let view else { return }
            let hits = view.hitTest(gesture.location(in: view), options: [.searchMode: SCNHitTestSearchMode.all.rawValue])
            for hit in hits {
                var node: SCNNode? = hit.node
                while let current = node {
                    if let name = current.name, name.hasPrefix("input:") {
                        onToggle(String(name.dropFirst("input:".count)))
                        return
                    }
                    if let name = current.name, name.hasPrefix("gate:"), let id = Int(name.dropFirst("gate:".count)) {
                        onSelect(.gate(id))
                        return
                    }
                    node = current.parent
                }
            }
        }
    }
}
