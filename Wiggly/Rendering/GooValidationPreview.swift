#if DEBUG
import SwiftUI

private extension StrokeSample {
    static func validation(_ point: CGPoint, pressure: Double = 0.5) -> StrokeSample {
        StrokeSample(
            x: point.x,
            y: point.y,
            pressure: pressure,
            tilt: 0,
            azimuth: 0,
            timestamp: 0
        )
    }
}

private extension WiggleDocument {
    static var gooStageOneValidation: WiggleDocument {
        var document = WiggleDocument.blank(name: "Goo Stage 1", size: CGSize(width: 1200, height: 1200))
        var thin = BrushSettings.preset(.goo)
        thin.size = 12
        thin.color = CodableColor(red: 0.05, green: 0.12, blue: 0.18)
        var thick = BrushSettings.preset(.goo)
        thick.size = 96
        thick.color = CodableColor(red: 0.12, green: 0.42, blue: 0.95)

        let straight = AnimatedStroke(samples: [
            .validation(CGPoint(x: 120, y: 190)),
            .validation(CGPoint(x: 1080, y: 190))
        ], brush: thin)
        let tightCurve = AnimatedStroke(samples: [
            .validation(CGPoint(x: 160, y: 520), pressure: 0.3),
            .validation(CGPoint(x: 340, y: 350), pressure: 0.5),
            .validation(CGPoint(x: 580, y: 520), pressure: 0.9),
            .validation(CGPoint(x: 820, y: 700), pressure: 0.5),
            .validation(CGPoint(x: 1040, y: 500), pressure: 0.7)
        ], brush: thick)
        let loop = AnimatedStroke(samples: [
            .validation(CGPoint(x: 240, y: 910)),
            .validation(CGPoint(x: 420, y: 790)),
            .validation(CGPoint(x: 650, y: 890)),
            .validation(CGPoint(x: 500, y: 1060)),
            .validation(CGPoint(x: 300, y: 1020)),
            .validation(CGPoint(x: 240, y: 910))
        ], brush: thick)
        document.layers[0].strokes = [straight, tightCurve, loop]
        return document
    }
}

#Preview("Unified Goo — Stage 1") {
    EditorView(
        document: .gooStageOneValidation,
        library: ProjectLibrary(),
        showLayersInitially: false
    )
}
#endif
