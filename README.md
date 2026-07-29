# Wiggly

Wiggly is an experimental, open-source animated drawing app for iPad. It combines Apple Pencil input with deterministic animated brush rendering, editable layers, and animation export.

> Wiggly currently targets iPadOS 26 and is under active development. Test drawing performance and Apple Pencil behavior on a physical iPad.

## Features

- Apple Pencil pressure, tilt, azimuth, coalesced input, and palm rejection
- Pencil-only or Pencil-and-finger drawing modes
- Smooth canvas pan, zoom, and rotation
- Two-finger tap to undo and three-finger tap to redo
- Quick two-finger pinch to center and fit the canvas
- Persistent project gallery with autosave, thumbnails, rename, duplicate, and delete
- Square, portrait, landscape, and custom canvases from 256–4096 px
- Editable drawing layers with visibility, opacity, reordering, duplication, rename, clear, fill, and delete actions
- Background Color layer that can be hidden for transparent export
- Image import from Photos and Files with move and scale controls
- Selection and partial-stroke erasing
- Full Brush Studio with a live drawing pad
- Customizable animated brushes with deterministic seamless loops
- Static PNG, animated GIF, H.264/HEVC MP4, and zipped PNG-sequence export
- Save images and videos directly to Photos or export through Files and the iOS share sheet

## Built-in Brushes

Wiggly currently includes:

- Wiggle Line
- Jitter Pencil
- Pulse Marker
- Scatter Dots
- Ghost Trail
- Dashed
- Particle
- Goo
- Scribbles
- Particles
- Glitter
- Gradient
- Polka Dots
- Faded
- Charcoal
- Color Noise

Each brush stores its settings with every stroke, so changing a preset does not alter existing artwork.

## Requirements

- macOS with Xcode 26 or newer
- iPad running iPadOS 26 or newer
- Apple Pencil recommended
- An Apple Developer account or free personal development team for device signing

The project uses SwiftUI, UIKit touch handling, Core Graphics, MetalKit, AVFoundation, ImageIO, Photos, and [ZIPFoundation](https://github.com/weichsel/ZIPFoundation) 0.9.20.

## Getting Started

### Using GitHub Desktop

1. Clone the repository in GitHub Desktop.
2. Choose **Repository → Show in Finder**.
3. Open `Wiggly.xcodeproj` in Xcode.
4. Allow Xcode to resolve the ZIPFoundation Swift package.
5. Select the **Wiggly** project, then the **Wiggly** target.
6. Under **Signing & Capabilities**, choose your development team.
7. Replace `co.rizzio.wiggly` with a bundle identifier owned by your team if Xcode reports a signing conflict.
8. Connect an iPad, trust the Mac if prompted, and select the iPad as the run destination.
9. Press **Run** or use `⌘R`.

The first time Wiggly saves an export to Photos, iPadOS asks for add-only Photos permission.

## Using the App

1. From the Gallery, create a canvas using a preset or custom dimensions.
2. Tap the brush icon to open Brush Studio and choose a brush.
3. Draw with Apple Pencil. Use the left controls for brush size and opacity.
4. Pan, zoom, and rotate with two fingers.
5. Open Layers to add, reorder, hide, rename, duplicate, clear, fill, or delete layers.
6. Import an image from the layer panel, then use Transform Image to move or scale it.
7. Open **Actions → Export Animation** to choose the format, size, frame rate, duration, codec, bitrate, and transparency.
8. After rendering, save to Photos, Files, or another app through the iOS share sheet.

Projects autosave inside the app sandbox. Exported media is only shared when you explicitly choose a destination.

## Customizing a Brush

Open Brush Studio, select a built-in brush, and adjust the available controls. Depending on the brush, settings include:

- Color and additional brush colors
- Size and opacity
- Stroke smoothing and spacing
- Start and end width
- Motion amount, frequency, and loop cycles
- Apple Pencil pressure and tilt response
- Deterministic seed
- Scribble line count and synchronized/random motion
- Particle, glitter, texture, charcoal, and pattern-specific controls

Changes to a built-in brush save as that brush’s current settings. **Reset** restores its original defaults.

## Adding a New Brush Engine

See [BRUSHES.md](Wiggly/BRUSHES.md) for the full brush-development guide.

The basic workflow is:

1. Add a case to `BrushKind`.
2. Create an `AnimatedBrushKernel` implementation.
3. Render only from the stored stroke, brush settings, deterministic seed, and normalized loop phase.
4. Register the kernel in `BrushKernelRegistry`.
5. Add default settings and Brush Studio controls.
6. Test that frame zero matches the loop boundary without exporting a duplicate final frame.

Avoid wall-clock time and unseeded randomness. The same document, seed, and phase should always produce the same pixels in live playback and every export format.

## Project Structure

```text
Wiggly/
├── Export/          Animation and image exporters
├── Models/          Documents, strokes, brushes, layers, and editor state
├── Persistence/     Project library and brush preset storage
├── Rendering/       Animated brush kernels and canvas rendering
├── Views/           Gallery, editor, layers, Brush Studio, and export UI
├── Assets.xcassets
├── BRUSHES.md
└── WigglyApp.swift
```

## Contributing

Contributions, bug reports, performance improvements, and new brush engines are welcome.

1. Fork the repository.
2. Create a focused branch.
3. Keep brush output deterministic and loop-safe.
4. Build and test on a physical iPad when changing Pencil input or rendering.
5. Confirm existing document decoding and all export formats still work.
6. Open a pull request describing the change and how it was tested.

Please avoid committing signing identities, provisioning profiles, Xcode user-state folders, exported media, or local environment files.

## License

Wiggly is licensed under the [Apache License 2.0](LICENSE).

## Donate

If Wiggly is useful to you, you can support its development:

- **SOL:** `BLcuGzFvroPp56S9rHgHXyhCexCZYFKxgDzYJxxjCriz`
- **ETH:** `0x50D922255318e03f803ae1dD85755e17df2aFEC8`
