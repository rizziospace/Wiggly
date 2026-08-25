import CoreGraphics
import Foundation
import Gifski

enum GifskiGIFEncoder {
    enum EncoderError: LocalizedError {
        case initialization
        case invalidFrame
        case operation(String, Int32)

        var errorDescription: String? {
            switch self {
            case .initialization:
                "The high-quality GIF encoder could not start."
            case .invalidFrame:
                "A rendered GIF frame had invalid dimensions."
            case .operation(let operation, let code):
                "GIF encoding failed during \(operation) (Gifski error \(code))."
            }
        }
    }

    static func encode(
        to url: URL,
        width: Int,
        height: Int,
        frameCount: Int,
        framesPerSecond: Int,
        fixedColors: [CodableColor] = [],
        frame: (Int) throws -> CGImage,
        progress: @escaping (Double) -> Void
    ) async throws {
        guard width > 0, height > 0, frameCount > 0, framesPerSecond > 0 else {
            throw EncoderError.invalidFrame
        }

        var settings = GifskiSettings(
            width: UInt32(width),
            height: UInt32(height),
            quality: 100,
            fast: false,
            repeat: 0
        )
        guard let encoder = gifski_new(&settings) else {
            throw EncoderError.initialization
        }

        var isFinished = false
        defer {
            // gifski_finish also releases the encoder. Always call it exactly
            // once, including cancellation and failed-frame paths.
            if !isFinished { _ = gifski_finish(encoder) }
        }

        // Spend more encoder work on the shared animated palette. GIF still
        // has a hard 256-color limit, but this substantially reduces visible
        // banding and color drift in gradients and textured strokes.
        try check(
            gifski_set_extra_effort(encoder, true),
            operation: "configuring palette quality"
        )
        // Keep most of the 256-entry palette available for antialiasing,
        // gradients, and textured brushes. Reserving half the palette for
        // source colors makes detailed strokes look flat and faded.
        for color in fixedColors.prefix(64) {
            try check(
                gifski_add_fixed_color(
                    encoder,
                    UInt8(clamping: Int((color.red * 255).rounded())),
                    UInt8(clamping: Int((color.green * 255).rounded())),
                    UInt8(clamping: Int((color.blue * 255).rounded()))
                ),
                operation: "preserving source colors"
            )
        }

        try check(
            url.path.withCString { gifski_set_file_output(encoder, $0) },
            operation: "opening the destination"
        )
        do {
            for index in 0..<frameCount {
                try Task.checkCancellation()
                let image = try frame(index)
                let pixels = try straightRGBA(
                    from: image,
                    width: width,
                    height: height
                )
                let timestamp = Double(index) / Double(framesPerSecond)
                let result = pixels.withUnsafeBytes { bytes in
                    gifski_add_frame_rgba(
                        encoder,
                        UInt32(index),
                        UInt32(width),
                        UInt32(height),
                        bytes.bindMemory(to: UInt8.self).baseAddress,
                        timestamp
                    )
                }
                try check(result, operation: "adding frame \(index + 1)")
                progress(Double(index + 1) / Double(frameCount))
                await Task.yield()
            }
        } catch {
            let result = gifski_finish(encoder)
            isFinished = true
            if Task.isCancelled { throw CancellationError() }
            if rawCode(result) != 0 {
                throw EncoderError.operation("finishing after an error", rawCode(result))
            }
            throw error
        }

        let result = gifski_finish(encoder)
        isFinished = true
        try check(result, operation: "finalizing the file")
    }

    private static func check(
        _ result: GifskiError,
        operation: String
    ) throws {
        let code = rawCode(result)
        guard code == 0 else { throw EncoderError.operation(operation, code) }
    }

    private static func rawCode(_ result: GifskiError) -> Int32 {
        Int32(result.rawValue)
    }

    /// Gifski accepts top-to-bottom, unassociated RGBA. Request an explicit
    /// big-endian 32-bit RGBA bitmap here; the previous little-endian layout
    /// was then read as RGBA, which could swap red/blue channels in GIFs.
    /// Quartz produces premultiplied RGBA, so unpremultiply before handing the
    /// copied buffer to the encoder. This preserves antialiased edges instead
    /// of darkening them.
    private static func straightRGBA(
        from image: CGImage,
        width: Int,
        height: Int
    ) throws -> [UInt8] {
        guard image.width == width, image.height == height else {
            throw EncoderError.invalidFrame
        }
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        let madeContext = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(
                data: bytes.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                    | CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .high
            context.setBlendMode(.copy)
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard madeContext else { throw EncoderError.invalidFrame }

        for offset in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Int(pixels[offset + 3])
            if alpha == 0 {
                pixels[offset] = 0
                pixels[offset + 1] = 0
                pixels[offset + 2] = 0
            } else if alpha < 255 {
                pixels[offset] = UInt8(clamping: Int(pixels[offset]) * 255 / alpha)
                pixels[offset + 1] = UInt8(clamping: Int(pixels[offset + 1]) * 255 / alpha)
                pixels[offset + 2] = UInt8(clamping: Int(pixels[offset + 2]) * 255 / alpha)
            }
        }
        return pixels
    }
}
