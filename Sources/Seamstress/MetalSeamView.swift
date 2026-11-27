import Cocoa
import Metal
import QuartzCore
import SeamstressCore
import simd

/// Uniform layout shared between Swift and the embedded MSL seam shader.
/// Keep field order and alignment in sync with `struct SeamUniforms` in `MetalSeamPipeline`.
struct SeamShaderUniforms {
    var resolution: SIMD2<Float> = .zero
    var accentColor: SIMD4<Float> = SIMD4<Float>(0.25, 0.56, 1.0, 1.0)
    var time: Float = 0
    var cursorAlong: Float = 0.5
    var hoverProgress: Float = 1
    var dragAmount: Float = 0
    var bowOffset: Float = 0
    var snapPulseAge: Float = -1
    var snapPulseOrigin: Float = 0.5
    var mode: UInt32 = 0
    var isHorizontal: UInt32 = 0
    var isClamped: UInt32 = 0
    var isSnapped: UInt32 = 0
    var showGrip: UInt32 = 1
}

/// Shared Metal device, command queue, and compiled pipeline state.
/// Warmed asynchronously so the very first seam hover never stalls on shader compilation.
@MainActor
final class MetalSeamPipeline {
    static let shared = MetalSeamPipeline()

    private(set) var device: MTLDevice?
    private(set) var commandQueue: MTLCommandQueue?
    private(set) var pipelineState: MTLRenderPipelineState?
    private var didStartWarmup = false
    private var isReady = false

    var isAvailable: Bool {
        if !didStartWarmup {
            ensureInitializedSync()
        }
        return pipelineState != nil
    }

    /// Compiles the shader off the main thread so first hover is instantaneous.
    func warmUpAsync() {
        guard !didStartWarmup else { return }
        didStartWarmup = true
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            return
        }
        self.device = device
        self.commandQueue = queue

