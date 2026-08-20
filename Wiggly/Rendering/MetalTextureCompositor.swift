import MetalKit
import simd

/// Uploads cached Core Graphics layers once, then composites them directly in
/// the same Metal render pass as procedural strokes. This replaces the
/// full-screen Core Image chain that previously ran on every animated frame.
final class MetalTextureCompositor {
    struct ViewTransform {
        var canvasSize: SIMD2<Float>
        var viewSize: SIMD2<Float>
        var fittedSize: SIMD2<Float>
        var centerOffset: SIMD2<Float>
        var zoom: Float
        var rotation: Float
        var phase: Float = 0
        var padding: Float = 0
    }

    private struct CachedTexture {
        var image: CGImage
        var texture: MTLTexture
    }

    private let loader: MTKTextureLoader
    private let pipeline: MTLRenderPipelineState
    private var textures: [ObjectIdentifier: CachedTexture] = [:]

    init?(device: MTLDevice, pixelFormat: MTLPixelFormat) {
        loader = MTKTextureLoader(device: device)
        do {
            let library = try device.makeLibrary(source: Self.shader, options: nil)
            guard let vertex = library.makeFunction(name: "canvasTextureVertex"),
                  let fragment = library.makeFunction(name: "canvasTextureFragment") else { return nil }
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.label = "Canvas Texture Compositor"
            descriptor.vertexFunction = vertex
            descriptor.fragmentFunction = fragment
            descriptor.colorAttachments[0].pixelFormat = pixelFormat
            let attachment = descriptor.colorAttachments[0]!
            attachment.isBlendingEnabled = true
            // CGImage textures are premultiplied. Multiplying RGB by alpha a
            // second time produces dark fringes around translucent layers.
            attachment.sourceRGBBlendFactor = .one
            attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
            attachment.sourceAlphaBlendFactor = .one
            attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            assertionFailure("Unable to create canvas texture compositor: \(error)")
            return nil
        }
    }

    func prepare(images: [CGImage]) {
        let active = Set(images.map(ObjectIdentifier.init))
        textures = textures.filter { active.contains($0.key) }
        for image in images where textures[ObjectIdentifier(image)] == nil {
            let options: [MTKTextureLoader.Option: Any] = [
                .origin: MTKTextureLoader.Origin.topLeft,
                .SRGB: false,
                .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue),
                .textureStorageMode: NSNumber(value: MTLStorageMode.private.rawValue)
            ]
            if let texture = try? loader.newTexture(cgImage: image, options: options) {
                texture.label = "Cached CPU Canvas Layer"
                textures[ObjectIdentifier(image)] = CachedTexture(image: image, texture: texture)
            }
        }
    }

    func encode(
        image: CGImage,
        encoder: MTLRenderCommandEncoder,
        transform: ViewTransform
    ) {
        guard let texture = textures[ObjectIdentifier(image)]?.texture else { return }
        encoder.pushDebugGroup("Cached Canvas Layer")
        encoder.setRenderPipelineState(pipeline)
        var uniforms = transform
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<ViewTransform>.stride, index: 0)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        encoder.popDebugGroup()
    }

    private static let shader = #"""
    #include <metal_stdlib>
    using namespace metal;

    struct Uniforms {
        float2 canvasSize;
        float2 viewSize;
        float2 fittedSize;
        float2 centerOffset;
        float zoom;
        float rotation;
        float phase;
        float padding;
    };

    struct VertexOut {
        float4 position [[position]];
        float2 uv;
    };

    float2 canvasToClip(float2 point, constant Uniforms &u) {
        float2 p = (point / u.canvasSize - 0.5) * u.fittedSize * u.zoom;
        float c = cos(u.rotation);
        float s = sin(u.rotation);
        p = float2(p.x * c - p.y * s, p.x * s + p.y * c);
        p += u.viewSize * 0.5 + u.centerOffset;
        return float2(p.x / u.viewSize.x * 2.0 - 1.0, 1.0 - p.y / u.viewSize.y * 2.0);
    }

    vertex VertexOut canvasTextureVertex(uint id [[vertex_id]], constant Uniforms &u [[buffer(0)]]) {
        const float2 positions[6] = {
            float2(0.0, 0.0),
            float2(1.0, 0.0),
            float2(0.0, 1.0),
            float2(0.0, 1.0),
            float2(1.0, 0.0),
            float2(1.0, 1.0)
        };
        VertexOut out;
        float2 normalized = positions[id];
        out.position = float4(canvasToClip(normalized * u.canvasSize, u), 0.0, 1.0);
        out.uv = normalized;
        return out;
    }

    fragment float4 canvasTextureFragment(
        VertexOut input [[stage_in]],
        texture2d<float> texture [[texture(0)]]) {
        constexpr sampler textureSampler(
            coord::normalized,
            address::clamp_to_edge,
            filter::linear);
        return texture.sample(textureSampler, input.uv);
    }
    """#
}
