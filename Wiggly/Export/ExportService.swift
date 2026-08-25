import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import UIKit
import ZIPFoundation

enum ExportFormat: String, CaseIterable, Identifiable, Sendable {
    case png
    case gif
    case mp4
    case movAlpha
    case pngSequence

    var id: String { rawValue }
    var title: String {
        switch self {
        case .png: "Static PNG"
        case .gif: "Animated GIF"
        case .mp4: "MP4 Video (Opaque)"
        case .movAlpha: "Transparent MOV (HEVC Alpha)"
        case .pngSequence: "PNG Sequence ZIP"
        }
    }

    var isVideo: Bool {
        self == .mp4 || self == .movAlpha
    }
}

enum VideoCodec: String, CaseIterable, Identifiable {
    case h264
    case hevc
    var id: String { rawValue }
    var title: String { self == .h264 ? "H.264" : "HEVC" }
    var avCodec: AVVideoCodecType { self == .h264 ? .h264 : .hevc }
}

struct ExportSettings {
    var format: ExportFormat = .mp4
    var width = 1080
    var height = 1080
    var framesPerSecond = 30
    var duration = 1.0
    var bitrateMbps = 35.0
    var codec: VideoCodec = .h264
    var transparentBackground = false
    var randomizeStrokePhase = false
    var filename = "Wiggly"

    var frameCount: Int {
        format == .png ? 1 : max(1, Int((duration * Double(framesPerSecond)).rounded()))
    }

    var sanitizedFilename: String {
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let cleaned = filename.components(separatedBy: invalid).joined(separator: "-")
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Wiggly" : cleaned
    }
}

enum ExportError: LocalizedError {
    case invalidDimensions
    case destinationCreation
    case gifMemoryLimit
    case writerFailure(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .invalidDimensions: "Export dimensions must be between 256 and 4096 pixels. Video dimensions must be even."
        case .destinationCreation: "Wiggly couldn’t create the export file."
        case .gifMemoryLimit: "This GIF is too large to export safely. Reduce its resolution, frame rate, or duration."
        case .writerFailure(let message): "Video export failed: \(message)"
        case .cancelled: "Export cancelled."
        }
    }
}

enum ExportService {
    static func export(
        document: WiggleDocument,
        settings: ExportSettings,
        progress: @escaping (Double) -> Void
    ) async throws -> URL {
        guard (256...4096).contains(settings.width), (256...4096).contains(settings.height) else {
            throw ExportError.invalidDimensions
        }
        if settings.format.isVideo && (settings.width.isMultiple(of: 2) == false || settings.height.isMultiple(of: 2) == false) {
            throw ExportError.invalidDimensions
        }

        switch settings.format {
        case .png:
            return try exportPNG(document: document, settings: settings)
        case .gif:
            return try await exportGIF(document: document, settings: settings, progress: progress)
        case .mp4, .movAlpha:
            return try await exportVideo(document: document, settings: settings, progress: progress)
        case .pngSequence:
            return try await exportPNGSequence(document: document, settings: settings, progress: progress)
        }
    }

