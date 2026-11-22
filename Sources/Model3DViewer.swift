import SwiftUI
import SceneKit
import ModelIO

/// OBJ / USDZ / DAE / STL / PLY などを読み込む
enum ModelLoader {
    static func load(_ url: URL) -> SCNScene? {
        if let s = try? SCNScene(url: url, options: nil) { return s }
        let asset = MDLAsset(url: url)
        guard asset.count > 0 else { return nil }
        return SCNScene(mdlAsset: asset)
    }
}

/// 3Dモデルを回転・拡大・移動して見るビューア
struct ModelViewerView: View {
    let url: URL
    @State private var scene: SCNScene?
    @State private var failed = false
    @State private var wireframe = false
    @State private var resetToken = 0

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if let scene {
                SceneContainer(scene: scene, wireframe: wireframe, resetToken: resetToken)
                    .ignoresSafeArea(edges: .bottom)
                VStack(spacing: 10) {
                    Spacer()
                    HStack(spacing: 10) {
                        Button { wireframe.toggle() } label: {
                            Label(wireframe ? "面表示" : "ワイヤー", systemImage: "square.grid.3x3")
                        }
                        .glassButton()
                        Button { resetToken += 1 } label: {
                            Label("リセット", systemImage: "arrow.counterclockwise")
                        }
                        .glassButton()
                    }
                    .padding(.bottom, 8)
                }
                .padding(.horizontal)
            } else if failed {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle").font(.largeTitle)
                    Text("このモデルは読み込めませんでした")
                    Text("形式によっては未対応です（glTF / GLB は現在非対応）")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding()
            } else {
                ProgressView("読み込み中…")
            }
        }
        .task {
            if let s = ModelLoader.load(url) {
                scene = s
            } else {
                failed = true
            }
        }
    }
}

/// SCNView を SwiftUI に載せる
private struct SceneContainer: UIViewRepresentable {
    let scene: SCNScene
    let wireframe: Bool
    let resetToken: Int

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> SCNView {
        let v = SCNView()
        v.scene = scene
        v.allowsCameraControl = true      // 1本指で回転、2本指で移動、ピンチで拡大
        v.autoenablesDefaultLighting = true
        v.backgroundColor = .systemGroupedBackground
        v.antialiasingMode = .multisampling4X
        frame(v)
        context.coordinator.token = resetToken
        return v
    }

    func updateUIView(_ v: SCNView, context: Context) {
        v.debugOptions = wireframe ? [.showWireframe] : []
        if context.coordinator.token != resetToken {
            context.coordinator.token = resetToken
            frame(v)
        }
    }

    /// モデル全体が画面に収まるようカメラを置く
    private func frame(_ v: SCNView) {
        guard let scene = v.scene else { return }
        let (minV, maxV) = scene.rootNode.boundingBox
        let cx = (minV.x + maxV.x) / 2
        let cy = (minV.y + maxV.y) / 2
        let cz = (minV.z + maxV.z) / 2
        var size = max(maxV.x - minV.x, maxV.y - minV.y, maxV.z - minV.z)
        if size <= 0 { size = 1 }

        scene.rootNode.childNode(withName: "fitCamera", recursively: false)?.removeFromParentNode()
        let cam = SCNNode()
        cam.name = "fitCamera"
        cam.camera = SCNCamera()
        cam.camera?.zNear = Double(size) * 0.01
        cam.camera?.zFar = Double(size) * 100
        cam.position = SCNVector3(cx, cy, cz + size * 1.8)
        scene.rootNode.addChildNode(cam)
        v.pointOfView = cam
        v.defaultCameraController.target = SCNVector3(cx, cy, cz)
    }

    final class Coordinator {
        var token = 0
    }
}
