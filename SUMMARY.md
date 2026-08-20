## Objective
- Fix the user-reported dull/dim color bug: strokes look vivid while drawing, but lose color (get dull) once the pencil lifts and the stroke becomes committed. Only reproducible on a **physical device** (confirmed by user; multiple brushes; no screenshot available). FIX APPLIED.
- Prior objective (GPU/CPU layer z-order) is complete and verified.

## Important Details
- Build-tool trap: the Xcode build tool targets the device (`Debug-iphoneos`), leaving the checked-in simulator app stale. Simulator builds must be explicit: `xcodebuild -project Wiggly.xcodeproj -scheme Wiggly -configuration Debug -sdk iphonesimulator -destination 'platform=iOS Simulator,id=670150E3-D07F-40C3-A738-9C7AFE849C00' -derivedDataPath /tmp/wiggly_dd build`; install from `/tmp/wiggly_dd/Build/Products/Debug-iphonesimulator/Wiggly.app`.
- ROOT CAUSE of the dull-color bug: the asymmetric color path between preview and committed. During drawing the active GPU stroke is written by the Metal renderer (`encodePreview`) directly into the drawable — raw sRGB brush bytes, no CI. After lift, the same stroke is read back via `CIImage(mtlTexture: gpu)` which tags the plain layer texture with NO color space, so CI interprets its sRGB bytes in the context's working color space (device RGB/linear on wide-gamut devices) and desaturates them. On the simulator's sRGB profile the round-trip is identity, so it only shows on a real P3 device.
- FIX (MetalCanvasView.swift, ~line 1141): `CIImage(mtlTexture: gpu, options: [.colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])` — explicitly tags the GPU layer texture as sRGB, matching how the Metal shaders encode the brush colors, so CI color-manages instead of misinterpreting. Verified: simulator colors unchanged (still pure red/green/blue/yellow, static and dynamic paths identical) — identity on sRGB, correct on P3.
- Test doc conventions: canvas 2048x2048, `hSamples(_ y: x0=300..1748)` horizontal stroke helper; simulator screenshot scale ~0.72 (canvas y0≈473); canvas screen x ≈ 66-1626.
- Pixel-analysis scripts in `/tmp`: `color.py`, `color2.py` (hue-band finder), `color3.py` (per-stroke-row avg/max/min saturation stats, calibrated y0=905 for doc y 600, scale 0.72), plus older `map.py`/`scan*.py`.
- `ContentView.swift` currently restored to the plain GalleryView version (backup `/tmp/ContentView.gallery.bak`); the older `/tmp/ContentView.swift.bak` holds the same 13-line file.
- Bundle id `co.rizzio.wiggly`; simulator UDID `670150E3-D07F-40C3-A738-9C7AFE849C00` (iPad Pro 11-inch M5).
- `WiggleDocument` is a mutable struct; preview code must use `var` copies.
- Build is clean (only unrelated pre-existing appintents warning).

## Work State
### Completed
- Dull-color bug root-caused and fixed via sRGB color-space tag on `CIImage(mtlTexture:)` reads of GPU layer textures (MetalCanvasView.swift ~1141). Verified no simulator regression; final build SUCCEEDED; autoplay test hack removed from `EditorView.onAppear`; `ContentView.swift` restored to GalleryView.
- Prior z-order work (all 6 renderers chunk/Range refactor, per-layer GPU textures, interleaved composite, dynamic/static paths) complete and verified.
- Diagnostic scaffolding used during this session: `/tmp/wiggly_colors{,_dyn,_fix}.png` screenshots; 4-stroke color test doc (red dashed / green particle / yellow star = GPU, blue goo = CPU) measured pure committed colors in both static and dynamic paths.

### Active
- (none)

### Blocked
- Cannot verify the fix on a real device from here — user should install to device and confirm the dull colors are gone after lifting the pencil. If still dull, next suspects: (1) set `MTKView.colorspace = sRGB` so the drawable presentation is uniformly color-managed (affects overall device color correctness, separate from the preview/committed asymmetry), (2) check `CIContext` `workingColorSpace` option.

## Next Move
1. Ask the user to install the fresh build on their physical device and draw a few strokes of different brushes/colors, confirming the committed strokes now match the vivid preview.
2. If the dulling persists on device, apply the MTKView `colorspace = sRGB` fix in the canvas setup and retest.
3. Otherwise, consider this bug closed and (if requested) commit the changes.

## Relevant Files
- `Wiggly/Rendering/MetalCanvasView.swift`: THE FIX at ~1141 (`CIImage(mtlTexture:options:[.colorSpace: sRGB])`); `hasCommittedGPU` branch ~1031, dynamic (~1176) vs static base-cache (~1191) paths, `BaseCacheKey`, `refreshRenderingDocument`.
- `Wiggly/Rendering/AnimatedBrushKernel.swift` (~4116-4155): CPU raster pipeline (`premultipliedLast`, sRGB space).
- All 6 renderers in `Wiggly/Rendering/*Renderer.swift`: committed vs preview buffers and shaders (encodePreview draws straight to drawable).
- `Wiggly/ContentView.swift`: restored GalleryView entry (backup `//tmp/ContentView.gallery.bak`).
- `//tmp/*.py` pixel scripts; `/tmp/wiggly_dd` sim build artifacts.
