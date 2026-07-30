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
    var duration = 3.0
    var bitrateMbps = 12.0
    var codec: VideoCodec = .h264
    var transparentBackground = false
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
    case writerFailure(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .invalidDimensions: "Export dimensions must be between 256 and 4096 pixels. Video dimensions must be even."
        case .destinationCreation: "Wiggly couldn’t create the export file."
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

    private static func image(document: WiggleDocument, settings: ExportSettings, frame: Int) throws -> CGImage {
        try Task.checkCancellation()
        let phase = Double(frame) / Double(settings.frameCount)
        var renderDocument = document
        if settings.format == .mp4 {
            renderDocument.backgroundVisible = true
        }
        let exportsAlpha = settings.format == .movAlpha
            || (settings.transparentBackground && settings.format != .mp4)
        guard let image = AnimatedDrawingRenderer.image(
            document: renderDocument,
            phase: phase,
            outputSize: CGSize(width: settings.width, height: settings.height),
            transparent: exportsAlpha
        ) else {
            throw ExportError.destinationCreation
        }
        return image
    }

    private static func exportPNG(document: WiggleDocument, settings: ExportSettings) throws -> URL {
        let url = temporaryURL(name: settings.sanitizedFilename, extension: "png")
        let image = try image(document: document, settings: settings, frame: 0)
        guard let data = UIImage(cgImage: image).pngData() else { throw ExportError.destinationCreation }
        try data.write(to: url, options: .atomic)
        return url
    }

    private static func exportGIF(
        document: WiggleDocument,
        settings: ExportSettings,
        progress: @escaping (Double) -> Void
    ) async throws -> URL {
        let url = temporaryURL(name: settings.sanitizedFilename, extension: "gif")
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.gif.identifier as CFString,
            settings.frameCount,
            nil
        ) else { throw ExportError.destinationCreation }

        let fileProperties: CFDictionary = [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]
        ] as CFDictionary
        CGImageDestinationSetProperties(destination, fileProperties)
        let frameProperties: CFDictionary = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFDelayTime: 1.0 / Double(settings.framesPerSecond)
            ]
        ] as CFDictionary

        for frame in 0..<settings.frameCount {
            try Task.checkCancellation()
            CGImageDestinationAddImage(destination, try image(document: document, settings: settings, frame: frame), frameProperties)
            progress(Double(frame + 1) / Double(settings.frameCount))
            await Task.yield()
        }
        guard CGImageDestinationFinalize(destination) else { throw ExportError.destinationCreation }
        return url
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
        for frame in 0..<settings.frameCount {
            try Task.checkCancellation()
            let cgImage = try image(document: document, settings: settings, frame: frame)
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

    private static func exportVideo(
        document: WiggleDocument,
        settings: ExportSettings,
        progress: @escaping (Double) -> Void
    ) async throws -> URL {
        let exportsAlpha = settings.format == .movAlpha
        let url = temporaryURL(
            name: settings.sanitizedFilename,
            extension: exportsAlpha ? "mov" : "mp4"
        )
        let writer = try AVAssetWriter(
            outputURL: url,
            fileType: exportsAlpha ? .mov : .mp4
        )
        let outputSettings: [String: Any] = [
            AVVideoCodecKey: exportsAlpha ? AVVideoCodecType.hevcWithAlpha : settings.codec.avCodec,
            AVVideoWidthKey: settings.width,
            AVVideoHeightKey: settings.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: Int(settings.bitrateMbps * 1_000_000),
                AVVideoExpectedSourceFrameRateKey: settings.framesPerSecond
            ]
        ]
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
                try image(document: document, settings: settings, frame: frame),
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
        return url
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