        DispatchQueue.global(qos: .utility).async {
            do {
                let library = try device.makeLibrary(source: Self.shaderSource, options: nil)
                guard let vertexFn = library.makeFunction(name: "seamVertex"),
                      let fragmentFn = library.makeFunction(name: "seamFragment") else {
                    return
                }
                let desc = MTLRenderPipelineDescriptor()
                desc.vertexFunction = vertexFn
                desc.fragmentFunction = fragmentFn
                desc.colorAttachments[0].pixelFormat = .bgra8Unorm
                desc.colorAttachments[0].isBlendingEnabled = false
                let state = try device.makeRenderPipelineState(descriptor: desc)
                DispatchQueue.main.async {
                    self.pipelineState = state
                    self.isReady = true
                }
            } catch {
                SeamstressLog.lifecycle.error("Failed to compile Metal seam shader: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func ensureInitializedSync() {
        guard !isReady else { return }
        didStartWarmup = true
        isReady = true

        guard let device = self.device ?? MTLCreateSystemDefaultDevice(),
              let queue = self.commandQueue ?? device.makeCommandQueue() else {
            return
        }
        self.device = device
        self.commandQueue = queue

        do {
            let library = try device.makeLibrary(source: Self.shaderSource, options: nil)
            guard let vertexFn = library.makeFunction(name: "seamVertex"),
                  let fragmentFn = library.makeFunction(name: "seamFragment") else {
                return
            }
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = vertexFn
            desc.fragmentFunction = fragmentFn
            desc.colorAttachments[0].pixelFormat = .bgra8Unorm
            desc.colorAttachments[0].isBlendingEnabled = false
            self.pipelineState = try device.makeRenderPipelineState(descriptor: desc)
        } catch {
            SeamstressLog.lifecycle.error("Failed to compile Metal seam shader: \(error.localizedDescription, privacy: .public)")
        }
    }

    private nonisolated static let shaderSource: String = """
    #include <metal_stdlib>
    using namespace metal;

    struct SeamUniforms {
        float2 resolution;
        float4 accentColor;
        float time;
        float cursorAlong;
        float hoverProgress;
        float dragAmount;
        float bowOffset;
        float snapPulseAge;
        float snapPulseOrigin;
        uint mode;         // 0 = elastic, 1 = prism
        uint isHorizontal; // 0 = vertical seam, 1 = horizontal seam
        uint isClamped;
        uint isSnapped;
        uint showGrip;
    };

    struct VertexOut {
        float4 position [[position]];
        float2 uv;
    };

    vertex VertexOut seamVertex(uint vid [[vertex_id]]) {
        constexpr float2 positions[4] = {
            float2(-1.0, -1.0),
            float2( 1.0, -1.0),
            float2(-1.0,  1.0),
            float2( 1.0,  1.0)
        };
        constexpr float2 uvs[4] = {
            float2(0.0, 1.0),
            float2(1.0, 1.0),
            float2(0.0, 0.0),
            float2(1.0, 0.0)
        };
        VertexOut out;
        out.position = float4(positions[vid], 0.0, 1.0);
        out.uv = uvs[vid];
        return out;
    }

    static inline float sdRoundedBox(float2 p, float2 b, float r) {
        float2 q = abs(p) - b + r;
        return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - r;
    }

    static inline float3 cosinePalette(float t) {
        constexpr float3 a = float3(0.58, 0.62, 0.72);
        constexpr float3 b = float3(0.42, 0.38, 0.32);
        constexpr float3 d = float3(0.00, 0.28, 0.62);
        return saturate(a + b * cos(6.2831853 * (t + d)));
    }

    static inline float detentWave(float alongPt, float lengthPt, float originNorm, float pulseAge) {
        if (pulseAge < 0.0 || pulseAge > 0.45) {
            return 0.0;
        }
        float distFromOrigin = abs(alongPt - originNorm * lengthPt);
        float waveRadius = pulseAge * max(lengthPt * 2.5, 1100.0);
        float d = (distFromOrigin - waveRadius) * (1.0 / 38.0);
        float fade = 1.0 - smoothstep(0.06, 0.45, pulseAge);
        return exp(-d * d) * fade;
    }

    fragment float4 seamFragment(VertexOut in [[stage_in]], constant SeamUniforms& u [[buffer(0)]]) {
        float2 pt = in.uv * u.resolution;
        bool horiz = (u.isHorizontal == 1u);
        float lengthPt = horiz ? u.resolution.x : u.resolution.y;
        float thicknessPt = horiz ? u.resolution.y : u.resolution.x;
        float alongPt = horiz ? pt.x : pt.y;
        float acrossPt = (horiz ? pt.y : pt.x) - thicknessPt * 0.5;
        float invLen = 1.0 / max(lengthPt, 1.0);
        float alongNorm = alongPt * invLen;

        float cursorPt = u.cursorAlong * lengthPt;
        float distToCursor = abs(alongPt - cursorPt);
        float cg = distToCursor * (1.0 / 130.0);
        float cursorGlow = exp(-cg * cg);

        float endFade = smoothstep(0.0, 8.0, alongPt) * smoothstep(lengthPt, lengthPt - 8.0, alongPt);
        float maxSpan = max(cursorPt, lengthPt - cursorPt) + 22.0;
        float revealEdge = u.hoverProgress * maxSpan;
        float revealMask = (u.hoverProgress >= 0.999)
            ? 1.0
            : (1.0 - smoothstep(revealEdge - 22.0, revealEdge + 4.0, distToCursor));

        float3 activeTint = (u.isClamped == 1u) ? float3(1.0, 0.56, 0.14) : u.accentColor.rgb;
        float wave = detentWave(alongPt, lengthPt, u.snapPulseOrigin, u.snapPulseAge);
        float clampedShake = (u.isClamped == 1u) ? (sin(u.time * 58.0 + alongPt * 0.22) * 0.6) : 0.0;

        float3 rgb;
        float alpha;

        if (u.mode == 0u) {
            // ================================================================
            // MODE 0: ELASTIC — Crisp spring-physics cord with harmonic settle
            // ================================================================
            float pinMask = sin(saturate(alongNorm) * 3.14159265);
            float cb = distToCursor / max(lengthPt * 0.28, 100.0);
            float bowProfile = mix(pinMask, exp(-cb * cb) * pinMask, 0.55);

            float harmonic = sin(alongNorm * 12.5663706 + u.time * 28.0) * 0.10 * abs(u.bowOffset) * pinMask;
            float curveOffset = u.bowOffset * bowProfile + harmonic + clampedShake;
            float dist = abs(acrossPt - curveOffset);
            float dist2 = dist * dist;

            float tension = saturate(abs(u.bowOffset) * 0.18);
            float coreWidth = mix(1.45, 1.1, tension) + 0.4 * wave;
            float core = 1.0 - smoothstep(coreWidth * 0.45, coreWidth * 1.15, dist);
            float innerGlow = exp(-dist2 / mix(11.0, 22.0, tension + 0.35 * u.dragAmount))
                * (0.50 + 0.32 * tension + 0.24 * cursorGlow);
            float outerHalo = exp(-dist2 * 0.022) * (0.15 + 0.20 * tension + 0.26 * wave);
            float shadowCushion = (1.0 - smoothstep(1.4, 4.6, dist)) * 0.26;

            float3 hotColor = mix(activeTint, float3(0.95, 0.98, 1.0), 0.42 + 0.35 * tension + 0.45 * wave);
            if (u.isSnapped == 1u && u.isClamped == 0u) {
                hotColor = mix(hotColor, float3(1.0), 0.40);
            }

            float bead = 0.0;
            float beadHalo = 0.0;
            if (u.showGrip == 1u) {
                float2 bd = float2(alongPt - cursorPt, acrossPt - curveOffset);
                float bd2 = dot(bd, bd);
                if (bd2 < 144.0) {
                    float bDist = sqrt(bd2);
                    float bRad = mix(3.4, 4.6, u.dragAmount);
                    bead = 1.0 - smoothstep(bRad - 0.8, bRad + 0.8, bDist);
                    beadHalo = exp(-bd2 * 0.024) * 0.42;
                }
            }

            float mask = revealMask * endFade;
            float glowAlpha = saturate(core + innerGlow + outerHalo + bead + beadHalo + wave * 0.7) * mask;
            float totalAlpha = saturate(max(glowAlpha, shadowCushion * mask));

            float3 cordColor = mix(activeTint, hotColor, saturate(core * 0.85 + bead * 0.9 + tension * 0.35));
            cordColor += float3(1.0) * (wave * 0.45 + bead * 0.25);
            rgb = mix(float3(0.04, 0.05, 0.08), cordColor, saturate(glowAlpha / max(totalAlpha, 1e-4)));
            alpha = totalAlpha;

        } else {
            // ================================================================
            // MODE 1: PRISM — Iridescent liquid-glass ribbon & spectral caustics
            // ================================================================
            float centerAcross = acrossPt - clampedShake;
            float dist = abs(centerAcross);
            float dist2 = dist * dist;

            float flow = alongPt * 0.0042 - u.time * (0.45 + 0.55 * u.dragAmount) + u.bowOffset * 0.02;
            float3 prismColor = cosinePalette(flow + 0.14 * sin(alongPt * 0.018 + u.time * 2.1));
            prismColor = mix(prismColor, activeTint, (u.isClamped == 1u) ? 0.78 : 0.26);

            float dispersion = mix(1.2, 2.0, cursorGlow + 0.35 * u.dragAmount);
            float dr = (centerAcross - dispersion) * 0.42;
            float dg = centerAcross * 0.48;
            float db = (centerAcross + dispersion) * 0.42;
            float3 spectral = float3(exp(-dr * dr), exp(-dg * dg), exp(-db * db)) * prismColor * 1.15;

            float caustic = 0.65 + 0.35 * sin(alongPt * 0.045 - u.time * 5.2) * cos(alongPt * 0.021 + u.time * 3.1);
            float glassCore = 1.0 - smoothstep(0.55, 1.35, dist);
            float ribbonGlow = exp(-dist2 * 0.044) * (0.42 + 0.40 * cursorGlow + 0.18 * u.dragAmount) * caustic;
            float wideBloom = exp(-dist2 * 0.018) * (0.14 + 0.20 * cursorGlow + 0.30 * wave);
            float shadowCushion = (1.0 - smoothstep(1.5, 4.8, dist)) * 0.24;

            float lensMask = 0.0;
            float lensRim = 0.0;
            if (u.showGrip == 1u) {
                float pillHalfLen = clamp(lengthPt * 0.11, 12.0, 24.0);
                float dPill = sdRoundedBox(float2(alongPt - lengthPt * 0.5, centerAcross), float2(pillHalfLen, 3.4), 3.2);
                lensMask = (1.0 - smoothstep(-0.5, 0.8, dPill)) * 0.88;
                lensRim = (1.0 - smoothstep(0.15, 1.25, abs(dPill))) * (u.isSnapped == 1u ? 1.0 : 0.72);
            }

            float3 coreHighlight = mix(prismColor, float3(1.0), 0.72 + 0.28 * wave);
            float3 finalColor = spectral + coreHighlight * (glassCore * 0.92 + wave * 0.85);
            finalColor = mix(finalColor, mix(prismColor, float3(1.0), 0.55), lensMask);
            finalColor += float3(1.0) * (lensRim * 0.65 + cursorGlow * glassCore * 0.35);

            float mask = revealMask * endFade;
            float lumAlpha = saturate(glassCore + ribbonGlow + wideBloom + lensMask + lensRim * 0.8 + wave * 0.75) * mask;
            float totalAlpha = saturate(max(lumAlpha, shadowCushion * mask));

            rgb = mix(float3(0.05, 0.06, 0.10), saturate(finalColor), saturate(lumAlpha / max(totalAlpha, 1e-4)));
            alpha = totalAlpha;
        }

        alpha = saturate(alpha);
        return float4(saturate(rgb) * alpha, alpha);
    }
    """
}

/// Transparent `CAMetalLayer`-backed view that renders one animated seam strip.
/// Uses a non-blocking in-flight semaphore so Metal never queues frames ahead of vsync
/// or stalls the main thread during fast seam drags.
@MainActor
final class MetalSeamView: NSView {
    private let metalLayer = CAMetalLayer()
    private let inFlightSemaphore = DispatchSemaphore(value: 2)
    private var cachedScale: CGFloat = 2.0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = metalLayer
        configureMetalLayer()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func configureMetalLayer() {
        metalLayer.device = MetalSeamPipeline.shared.device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.isOpaque = false
        metalLayer.backgroundColor = CGColor.clear
        metalLayer.framebufferOnly = true
        metalLayer.maximumDrawableCount = 3
        metalLayer.allowsNextDrawableTimeout = false
        metalLayer.presentsWithTransaction = false
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        cachedScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        syncDrawableSize()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        syncDrawableSize()
    }

    func syncDrawableSize() {
        let scale = window?.backingScaleFactor ?? cachedScale
        cachedScale = scale
        if metalLayer.contentsScale != scale {
            metalLayer.contentsScale = scale
        }
        let width = max(1, Int((bounds.width * scale).rounded()))
        let height = max(1, Int((bounds.height * scale).rounded()))
        if Int(metalLayer.drawableSize.width) != width || Int(metalLayer.drawableSize.height) != height {
            metalLayer.drawableSize = CGSize(width: width, height: height)
        }
    }

    func render(uniforms: SeamShaderUniforms) {
        guard bounds.width > 0, bounds.height > 0,
              let pipeline = MetalSeamPipeline.shared.pipelineState,
              let queue = MetalSeamPipeline.shared.commandQueue else {
            return
        }
        // Drop this frame immediately if the GPU already has 2 frames in flight;
        // never block the main thread waiting for a drawable.
        guard inFlightSemaphore.wait(timeout: .now()) == .success else {
            return
        }

        if metalLayer.device == nil {
            metalLayer.device = MetalSeamPipeline.shared.device
        }
        syncDrawableSize()

        guard let drawable = metalLayer.nextDrawable(),
              let commandBuffer = queue.makeCommandBuffer() else {
            inFlightSemaphore.signal()
            return
        }

        let semaphore = inFlightSemaphore
        commandBuffer.addCompletedHandler { _ in
            semaphore.signal()
        }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            inFlightSemaphore.signal()
            return
        }
        encoder.setRenderPipelineState(pipeline)
        var mutableUniforms = uniforms
        encoder.setFragmentBytes(&mutableUniforms, length: MemoryLayout<SeamShaderUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
