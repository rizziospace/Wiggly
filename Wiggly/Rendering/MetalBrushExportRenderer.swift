import CoreGraphics
import MetalKit
import simd
import UIKit

/// Renders every GPU brush with the exact same Metal pipelines used by the
/// canvas. CPU layers are composited between them to preserve layer order.
final class MetalBrushExportRenderer {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let compositor: MetalTextureCompositor
    private let dashedRenderer: MetalDashedRenderer
    private let dryOutlineRenderer: MetalDryOutlineRenderer
    private let starRenderer: MetalStarRenderer
    private let particleRenderer: MetalParticleRenderer
    private let particleCloudRenderer: MetalParticleCloudRenderer
    private let scribblesRenderer: MetalScribblesRenderer
    private let proceduralBrushRenderer: MetalProceduralBrushRenderer
    private let checkerRenderer: MetalCheckerRenderer
    private let pixelFormat: MTLPixelFormat = .bgra8Unorm

    static func isNeeded(for document: WiggleDocument) -> Bool {
        document.layers.contains { layer in
            layer.strokes.contains(where: \.usesGPUAnimatedRenderer)
        }
    }

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue(),
              let compositor = MetalTextureCompositor(device: device, pixelFormat: pixelFormat),
              let dashedRenderer = MetalDashedRenderer(device: device, pixelFormat: pixelFormat),
              let dryOutlineRenderer = MetalDryOutlineRenderer(device: device, pixelFormat: pixelFormat),
              let starRenderer = MetalStarRenderer(device: device, pixelFormat: pixelFormat),
              let particleRenderer = MetalParticleRenderer(device: device, pixelFormat: pixelFormat),
              let particleCloudRenderer = MetalParticleCloudRenderer(device: device, pixelFormat: pixelFormat),
              let scribblesRenderer = MetalScribblesRenderer(device: device, pixelFormat: pixelFormat),
              let proceduralBrushRenderer = MetalProceduralBrushRenderer(device: device, pixelFormat: pixelFormat),
              let checkerRenderer = MetalCheckerRenderer(device: device, pixelFormat: pixelFormat) else {
            return nil
        }
        self.device = device
        self.commandQueue = commandQueue
        self.compositor = compositor
        self.dashedRenderer = dashedRenderer
        self.dryOutlineRenderer = dryOutlineRenderer
        self.starRenderer = starRenderer
        self.particleRenderer = particleRenderer
        self.particleCloudRenderer = particleCloudRenderer
        self.scribblesRenderer = scribblesRenderer
        self.proceduralBrushRenderer = proceduralBrushRenderer
        self.checkerRenderer = checkerRenderer
    }

    func image(
        document: WiggleDocument,
        phase: Double,
        outputSize: CGSize,
        transparent: Bool,
        randomizeStrokePhase: Bool
    ) -> CGImage? {
        // If an export continues while the app is being backgrounded, fall
        // back to the CPU renderer instead of submitting forbidden GPU work.
        guard UIApplication.shared.applicationState == .active else { return nil }
        let width = Int(outputSize.width.rounded())
        let height = Int(outputSize.height.rounded())
        guard width > 0, height > 0 else { return nil }

        dashedRenderer.setStrokePhaseRandomized(randomizeStrokePhase)
        dryOutlineRenderer.setStrokePhaseRandomized(randomizeStrokePhase)
        starRenderer.setStrokePhaseRandomized(randomizeStrokePhase)
        particleRenderer.setStrokePhaseRandomized(randomizeStrokePhase)
        particleCloudRenderer.setStrokePhaseRandomized(randomizeStrokePhase)
        scribblesRenderer.setStrokePhaseRandomized(randomizeStrokePhase)
        proceduralBrushRenderer.setStrokePhaseRandomized(randomizeStrokePhase)
        checkerRenderer.setStrokePhaseRandomized(randomizeStrokePhase)
        dashedRenderer.update(document: document)
        dryOutlineRenderer.update(document: document)
        starRenderer.update(document: document)
        particleRenderer.update(document: document)
        particleCloudRenderer.update(document: document)
        scribblesRenderer.update(document: document)
        proceduralBrushRenderer.update(document: document)
        checkerRenderer.update(document: document)

        var cpuImages: [UUID: CGImage] = [:]
        for layer in document.layers where document.isLayerEffectivelyVisible(layer) {
            var cpuLayer = layer
            cpuLayer.strokes.removeAll {
                $0.usesGPUAnimatedRenderer
            }
            let hasCPUContent = !cpuLayer.strokes.isEmpty
                || !(cpuLayer.fills ?? []).isEmpty
                || cpuLayer.imageData != nil
            guard hasCPUContent else { continue }
            var layerDocument = document
            layerDocument.backgroundVisible = false
            layerDocument.layers = [cpuLayer]
            if let image = AnimatedDrawingRenderer.image(
                document: layerDocument,
                phase: phase,
                outputSize: outputSize,
                transparent: true,
                randomizeStrokePhase: randomizeStrokePhase
            ) {
                cpuImages[layer.id] = image
            }
        }
        compositor.prepare(images: Array(cpuImages.values))

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor),
              let commandBuffer = commandQueue.makeCommandBuffer() else { return nil }
        texture.label = "Exported GPU Brush Frame"

        let clear: MTLClearColor
        if document.resolvedBackgroundVisible && !transparent {
            clear = MTLClearColor(
                red: document.background.red,
                green: document.background.green,
                blue: document.background.blue,
                alpha: 1
            )
        } else {
            clear = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = clear
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        encoder.label = "GPU Brush Export"

        let canvasSize = SIMD2(Float(document.width), Float(document.height))
        let viewSize = SIMD2(Float(width), Float(height))
        let waveAmount: Float = 1
        let compositorTransform = MetalTextureCompositor.ViewTransform(
            canvasSize: canvasSize,
            viewSize: viewSize,
            fittedSize: viewSize,
            centerOffset: .zero,
            zoom: 1,
            rotation: 0,
            phase: Float(phase)
        )
        let dashedTransform = MetalDashedRenderer.ViewTransform(
            canvasSize: canvasSize,
            viewSize: viewSize,
            fittedSize: viewSize,
            centerOffset: .zero,
            zoom: 1,
            rotation: 0,
            phase: Float(phase),
            waveAmount: waveAmount
        )
        let grainTransform = MetalDryOutlineRenderer.ViewTransform(
            canvasSize: canvasSize,
            viewSize: viewSize,
            fittedSize: viewSize,
            centerOffset: .zero,
            zoom: 1,
            rotation: 0,
            phase: Float(phase)
        )
        let starTransform = MetalStarRenderer.ViewTransform(
            canvasSize: canvasSize,
            viewSize: viewSize,
            fittedSize: viewSize,
            centerOffset: .zero,
            zoom: 1,
            rotation: 0,
            phase: Float(phase),
            waveAmount: waveAmount
        )
        let particleTransform = MetalParticleRenderer.ViewTransform(
            canvasSize: canvasSize,
            viewSize: viewSize,
            fittedSize: viewSize,
            centerOffset: .zero,
            zoom: 1,
            rotation: 0,
            phase: Float(phase),
            waveAmount: waveAmount
        )
        let particleCloudTransform = MetalParticleCloudRenderer.ViewTransform(
            canvasSize: canvasSize,
            viewSize: viewSize,
            fittedSize: viewSize,
            centerOffset: .zero,
            zoom: 1,
            rotation: 0,
            phase: Float(phase),
            waveAmount: waveAmount
        )
        let scribblesTransform = MetalScribblesRenderer.ViewTransform(
            canvasSize: canvasSize,
            viewSize: viewSize,
            fittedSize: viewSize,
            centerOffset: .zero,
            zoom: 1,
            rotation: 0,
            phase: Float(phase),
            waveAmount: waveAmount
        )
        let proceduralTransform = MetalProceduralBrushRenderer.ViewTransform(
            canvasSize: canvasSize,
            viewSize: viewSize,
            fittedSize: viewSize,
            centerOffset: .zero,
            zoom: 1,
            rotation: 0,
            phase: Float(phase),
            waveAmount: waveAmount
        )
        let checkerTransform = MetalCheckerRenderer.ViewTransform(
            canvasSize: canvasSize,
            viewSize: viewSize,
            fittedSize: viewSize,
            centerOffset: .zero,
            zoom: 1,
            rotation: 0,
            phase: Float(phase),
            waveAmount: waveAmount
        )

        for layer in document.layers where document.isLayerEffectivelyVisible(layer) {
            if let image = cpuImages[layer.id] {
                compositor.encode(image: image, encoder: encoder, transform: compositorTransform)
            }
            dashedRenderer.encode(encoder: encoder, transform: dashedTransform, layerID: layer.id)
            dryOutlineRenderer.encode(encoder: encoder, transform: grainTransform, layerID: layer.id)
            starRenderer.encode(encoder: encoder, transform: starTransform, layerID: layer.id)
            particleRenderer.encode(encoder: encoder, transform: particleTransform, layerID: layer.id)
            particleCloudRenderer.encode(encoder: encoder, transform: particleCloudTransform, layerID: layer.id)
            scribblesRenderer.encode(encoder: encoder, transform: scribblesTransform, layerID: layer.id)
            proceduralBrushRenderer.encode(encoder: encoder, transform: proceduralTransform, layerID: layer.id)
            checkerRenderer.encode(encoder: encoder, transform: checkerTransform, layerID: layer.id)
        }
        encoder.endEncoding()
        guard UIApplication.shared.applicationState == .active else { return nil }
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        guard commandBuffer.status == .completed else { return nil }

        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        texture.getBytes(
            &pixels,
            bytesPerRow: bytesPerRow,
            from: MTLRegionMake2D(0, 0, width, height),
            mipmapLevel: 0
        )
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo.byteOrder32Little.union(
                CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
            ),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }
}
