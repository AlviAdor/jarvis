import SwiftUI
import AppKit
import MetalKit
import simd

/// The particle sphere: points spread evenly over a globe, turning slowly in 3D. Nearer points are larger
/// and brighter. Each point drifts on its own sine, the surface ripples with your voice, and the whole globe
/// turns faster while Jarvis works. The GPU does all of it; each frame the app only updates a few numbers.
final class SphereRenderer: NSObject, MTKViewDelegate {
    struct Uniforms {
        var time: Float = 0
        var angle: Float = 0
        var level: Float = 0
        var energy: Float = 0.4
        var aspect: Float = 1
        var pointSize: Float = 4
        var tilt: Float = 0.38
        var ringAngle: Float = 0
        var color = SIMD4<Float>(0.24, 0.84, 0.96, 1)
    }

    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let points: MTLBuffer
    private let count: Int
    private var u = Uniforms()
    private var last = CACurrentMediaTime()
    private let start = CACurrentMediaTime()

    // Targets the animation eases towards, so changes never jump.
    var targetSpeed: Float = 0.2
    var targetEnergy: Float = 0.4
    var targetLevel: Float = 0
    var speaking = false
    var idle = true
    private var speed: Float = 0.2
    private var smoothLevel: Float = 0

    var color: SIMD4<Float> {
        get { u.color }
        set { u.color = newValue }
    }

    static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    struct U { float time; float angle; float level; float energy; float aspect; float pointSize; float tilt; float ringAngle; float4 color; };
    struct VOut { float4 pos [[position]]; float size [[point_size]]; float front; float ring; };

    vertex VOut sphere_vertex(uint vid [[vertex_id]], const device float4 *pts [[buffer(0)]], constant U &u [[buffer(1)]]) {
        float4 d = pts[vid];
        // Ring particles orbit on their own tilted plane, at their own pace.
        if (d.w >= 2.0) {
            float seed = d.w - 2.0;
            float a = d.x + u.ringAngle * (1.0 + 0.08 * sin(seed * 9.0));
            float r = 1.36 + d.y + u.level * 0.06 * sin(u.time * 6.0 + seed * 20.0);
            float3 p = float3(cos(a) * r, d.z, sin(a) * r);
            float rt = 1.18;
            p = float3(p.x, cos(rt) * p.y - sin(rt) * p.z, sin(rt) * p.y + cos(rt) * p.z);
            float rz = -0.42;
            p = float3(cos(rz) * p.x - sin(rz) * p.y, sin(rz) * p.x + cos(rz) * p.y, p.z);
            float cam = 3.2;
            float s = cam / (cam - p.z);
            float2 xy = p.xy * s * 0.6;
            VOut o;
            o.pos = float4(xy.x / max(u.aspect, 0.01), xy.y, 0.0, 1.0);
            o.front = clamp((p.z + 1.4) / 2.8, 0.0, 1.0);
            o.size = u.pointSize * s * (0.5 + 0.7 * o.front);
            o.ring = 1.0;
            return o;
        }
        float3 p = d.xyz;
        float seed = d.w;
        float drift = 1.0 + u.energy * 0.035 * sin(u.time * 1.3 + seed * 17.0)
                          + u.level * 0.24 * sin(u.time * 7.0 + seed * 31.0) * (0.5 + 0.5 * sin(seed * 5.0 + u.time * 2.0));
        p *= drift;
        float ca = cos(u.angle), sa = sin(u.angle);
        p = float3(ca * p.x + sa * p.z, p.y, -sa * p.x + ca * p.z);
        float ct = cos(u.tilt), st = sin(u.tilt);
        p = float3(p.x, ct * p.y - st * p.z, st * p.y + ct * p.z);
        float cam = 3.2;
        float s = cam / (cam - p.z);
        float2 xy = p.xy * s * 0.6;
        VOut o;
        o.pos = float4(xy.x / max(u.aspect, 0.01), xy.y, 0.0, 1.0);
        o.front = clamp((p.z + 1.0) * 0.5, 0.0, 1.0);
        o.size = u.pointSize * s * (0.45 + 0.85 * o.front);
        o.ring = 0.0;
        return o;
    }

