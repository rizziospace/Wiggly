# Creating Animated Brushes

Wiggly stores editable strokes as `StrokeSample` values containing canvas position, timestamp, Apple Pencil pressure, tilt, and azimuth. A stroke embeds its `BrushSettings`, so future preset edits never change existing artwork.

## Make a brush in the app

1. Open **Brush Studio** from the canvas toolbar.
2. Start from Wiggle Line, Jitter Pencil, Pulse Marker, or Scatter Dots.
3. Tune size, opacity, smoothing, spacing, motion, frequency, loop cycles, pressure, tilt, and seed.
4. Watch the live three-second loop, name the preset, and choose **Save Preset**.
5. Choose **Use Brush** to draw with it.

## Add a brush engine

1. Add a case to `BrushKind` with a title and SF Symbol.
2. Create a type conforming to `AnimatedBrushKernel`.
3. Implement `draw(stroke:phase:in:)`. `phase` is normalized to `[0, 1)`. Read only the stroke and phase; never use wall-clock time or unseeded randomness.
4. Register the kernel in `BrushKernelRegistry.kernels`.
5. Add tuned defaults in `BrushSettings.preset(_:)` and expose any new controls in Brush Studio.

## Seamless-loop rule

A rendered animation contains frames `0 ..< frameCount`, with phase calculated as `frame / frameCount`. Do not export a phase of exactly `1`, because it duplicates frame zero. Use integer temporal cycles such as:

```swift
let angle = phase * Double.pi * 2 * Double(brush.loopCycles)
let offset = sin(angle) * brush.motionAmount
```

For organic-looking deterministic motion, derive values from `brush.seed` and sample index, then rotate or interpolate those values using the loop phase. The same document, seed, and phase must always produce the same pixels.

## Renderer contract

Live preview and every exporter call `AnimatedDrawingRenderer.image`. Keep brush behavior in kernels rather than UI or export code so GIF, MP4, PNG, and PNG-sequence output remain identical.

## Performance checklist

- Resample input rather than creating a vertex for every touch event.
- Keep export work cancellable and avoid retaining all frames in memory.
- Prefer instanced Metal geometry for high-density particle brushes.
- Test on a physical 120 Hz iPad with long strokes and 4096 px exports.

Wiggly is licensed under the Apache License 2.0. See the repository’s `LICENSE` file.