    private static func temporaryURL(name: String, extension fileExtension: String) -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "\(name)-\(UUID().uuidString).\(fileExtension)")
    }

    private static func videoWorkingURL(name: String, extension fileExtension: String) throws -> URL {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            throw ExportError.destinationCreation
        }
        let folder = caches.appending(path: "WigglyExports", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appending(path: "\(name)-\(UUID().uuidString).\(fileExtension)")
    }

    private static func image(
        document: WiggleDocument,
        settings: ExportSettings,
        frame: Int,
        metalRenderer: MetalBrushExportRenderer? = nil
    ) throws -> CGImage {
        try Task.checkCancellation()
        // Export duration owns the timeline: every exported animation covers
        // exactly one normalized brush loop, regardless of canvas playback speed.
        let phase = settings.frameCount <= 1
            ? 0
            : Double(frame) / Double(settings.frameCount)
        var renderDocument = document
        if settings.format == .mp4 || settings.format == .gif {
            renderDocument.backgroundVisible = true
        }
        let exportsAlpha = settings.format == .movAlpha
            || (settings.transparentBackground && settings.format != .mp4 && settings.format != .gif)
        let outputSize = CGSize(width: settings.width, height: settings.height)
        // GIF must render directly at its final pixel size. Rendering procedural
        // grain at 2x and averaging it down erases one-pixel flecks and thin
        // animated strands before the encoder receives them. PNG can retain the
        // smoother supersampled path because it is not palette-quantized.
        let usesRasterSupersampling = settings.format == .png
            || settings.format == .pngSequence
        let isReducingSize = settings.width < document.width || settings.height < document.height
        let maximumScale = min(
            2.0,
            4096.0 / Double(settings.width),
            4096.0 / Double(settings.height)
        )
        // Lossless raster exports are supersampled before their final downsample.
        // Metal renderers receive the same larger target and therefore keep
        // CPU/GPU layers at one common scale.
        let renderScale = usesRasterSupersampling && isReducingSize
            ? max(1.0, maximumScale)
            : 1.0
        let renderSize = CGSize(
            width: (Double(settings.width) * renderScale).rounded(),
            height: (Double(settings.height) * renderScale).rounded()
        )

        let renderedImage = metalRenderer?.image(
            document: renderDocument,
            phase: phase,
            outputSize: renderSize,
            transparent: exportsAlpha,
            randomizeStrokePhase: settings.randomizeStrokePhase
        ) ?? AnimatedDrawingRenderer.image(
            document: renderDocument,
            phase: phase,
            outputSize: renderSize,
            transparent: exportsAlpha,
            randomizeStrokePhase: settings.randomizeStrokePhase
        )
        guard let renderedImage else {
            throw ExportError.destinationCreation
        }
        guard renderSize != outputSize else { return renderedImage }
        return try highQualityDownsample(renderedImage, to: outputSize)
    }

    private static func highQualityDownsample(_ image: CGImage, to size: CGSize) throws -> CGImage {
        guard let context = CGContext(
            data: nil,
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            throw ExportError.destinationCreation
        }
        context.interpolationQuality = .high
        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)
        context.draw(image, in: CGRect(origin: .zero, size: size))
        guard let downsampled = context.makeImage() else {
            throw ExportError.destinationCreation
        }
        return downsampled
    }

    private static func exportPNG(document: WiggleDocument, settings: ExportSettings) throws -> URL {
        let url = temporaryURL(name: settings.sanitizedFilename, extension: "png")
        let metalRenderer = makeMetalRendererIfNeeded(for: document)
        let image = try image(
            document: document,
            settings: settings,
            frame: 0,
            metalRenderer: metalRenderer
        )
        guard let data = UIImage(cgImage: image).pngData() else { throw ExportError.destinationCreation }
        try data.write(to: url, options: .atomic)
        return url
    }

    private static func exportGIF(
        document: WiggleDocument,
        settings: ExportSettings,
        progress: @escaping (Double) -> Void
    ) async throws -> URL {
        // GIF encoding and rendering retain working frame data while assembling
        // the animation. Reject jobs whose uncompressed frame set exceeds 512 MiB so iOS can
        // report a useful error instead of terminating the process for memory.
        let bytesPerFrame = Int64(settings.width) * Int64(settings.height) * 4
        let uncompressedBytes = bytesPerFrame.multipliedReportingOverflow(
            by: Int64(settings.frameCount)
        )
        guard !uncompressedBytes.overflow,
              uncompressedBytes.partialValue <= 512 * 1_024 * 1_024 else {
            throw ExportError.gifMemoryLimit
        }

        let url = temporaryURL(name: settings.sanitizedFilename, extension: "gif")
        var completed = false
        defer {
            if !completed { try? FileManager.default.removeItem(at: url) }
        }
        let metalRenderer = makeMetalRendererIfNeeded(for: document)
        try await GifskiGIFEncoder.encode(
            to: url,
            width: settings.width,
            height: settings.height,
            frameCount: settings.frameCount,
            framesPerSecond: settings.framesPerSecond,
            fixedColors: gifPaletteColors(for: document),
            frame: { frame in
                try autoreleasepool {
                    try image(
                        document: document,
                        settings: settings,
                        frame: frame,
                        metalRenderer: metalRenderer
                    )
                }
            },
            progress: progress
        )
        completed = true
        return url
    }

    private static func gifPaletteColors(for document: WiggleDocument) -> [CodableColor] {
        var colors: [CodableColor] = [document.background]
        var seen = Set<CodableColor>(colors)
        for layer in document.layers {
            for stroke in layer.strokes {
                let brush = stroke.brush
                // Only reserve colors explicitly present in the document.
                // The resolved* accessors provide UI defaults (pink, white,
                // cyan, etc.) for unset fields; reserving those defaults can
                // consume most of GIF's palette without representing pixels
                // in the artwork.
                let candidates = [brush.color]
                    + [brush.secondaryColor, brush.tertiaryColor,
                       brush.quaternaryColor, brush.quinaryColor]
                    .compactMap { $0 }
                for color in candidates where seen.insert(color).inserted {
                    colors.append(color)
                    if colors.count == 64 { return colors }
                }
            }
        }
        return colors
    }

    private static func exportPNGSequence(
        document: WiggleDocument,
        settings: ExportSettings,
        progress: @escaping (Double) -> Void
    ) async throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "\(settings.sanitizedFilename)-frames-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let digits = max(4, String(settings.frameCount).count)
        let metalRenderer = makeMetalRendererIfNeeded(for: document)
        for frame in 0..<settings.frameCount {
            try Task.checkCancellation()
            let cgImage = try image(
                document: document,
                settings: settings,
                frame: frame,
                metalRenderer: metalRenderer
            )
            guard let data = UIImage(cgImage: cgImage).pngData() else { throw ExportError.destinationCreation }
            let name = String(format: "frame_%0*d.png", digits, frame)
            try data.write(to: folder.appending(path: name), options: .atomic)
            progress(Double(frame + 1) / Double(settings.frameCount))
            await Task.yield()
        }

        let zipURL = temporaryURL(name: "\(settings.sanitizedFilename)-PNG-Sequence", extension: "zip")
        try FileManager.default.zipItem(at: folder, to: zipURL, shouldKeepParent: false, compressionMethod: .deflate)
        return zipURL
    }

    static func exportPNGFrames(
        document: WiggleDocument,
        settings: ExportSettings,
        progress: @escaping (Double) -> Void
    ) async throws -> [URL] {
        guard (256...4096).contains(settings.width),
              (256...4096).contains(settings.height) else {
            throw ExportError.invalidDimensions
        }

        let folder = FileManager.default.temporaryDirectory
            .appending(path: "\(settings.sanitizedFilename)-frames-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var urls: [URL] = []
        urls.reserveCapacity(settings.frameCount)

        do {
            let digits = max(4, String(settings.frameCount).count)
            let metalRenderer = makeMetalRendererIfNeeded(for: document)
            for frame in 0..<settings.frameCount {
                try Task.checkCancellation()
                let cgImage = try image(
                    document: document,
                    settings: settings,
                    frame: frame,
                    metalRenderer: metalRenderer
                )
                guard let data = UIImage(cgImage: cgImage).pngData() else {
                    throw ExportError.destinationCreation
                }
                let url = folder.appending(path: String(format: "frame_%0*d.png", digits, frame))
                try data.write(to: url, options: .atomic)
                urls.append(url)
                progress(Double(frame + 1) / Double(settings.frameCount))
                await Task.yield()
            }
            return urls
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    private static func exportVideo(
        document: WiggleDocument,
        settings: ExportSettings,
        progress: @escaping (Double) -> Void
    ) async throws -> URL {
        let exportsAlpha = settings.format == .movAlpha
        let writerURL = try videoWorkingURL(
            name: exportsAlpha ? settings.sanitizedFilename : "\(settings.sanitizedFilename)-source",
            extension: "mov"
        )
        let finalURL = exportsAlpha
            ? writerURL
            : try videoWorkingURL(name: settings.sanitizedFilename, extension: "mp4")
        if !exportsAlpha {
            try? FileManager.default.removeItem(at: finalURL)
        }
        defer {
            if !exportsAlpha { try? FileManager.default.removeItem(at: writerURL) }
        }
        let writer = try AVAssetWriter(
            outputURL: writerURL,
            fileType: .mov
        )
        writer.shouldOptimizeForNetworkUse = true
        let outputSettings = try videoOutputSettings(settings: settings, exportsAlpha: exportsAlpha)
        guard writer.canApply(outputSettings: outputSettings, forMediaType: .video) else {
            throw ExportError.writerFailure("This device can’t encode the requested H.264 dimensions.")
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: outputSettings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: settings.width,
                kCVPixelBufferHeightKey as String: settings.height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ]
        )
        guard writer.canAdd(input) else { throw ExportError.writerFailure("Unsupported export settings.") }
        writer.add(input)
        guard writer.startWriting() else { throw ExportError.writerFailure(writer.error?.localizedDescription ?? "Unknown error") }
        writer.startSession(atSourceTime: .zero)
        let metalRenderer = makeMetalRendererIfNeeded(for: document)

        for frame in 0..<settings.frameCount {
            try Task.checkCancellation()
            while !input.isReadyForMoreMediaData {
                try Task.checkCancellation()
                try await Task.sleep(for: .milliseconds(4))
            }
            guard let pool = adaptor.pixelBufferPool else { throw ExportError.destinationCreation }
            var optionalBuffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &optionalBuffer)
            guard let buffer = optionalBuffer else { throw ExportError.destinationCreation }
            try draw(
                try image(
                    document: document,
                    settings: settings,
                    frame: frame,
                    metalRenderer: metalRenderer
                ),
                into: buffer,
                document: document,
                preservesAlpha: exportsAlpha
            )
            let time = CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(settings.framesPerSecond))
            guard adaptor.append(buffer, withPresentationTime: time) else {
                throw ExportError.writerFailure(writer.error?.localizedDescription ?? "Couldn’t append a frame.")
            }
            progress(Double(frame + 1) / Double(settings.frameCount))
            await Task.yield()
        }

        input.markAsFinished()
        await withCheckedContinuation { continuation in
            writer.finishWriting { continuation.resume() }
        }
        guard writer.status == .completed else {
            throw ExportError.writerFailure(writer.error?.localizedDescription ?? "Unknown error")
        }
        try validateVideoFile(at: writerURL)

        if exportsAlpha { return writerURL }
        let sourceAsset = AVURLAsset(url: writerURL)
        guard let exportSession = AVAssetExportSession(
            asset: sourceAsset,
            presetName: AVAssetExportPresetPassthrough
        ), exportSession.supportedFileTypes.contains(.mp4) else {
            throw ExportError.writerFailure("Apple’s MP4 export preset is unavailable on this device.")
        }
        exportSession.shouldOptimizeForNetworkUse = true
        do {
            try await exportSession.export(to: finalURL, as: .mp4)
        } catch {
            throw ExportError.writerFailure("MP4 packaging failed: \(error.localizedDescription)")
        }
        try validateVideoFile(at: finalURL)
        return finalURL
    }

    private static func makeMetalRendererIfNeeded(
        for document: WiggleDocument
    ) -> MetalBrushExportRenderer? {
        guard MetalBrushExportRenderer.isNeeded(for: document) else { return nil }
        return MetalBrushExportRenderer()
    }

    private static func videoOutputSettings(
        settings: ExportSettings,
        exportsAlpha: Bool
    ) throws -> [String: Any] {
        if exportsAlpha {
            return [
                AVVideoCodecKey: AVVideoCodecType.hevcWithAlpha,
                AVVideoWidthKey: settings.width,
                AVVideoHeightKey: settings.height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: Int(settings.bitrateMbps * 1_000_000),
                    AVVideoExpectedSourceFrameRateKey: settings.framesPerSecond
                ]
            ]
        }

        let uses4KPreset = settings.width > 1920 || settings.height > 1920
        let preset: AVOutputSettingsPreset = uses4KPreset ? .preset3840x2160 : .preset1920x1080
        guard let assistant = AVOutputSettingsAssistant(preset: preset),
              var output = assistant.videoSettings else {
            throw ExportError.writerFailure("Apple’s H.264 output preset is unavailable.")
        }

        output[AVVideoWidthKey] = settings.width
        output[AVVideoHeightKey] = settings.height
        var compression = output[AVVideoCompressionPropertiesKey] as? [String: Any] ?? [:]
        let presetWidth = uses4KPreset ? 3840.0 : 1920.0
        let presetHeight = uses4KPreset ? 2160.0 : 1080.0
        let presetBitrate = (compression[AVVideoAverageBitRateKey] as? NSNumber)?.doubleValue
            ?? (uses4KPreset ? 42_000_000 : 10_500_000)
        let pixelRatio = Double(settings.width * settings.height) / (presetWidth * presetHeight)
        let frameRateRatio = Double(settings.framesPerSecond) / 30
        let recommendedBitrate = presetBitrate * pixelRatio * frameRateRatio
        compression[AVVideoAverageBitRateKey] = Int(min(
            settings.bitrateMbps * 1_000_000,
            max(8_000_000, recommendedBitrate * 1.2)
        ))
        compression[AVVideoExpectedSourceFrameRateKey] = settings.framesPerSecond
        compression[AVVideoMaxKeyFrameIntervalKey] = settings.framesPerSecond
        output[AVVideoCompressionPropertiesKey] = compression
        return output
    }

    private static func validateVideoFile(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path),
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let byteCount = attributes[.size] as? NSNumber,
              byteCount.int64Value > 1_024 else {
            throw ExportError.writerFailure("The encoder did not create a complete video file.")
        }
    }

    private static func draw(
        _ image: CGImage,
        into pixelBuffer: CVPixelBuffer,
        document: WiggleDocument,
        preservesAlpha: Bool
    ) throws {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { throw ExportError.destinationCreation }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard let context = CGContext(
            data: base,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { throw ExportError.destinationCreation }
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        context.clear(bounds)
        if !preservesAlpha {
            context.setFillColor(UIColor(
                red: document.background.red,
                green: document.background.green,
                blue: document.background.blue,
                alpha: 1
            ).cgColor)
            context.fill(bounds)
        }
        context.draw(image, in: bounds)
    }
}