    fragment float4 sphere_fragment(VOut in [[stage_in]], float2 pc [[point_coord]], constant U &u [[buffer(1)]]) {
        float d = length(pc - 0.5);
        float a = smoothstep(0.5, 0.15, d) * (0.14 + 0.86 * in.front);
        // The globe is mostly white light with a hint of the accent; the ring carries the accent itself.
        float3 c = in.ring > 0.5 ? mix(u.color.rgb, float3(1.0), 0.12 + 0.2 * in.front)
                                 : mix(u.color.rgb, float3(1.0), 0.35 + 0.45 * in.front);
        a *= in.ring > 0.5 ? 0.85 : 1.0;
        return float4(c * a, a);
    }
    """

    init?(view: MTKView, count: Int = 900, ring: Int = 260) {
        guard let device = view.device ?? MTLCreateSystemDefaultDevice(), let q = device.makeCommandQueue() else { return nil }
        view.device = device
        queue = q
        self.count = count + ring
        do {
            let lib = try device.makeLibrary(source: Self.shader, options: nil)
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = lib.makeFunction(name: "sphere_vertex")
            desc.fragmentFunction = lib.makeFunction(name: "sphere_fragment")
            let att = desc.colorAttachments[0]!
            att.pixelFormat = view.colorPixelFormat
            att.isBlendingEnabled = true
            att.rgbBlendOperation = .add
            att.alphaBlendOperation = .add
            att.sourceRGBBlendFactor = .one
            att.sourceAlphaBlendFactor = .one
            att.destinationRGBBlendFactor = .oneMinusSourceAlpha
            att.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            pipeline = try device.makeRenderPipelineState(descriptor: desc)
        } catch {
            return nil
        }
        // A Fibonacci sphere spreads points evenly; a little radial noise keeps it organic.
        var pts: [SIMD4<Float>] = []
        pts.reserveCapacity(count)
        let golden = Float.pi * (3 - sqrt(5))
        var rng = SystemRandomNumberGenerator()
        for i in 0..<count {
            let y = 1 - Float(i) / Float(count - 1) * 2
            let r = (1 - y * y).squareRoot()
            let t = golden * Float(i)
            let jitter = Float.random(in: 0.965...1.035, using: &rng)
            pts.append(SIMD4(cos(t) * r * jitter, y * jitter, sin(t) * r * jitter, Float.random(in: 0...1, using: &rng)))
        }
        for i in 0..<ring {
            let a = Float(i) / Float(ring) * 2 * .pi + Float.random(in: -0.02...0.02, using: &rng)
            pts.append(SIMD4(a, Float.random(in: -0.035...0.035, using: &rng), Float.random(in: -0.02...0.02, using: &rng),
                             2 + Float.random(in: 0...1, using: &rng)))
        }
        guard let buf = device.makeBuffer(bytes: pts, length: MemoryLayout<SIMD4<Float>>.stride * pts.count) else { return nil }
        points = buf
        super.init()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        // Frame rate follows attention: smooth while Jarvis is active, gentle at rest, slower still in the background.
        let fps = idle ? (view.window?.isKeyWindow == true ? 20 : 10) : 60
        if view.preferredFramesPerSecond != fps { view.preferredFramesPerSecond = fps }
        let now = CACurrentMediaTime()
        let dt = Float(min(now - last, 0.1))
        last = now
        speed += (targetSpeed - speed) * min(1, dt * 2)
        u.energy += (targetEnergy - u.energy) * min(1, dt * 2)
        var lvl = targetLevel
        if speaking { lvl = max(lvl, 0.18 + 0.14 * Float(sin(now * 9) * 0.5 + 0.5)) }
        smoothLevel += (lvl - smoothLevel) * min(1, dt * 10)
        u.level = smoothLevel
        u.angle += dt * speed
        u.ringAngle -= dt * (0.35 + speed * 0.8)
        u.time = Float(now - start)
        let size = view.drawableSize
        u.aspect = Float(size.width / max(size.height, 1))
        u.pointSize = Float(min(size.width, size.height)) * 0.0095

        guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let cmd = queue.makeCommandBuffer(), let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }
        enc.setRenderPipelineState(pipeline)
        enc.setVertexBuffer(points, offset: 0, index: 0)
        enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
        enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
        enc.drawPrimitives(type: .point, vertexStart: 0, vertexCount: count)
        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()
    }
}

struct ParticleSphereView: NSViewRepresentable {
    let phase: Phase
    let accent: Color
    let still: Bool
    var level: Float = 0

    final class Coordinator { var renderer: SphereRenderer? }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> MTKView {
        let v = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        v.colorPixelFormat = .bgra8Unorm
        v.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        v.layer?.isOpaque = false
        v.layer?.backgroundColor = .clear
        v.framebufferOnly = true
        v.preferredFramesPerSecond = 20
        context.coordinator.renderer = SphereRenderer(view: v)
        v.delegate = context.coordinator.renderer
        return v
    }

    func updateNSView(_ v: MTKView, context: Context) {
        guard let r = context.coordinator.renderer else { return }
        let c = NSColor(accent).usingColorSpace(.sRGB) ?? .cyan
        r.color = SIMD4(Float(c.redComponent), Float(c.greenComponent), Float(c.blueComponent), 1)
        let (speed, energy): (Float, Float)
        switch phase {
        case .idle: (speed, energy) = (0.18, 0.4)
        case .listening: (speed, energy) = (0.32, 0.75)
        case .thinking: (speed, energy) = (0.85, 1.25)
        case .acting: (speed, energy) = (1.1, 1.45)
        case .speaking: (speed, energy) = (0.42, 1.0)
        }
        r.targetSpeed = speed
        r.targetEnergy = energy
        r.targetLevel = min(level, 1)
        r.speaking = phase == .speaking
        r.idle = phase == .idle
        // Fully stopped while hidden; the renderer picks the frame rate otherwise.
        v.isPaused = still
        if still { v.draw() }
    }
}
