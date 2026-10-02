import AppKit
import EchoRuntime
import SwiftUI

struct PetError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

// Owns the Rust handle. No borrowed Rust buffer escapes initialization.
final class RuntimeHandle {
    let pointer: OpaquePointer

    init(directory: URL) throws {
        var error = [CChar](repeating: 0, count: 2048)
        guard let pointer = directory.path.withCString({ echo_create($0, &error, error.count) }) else {
            throw PetError(message: String(decoding: error.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
        }
        self.pointer = pointer
    }

    deinit { echo_destroy(pointer) }
}

@MainActor
final class PetStore: ObservableObject {
    // Codex's default floating pet width; AppKit points match CSS logical pixels.
    private static let displayWidth: CGFloat = 112
    @Published private(set) var image: CGImage
    private(set) var spriteIndex: UInt32 = 0
    let size: NSSize
    let displayName: String
    private var handle: RuntimeHandle?
    private let images: [CGImage]
    private var timer: Timer?
    var onFailure: ((Error) -> Void)?
    /// The runtime's tick. Only tests replace it, to fail a tick the way a runtime error would.
    var advance: (OpaquePointer, UnsafeMutablePointer<EchoTick>) -> Bool = { echo_tick($0, $1) }

    init(directory: URL) throws {
        struct Metadata: Decodable { var displayName: String? }
        let metadata = try? JSONDecoder().decode(Metadata.self, from: Data(contentsOf: directory.appendingPathComponent("pet.json")))
        let name = metadata?.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.displayName = name.flatMap { $0.isEmpty ? nil : $0 } ?? "桌面精灵"
        let handle = try RuntimeHandle(directory: directory)
        var info = EchoInfo()
        guard echo_info(handle.pointer, &info), info.frame_count > 0 else {
            throw PetError(message: "无法读取精灵帧信息。")
        }
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        var images: [CGImage] = []
        for index in 0..<info.frame_count {
            var frame = EchoFrame()
            guard echo_frame(handle.pointer, index, &frame), let bytes = frame.data else {
                throw PetError(message: "无法读取第 \(index) 帧。")
            }
            // Data(bytes:count:) copies Rust memory. CGDataProvider retains it.
            let data = Data(bytes: bytes, count: frame.length)
            guard let provider = CGDataProvider(data: data as CFData),
                  let image = CGImage(
                    width: Int(info.width), height: Int(info.height),
                    bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: Int(info.width) * 4,
                    space: colorSpace,
                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue)
                        .union(.byteOrder32Big),
                    provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
                  ) else {
                throw PetError(message: "无法创建第 \(index) 帧图像。")
            }
            images.append(image)
        }
        self.handle = handle
        self.images = images
        self.image = images[0]
        self.size = NSSize(width: Self.displayWidth,
                           height: Self.displayWidth * CGFloat(info.height) / CGFloat(info.width))
    }

    func start() { refresh() }

    func wave() {
        play("waving")
    }

    func interact(hovered: Bool, direction: Int32) {
        guard let handle else { return }
        guard echo_set_interaction(handle.pointer, hovered, direction) else {
            fail(PetError(message: "无法更新精灵交互状态。"))
            return
        }
        refresh()
    }

    func look(at offset: NSPoint) {
        guard let handle else { return }
        guard echo_look_at(handle.pointer, offset.x, offset.y) else {
            fail(PetError(message: "无法更新精灵注视方向。"))
            return
        }
        refresh()
    }

    /// Hold the frame that is already showing instead of advancing. Reduce Motion pauses the
    /// Live Voice planet here, which leaves the state readable rather than blanking the mark.
    var isPaused = false {
        didSet {
            guard isPaused != oldValue else { return }
            if isPaused {
                timer?.invalidate()
                timer = nil
            } else {
                refresh()
            }
        }
    }

    func play(_ animation: String) {
        guard let handle else { return }
        guard echo_set_animation(handle.pointer, animation) else {
            fail(PetError(message: "无法播放动画：\(animation)。"))
            return
        }
        refresh()
    }

    /// Plays `animation` when this sprite has it and `fallback` otherwise, returning the clip that
    /// plays. The runtime is what knows a sheet's clips, so callers never mirror its catalogue.
    @discardableResult func play(_ animation: String, fallback: String) -> String? {
        guard let handle else { return nil }
        if echo_set_animation(handle.pointer, animation) {
            refresh()
            return self.handle == nil ? nil : animation
        }
        play(fallback)
        return self.handle == nil ? nil : fallback
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        handle = nil
    }

    private func refresh() {
        timer?.invalidate()
        timer = nil
        guard let handle else { return }
        var tick = EchoTick()
        guard advance(handle.pointer, &tick), Int(tick.sprite_index) < images.count else {
            fail(PetError(message: "精灵动画推进失败。"))
            return
        }
        if spriteIndex != tick.sprite_index {
            spriteIndex = tick.sprite_index
            image = images[Int(tick.sprite_index)]
        }
        if tick.next_frame_seconds > 0 && !isPaused {
            let timer = Timer(timeInterval: max(0.001, tick.next_frame_seconds), repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
            self.timer = timer
            // Includes event tracking: moving the pet does not freeze animation.
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    private func fail(_ error: Error) {
        stop()
        onFailure?(error)
    }
}

struct PetView: View {
    @ObservedObject var store: PetStore
    var body: some View {
        // Keep SwiftUI hit testing enabled: disabling it also makes WindowServer
        // pass clicks through this hosting view, so the pet panel never sees them.
        // PetInteractionView.hitTest then sends delivered clicks to its gesture
        // recognizers and its context menu.
        Image(decorative: store.image, scale: 1, orientation: .up)
            .resizable()
            .interpolation(.high)
            .frame(width: store.size.width, height: store.size.height)
            .accessibilityLabel(store.displayName)
    }
}

#Preview("桌面精灵") {
    if let directory = Bundle.main.resourceURL?.appendingPathComponent("pets/chiyan"),
       let store = try? PetStore(directory: directory) {
        PetView(store: store)
            .padding(24)
    } else {
        Text("无法加载内置精灵素材")
    }
}
