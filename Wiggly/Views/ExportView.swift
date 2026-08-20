import AVFoundation
import Photos
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ExportView: View {
    let document: WiggleDocument
    let onClose: () -> Void

    @State private var settings: ExportSettings
    @State private var expandedFormat: ExportFormat = .mp4
    @State private var progress = 0.0
    @State private var exportTask: Task<Void, Never>?
    @State private var status: ExportStatus = .idle
    @State private var locksAspectRatio = true
    @State private var editingResolution: ResolutionDimension?
    @State private var resolutionInput = ""

    private let durationChoices = [1, 2, 3, 4, 5]

    init(
        document: WiggleDocument,
        randomizeStrokePhase: Bool = false,
        onClose: @escaping () -> Void = {}
    ) {
        self.document = document
        self.onClose = onClose
        var initialSettings = ExportSettings(filename: document.name)
        initialSettings.format = .mp4
        let videoSize = Self.videoSafeSize(width: document.width, height: document.height)
        initialSettings.width = videoSize.width
        initialSettings.height = videoSize.height
        initialSettings.framesPerSecond = 60
        initialSettings.randomizeStrokePhase = randomizeStrokePhase
        // Export duration controls one complete loop. A one-second export
        // therefore always starts a fresh loop exactly one second later.
        initialSettings.duration = AnimationTiming.canvasLoopDuration
        initialSettings.bitrateMbps = 60
        initialSettings.codec = .h264
        _settings = State(initialValue: initialSettings)
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black.opacity(0.62)
                    .ignoresSafeArea()
                    .onTapGesture {
                        guard exportTask == nil else { return }
                        onClose()
                    }

                VStack(spacing: 18) {
                    header

                    HStack(spacing: 10) {
                        formatButton(.mp4, title: "MP4", subtitle: "Video", icon: "play.rectangle.fill")
                        formatButton(.gif, title: "GIF", subtitle: "Animated", icon: "photo.stack.fill")
                        formatButton(.pngSequence, title: "PNG", subtitle: "Sequence", icon: "square.stack.3d.up.fill")
                    }

                    settingsPanel

                    Spacer(minLength: 0)

                    exportFooter
                }
                .padding(22)
                .frame(
                    width: min(700, max(520, proxy.size.width - 56)),
                    height: min(600, max(520, proxy.size.height - 56))
                )
                .background(
                    Color(red: 0.075, green: 0.075, blue: 0.082),
                    in: RoundedRectangle(cornerRadius: 22, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(.white.opacity(0.13), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.45), radius: 36, y: 18)
                .padding(28)
            }
            .foregroundStyle(.white)
        }
        .preferredColorScheme(.dark)
        .onDisappear { exportTask?.cancel() }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Export")
                    .font(.title.bold())
                Text("Choose a format and save directly to Photos.")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.52))
            }
            Spacer()
            Button {
                exportTask?.cancel()
                onClose()
            } label: {
                Image(systemName: "xmark")
                    .font(.headline.weight(.semibold))
                    .frame(width: 38, height: 38)
                    .background(.white.opacity(0.08), in: Circle())
            }
            .buttonStyle(.plain)
        }
    }

    private func formatButton(
        _ format: ExportFormat,
        title: String,
        subtitle: String,
        icon: String
    ) -> some View {
        Button {
            select(format)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(expandedFormat == format ? .white.opacity(0.72) : .white.opacity(0.42))
                }
                Spacer(minLength: 0)
                if expandedFormat == format {
                    Image(systemName: "checkmark.circle.fill")
                }
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 66)
            .background(
                expandedFormat == format ? Color.accentColor.opacity(0.24) : Color.white.opacity(0.055),
                in: RoundedRectangle(cornerRadius: 13, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .disabled(exportTask != nil)
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(expandedFormat == format ? Color.accentColor : .white.opacity(0.08), lineWidth: 1)
        }
    }

    private var settingsPanel: some View {
        VStack(spacing: 16) {
            resolutionRow

            Divider().overlay(.white.opacity(0.08))

            choiceRow(
                title: "Frame Rate",
                values: fpsChoices(for: expandedFormat),
                selected: settings.framesPerSecond,
                label: { "\($0) fps" },
                select: { settings.framesPerSecond = $0 }
            )

            Divider().overlay(.white.opacity(0.08))

            choiceRow(
                title: "Duration",
                values: durationChoices,
                selected: Int(settings.duration),
                label: { "\($0)s" },
                select: { settings.duration = Double($0) }
            )

            Text(formatSummary(expandedFormat))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.white.opacity(0.5))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(18)
        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(.white.opacity(0.08), lineWidth: 1)
        }
    }

    private var resolutionRow: some View {
        HStack(spacing: 14) {
            Text("Resolution")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 82, alignment: .leading)

            HStack(spacing: 8) {
                resolutionField(.width)

                Text("×")
                    .font(.headline)
                    .foregroundStyle(.white.opacity(0.45))

                resolutionField(.height)

                Button {
                    locksAspectRatio.toggle()
                } label: {
                    Image(systemName: locksAspectRatio ? "link" : "link.badge.plus")
                        .font(.headline.weight(.semibold))
                        .frame(width: 52, height: 56)
                        .background(Color.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(locksAspectRatio ? "Unlock aspect ratio" : "Lock aspect ratio")

                Button("Canvas") {
                    editingResolution = nil
                    resolutionInput = ""
                    settings.width = document.width
                    settings.height = document.height
                }
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14)
                .frame(height: 56)
                .background(Color.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
                .contentShape(Rectangle())
                .buttonStyle(.plain)
            }
        }
        .popover(
            isPresented: resolutionKeypadPresented,
            attachmentAnchor: .rect(.bounds),
            arrowEdge: .top
        ) {
            resolutionKeypad
                .presentationCompactAdaptation(.popover)
        }
    }

    private func resolutionField(_ dimension: ResolutionDimension) -> some View {
        Button {
            editingResolution = dimension
            resolutionInput = ""
        } label: {
            VStack(spacing: 2) {
                Text(dimension.title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.5))
                Text(resolutionDisplay(for: dimension))
                    .font(.title3.weight(.semibold).monospacedDigit())
                    .contentTransition(.numericText())
            }
            .frame(width: 124, height: 56)
            .background(Color.white.opacity(0.11), in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(
                        editingResolution == dimension ? Color.accentColor : Color.white.opacity(0.08),
                        lineWidth: editingResolution == dimension ? 2 : 1
                    )
            }
            .contentShape(Rectangle())
        }
            .buttonStyle(ResolutionFieldButtonStyle())
            .accessibilityLabel("Export \(dimension.title)")
            .accessibilityHint("Opens the number keypad and replaces the current value")
    }

    private var resolutionKeypadPresented: Binding<Bool> {
        Binding(
            get: { editingResolution != nil },
            set: { isPresented in
                if !isPresented {
                    finishResolutionEntry()
                }
            }
        )
    }

    private var resolutionKeypad: some View {
        VStack(spacing: 14) {
            HStack {
                Text(editingResolution?.title ?? "Resolution")
                    .font(.title3.weight(.semibold))
                Spacer()
                Text("256–4096")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Text(resolutionInput.isEmpty ? "New value" : resolutionInput)
                .font(.title2.weight(.semibold).monospacedDigit())
                .foregroundStyle(resolutionInput.isEmpty ? .secondary : .primary)
                .frame(maxWidth: .infinity)
                .frame(height: 54)
                .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                ForEach([7, 8, 9, 4, 5, 6, 1, 2, 3], id: \.self) { digit in
                    resolutionKey(String(digit)) {
                        appendResolutionDigit(digit)
                    }
                }

                Button {
                    if !resolutionInput.isEmpty {
                        resolutionInput.removeLast()
                    }
                } label: {
                    Image(systemName: "delete.left")
                        .font(.title3.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 60)
                        .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Delete digit")

                resolutionKey("0") {
                    appendResolutionDigit(0)
                }

                Button {
                    finishResolutionEntry()
                } label: {
                    Image(systemName: "checkmark")
                        .font(.title3.weight(.bold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 60)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 12))
                .disabled(validResolutionInput == nil)
                .opacity(validResolutionInput == nil ? 0.35 : 1)
                .accessibilityLabel("Done")
            }
        }
        .padding(18)
        .frame(width: 320)
    }

    private func resolutionKey(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.title2.weight(.semibold).monospacedDigit())
                .frame(maxWidth: .infinity)
                .frame(height: 60)
                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func resolutionDisplay(for dimension: ResolutionDimension) -> String {
        if editingResolution == dimension {
            return resolutionInput.isEmpty ? " " : resolutionInput
        }
        return String(dimension == .width ? settings.width : settings.height)
    }

    private func appendResolutionDigit(_ digit: Int) {
        guard resolutionInput.count < 4 else { return }
        if resolutionInput == "0" {
            resolutionInput = String(digit)
        } else {
            resolutionInput.append(String(digit))
        }
    }

    private var validResolutionInput: Int? {
        guard let value = Int(resolutionInput), (256...4096).contains(value) else { return nil }
        return value
    }

    private func finishResolutionEntry() {
        guard let dimension = editingResolution else { return }
        defer {
            editingResolution = nil
            resolutionInput = ""
        }
        guard let value = validResolutionInput else { return }

        switch dimension {
        case .width:
            settings.width = value
            guard locksAspectRatio, document.width > 0 else { return }
            settings.height = max(1, Int(
                (Double(value) * Double(document.height) / Double(document.width)).rounded()
            ))
        case .height:
            settings.height = value
            guard locksAspectRatio, document.height > 0 else { return }
            settings.width = max(1, Int(
                (Double(value) * Double(document.width) / Double(document.height)).rounded()
            ))
        }
    }

    private func choiceRow(
        title: String,
        values: [Int],
        selected: Int,
        label: @escaping (Int) -> String,
        select: @escaping (Int) -> Void
    ) -> some View {
        HStack(spacing: 14) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 82, alignment: .leading)

            HStack(spacing: 8) {
                ForEach(values, id: \.self) { value in
                    Button {
                        select(value)
                    } label: {
                        Text(label(value))
                            .font(.headline.monospacedDigit())
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .foregroundStyle(selected == value ? Color.black : Color.white)
                            .background(
                                selected == value ? Color.white : Color.white.opacity(0.09),
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private var exportFooter: some View {
        if exportTask != nil {
            exportProgress
                .frame(maxWidth: .infinity)
        } else {
            VStack(spacing: 12) {
                statusView
                    .frame(minHeight: 34)

                Button {
                    startExport(expandedFormat)
                } label: {
                    Label(exportButtonTitle(expandedFormat), systemImage: "square.and.arrow.down")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .foregroundStyle(.black)
                        .background(.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var exportProgress: some View {
        VStack(spacing: 10) {
            ProgressView(value: progress)
                .tint(.white)
            HStack {
                Text(status.label)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.64))
                Spacer()
                Text("\(Int((progress * 100).rounded()))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.64))
            }
            Button("Cancel Export", role: .destructive) {
                exportTask?.cancel()
                exportTask = nil
                status = .idle
            }
            .font(.caption.weight(.semibold))
        }
    }

    @ViewBuilder
    private var statusView: some View {
        switch status {
        case .idle, .authorizing, .rendering, .saving:
            EmptyView()
        case .saved(let message):
            Label(message, systemImage: "checkmark.circle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.green)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .permissionDenied:
            HStack {
                Label("Photos access is required", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                Spacer()
                Button("Open Settings") {
                    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                    UIApplication.shared.open(url)
                }
                .font(.caption.weight(.semibold))
            }
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func select(_ format: ExportFormat) {
        expandedFormat = format
        settings.format = format
        let choices = fpsChoices(for: format)
        if !choices.contains(settings.framesPerSecond) {
            settings.framesPerSecond = choices.last ?? 30
        }
        status = .idle
    }

    private func startExport(_ format: ExportFormat) {
        progress = 0
        status = .authorizing
        var exportSettings = settings
        exportSettings.format = format

        exportTask = Task {
            var cleanupURL: URL?
            defer {
                if let cleanupURL { try? FileManager.default.removeItem(at: cleanupURL) }
                exportTask = nil
            }

            do {
                try await PhotoLibraryExporter.requestExportAuthorization()
                status = .rendering

                switch format {
                case .mp4:
                    let url = try await ExportService.export(
                        document: document,
                        settings: exportSettings,
                        progress: { progress = $0 }
                    )
                    cleanupURL = url
                    status = .saving
                    try await PhotoLibraryExporter.saveVideo(at: url)
                    status = .saved("MP4 saved to Photos")

                case .gif:
                    let url = try await ExportService.export(
                        document: document,
                        settings: exportSettings,
                        progress: { progress = $0 }
                    )
                    cleanupURL = url
                    status = .saving
                    try await PhotoLibraryExporter.saveImage(at: url)
                    status = .saved("Gifski HQ sharp GIF saved to Photos")

                case .pngSequence:
                    let urls = try await ExportService.exportPNGFrames(
                        document: document,
                        settings: exportSettings,
                        progress: { progress = $0 }
                    )
                    cleanupURL = urls.first?.deletingLastPathComponent()
                    status = .saving
                    try await PhotoLibraryExporter.saveImages(at: urls)
                    status = .saved("\(urls.count) PNG frames saved to Photos")

                case .png, .movAlpha:
                    throw ExportError.writerFailure("This format is not available in the quick exporter.")
                }
                progress = 1
            } catch is CancellationError {
                status = .idle
            } catch PhotoLibrarySaveError.permissionDenied {
                status = .permissionDenied
            } catch {
                status = .failed(error.localizedDescription)
            }
        }
    }

    private func fpsChoices(for format: ExportFormat) -> [Int] {
        switch format {
        case .mp4: [30, 60]
        case .gif, .pngSequence: [10, 15, 30, 60]
        case .png, .movAlpha: [30]
        }
    }

    private func formatSummary(_ format: ExportFormat) -> String {
        let dimensions = "\(settings.width) × \(settings.height)"
        let loop = "\(settings.duration.formatted(.number.precision(.fractionLength(0...1))))s loop"
        let timing = settings.randomizeStrokePhase ? "random" : "synced"
        return switch format {
        case .mp4: "\(dimensions) • \(settings.framesPerSecond) fps • \(loop) • \(timing)"
        case .gif: "\(dimensions) • \(settings.framesPerSecond) fps • \(loop) • \(timing) • Gifski HQ sharp"
        case .pngSequence: "\(dimensions) • \(settings.framesPerSecond) fps • \(loop) • \(settings.frameCount) frames"
        case .png, .movAlpha: dimensions
        }
    }

    private func exportButtonTitle(_ format: ExportFormat) -> String {
        switch format {
        case .mp4: "Export MP4 to Photos"
        case .gif: "Export GIF to Photos"
        case .pngSequence: "Export Frames to Photos"
        case .png, .movAlpha: "Export"
        }
    }

    private static func videoSafeSize(width: Int, height: Int) -> (width: Int, height: Int) {
        let sourceWidth = max(1, Double(width))
        let sourceHeight = max(1, Double(height))
        let longEdge = max(sourceWidth, sourceHeight)
        let shortEdge = min(sourceWidth, sourceHeight)
        let scale = min(1, 3840 / longEdge, 2160 / shortEdge)
        let scaledWidth = max(256, Int((sourceWidth * scale).rounded(.down)))
        let scaledHeight = max(256, Int((sourceHeight * scale).rounded(.down)))
        return (
            scaledWidth.isMultiple(of: 2) ? scaledWidth : scaledWidth - 1,
            scaledHeight.isMultiple(of: 2) ? scaledHeight : scaledHeight - 1
        )
    }
}

private enum ResolutionDimension {
    case width
    case height

    var title: String {
        switch self {
        case .width: "Width"
        case .height: "Height"
        }
    }
}

private struct ResolutionFieldButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .brightness(configuration.isPressed ? 0.08 : 0)
    }
}

private enum ExportStatus {
    case idle
    case authorizing
    case rendering
    case saving
    case saved(String)
    case permissionDenied
    case failed(String)

    var label: String {
        switch self {
        case .authorizing: "Requesting Photos access…"
        case .rendering: "Rendering…"
        case .saving: "Saving to Photos…"
        default: ""
        }
    }
}

private enum PhotoLibrarySaveError: LocalizedError {
    case permissionDenied
    case unsupportedResource
    case invalidVideo(String)
    case saveFailed(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            "Photos access was denied."
        case .unsupportedResource:
            "Photos couldn’t read the exported file."
        case .invalidVideo(let reason):
            "The MP4 is invalid: \(reason)"
        case .saveFailed(let message):
            message
        }
    }
}

private enum PhotoLibraryExporter {
    static func requestExportAuthorization() async throws {
        var status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if status == .notDetermined {
            status = await requestAddOnlyAuthorization()
        }

        switch status {
        case .authorized, .limited:
            return
        case .denied, .restricted, .notDetermined:
            throw PhotoLibrarySaveError.permissionDenied
        @unknown default:
            throw PhotoLibrarySaveError.permissionDenied
        }
    }

    static func saveVideo(at url: URL) async throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw PhotoLibrarySaveError.unsupportedResource
        }
        let asset = AVURLAsset(url: url)
        do {
            let isPlayable = try await asset.load(.isPlayable)
            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            guard isPlayable, !videoTracks.isEmpty else {
                throw PhotoLibrarySaveError.invalidVideo("No playable video track was created.")
            }
        } catch let error as PhotoLibrarySaveError {
            throw error
        } catch {
            throw PhotoLibrarySaveError.invalidVideo(error.localizedDescription)
        }
        try await saveResources(at: [url], type: .video)
    }

    static func saveImage(at url: URL) async throws {
        try await saveImages(at: [url])
    }

    static func saveImages(at urls: [URL]) async throws {
        try await saveResources(at: urls, type: .photo)
    }

    private static func saveResources(
        at urls: [URL],
        type: PHAssetResourceType
    ) async throws {
        guard !urls.isEmpty else { throw PhotoLibrarySaveError.unsupportedResource }
        guard urls.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else {
            throw PhotoLibrarySaveError.unsupportedResource
        }
        try await requestExportAuthorization()

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges {
                for url in urls {
                    let options = PHAssetResourceCreationOptions()
                    options.shouldMoveFile = true
                    options.originalFilename = url.lastPathComponent
                    options.contentType = UTType(filenameExtension: url.pathExtension)
                    PHAssetCreationRequest.forAsset().addResource(
                        with: type,
                        fileURL: url,
                        options: options
                    )
                }
            } completionHandler: { success, error in
                if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: PhotoLibrarySaveError.saveFailed(
                        Self.photoErrorMessage(error)
                    ))
                }
            }
        }
    }

    private static func photoErrorMessage(_ error: Error?) -> String {
        guard let error else { return "Photos couldn’t save this export." }
        let nsError = error as NSError
        return "Photos error \(nsError.code): \(nsError.localizedDescription)"
    }

    private static func requestAddOnlyAuthorization() async -> PHAuthorizationStatus {
        await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                continuation.resume(returning: status)
            }
        }
    }
}

#Preview {
    ExportView(document: .blank())
}
