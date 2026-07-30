import Photos
import SwiftUI
import UIKit

private struct ExportedFile: Identifiable, Sendable {
    let id = UUID()
    let url: URL
    let format: ExportFormat
}

struct ExportView: View {
    @Environment(\.dismiss) private var dismiss
    let document: WiggleDocument
    @State private var settings: ExportSettings
    @State private var progress = 0.0
    @State private var exportTask: Task<Void, Never>?
    @State private var exportedFile: ExportedFile?
    @State private var showsShareSheet = false
    @State private var showsFilesPicker = false
    @State private var showsDestinationPicker = false
    @State private var isSavingToPhotos = false
    @State private var alertTitle = "Export Failed"
    @State private var showsSettingsAction = false
    @State private var errorMessage: String?

    init(document: WiggleDocument) {
        self.document = document
        _settings = State(initialValue: ExportSettings(filename: document.name))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Format") {
                    Picker("Export as", selection: $settings.format) {
                        ForEach(ExportFormat.allCases) { Text($0.title).tag($0) }
                    }
                    TextField("Filename", text: $settings.filename)
                    if settings.format == .mp4 {
                        Picker("Codec", selection: $settings.codec) {
                            ForEach(VideoCodec.allCases) { Text($0.title).tag($0) }
                        }
                    }
                    if settings.format.isVideo {
                        LabeledContent("Bitrate") {
                            HStack {
                                Slider(value: $settings.bitrateMbps, in: 1...50)
                                Text("\(settings.bitrateMbps, specifier: "%.0f") Mbps")
                                    .frame(width: 72)
                            }
                        }
                    }
                    if settings.format == .movAlpha {
                        Label("HEVC with alpha preserves transparent pixels in a .mov file.", systemImage: "checkerboard.rectangle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Dimensions") {
                    Stepper("Width: \(settings.width) px", value: $settings.width, in: 256...4096, step: 2)
                    Stepper("Height: \(settings.height) px", value: $settings.height, in: 256...4096, step: 2)
                    Button("Match Canvas") {
                        settings.width = document.width
                        settings.height = document.height
                    }
                }

                if settings.format != .png {
                    Section("Timeline") {
                        Stepper("Frame rate: \(settings.framesPerSecond) fps", value: $settings.framesPerSecond, in: 12...60)
                        LabeledContent("Duration") {
                            HStack {
                                Slider(value: $settings.duration, in: 1...12, step: 0.5)
                                Text("\(settings.duration, specifier: "%.1f") s").frame(width: 48)
                            }
                        }
                        LabeledContent("Frames", value: "\(settings.frameCount)")
                    }
                }

                Section("Background") {
                    if settings.format == .mp4 {
                        Label("MP4/H.264 and standard HEVC do not support transparency. The canvas background will be included.", systemImage: "info.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if settings.format == .movAlpha {
                        Label("Transparent background is enabled for this format.", systemImage: "checkerboard.rectangle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Label("iOS Photos may preview this video as opaque or duplicated. The exported file keeps its transparency; preview it in Files or on a Mac.", systemImage: "info.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Toggle("Transparent background", isOn: $settings.transparentBackground)
                        if !document.resolvedBackgroundVisible {
                            Label("The Background Color layer is hidden, so this export will be transparent.", systemImage: "checkerboard.rectangle")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if exportTask != nil {
                    Section("Rendering") {
                        ProgressView(value: progress)
                        Button("Cancel", role: .destructive) {
                            exportTask?.cancel()
                            exportTask = nil
                        }
                    }
                }
            }
            .navigationTitle("Export Animation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        exportTask?.cancel()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    HStack(spacing: 12) {
                        if exportedFile != nil {
                            Button("Save") {
                                showsDestinationPicker = true
                            }
                            .disabled(isSavingToPhotos)
                        }
                        Button("Export") { startExport() }
                            .disabled(exportTask != nil || isSavingToPhotos)
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
        }
        .presentationDetents([.large])
        .confirmationDialog(
            "Export Ready",
            isPresented: $showsDestinationPicker,
            titleVisibility: .visible
        ) {
            if let exportedFile {
                if let photosTitle = photosSaveTitle(for: exportedFile.format) {
                    Button(photosTitle) {
                        saveToPhotos(exportedFile)
                    }
                }
                Button("Save to Files") {
                    showsFilesPicker = true
                }
                Button("More Sharing Options") {
                    showsShareSheet = true
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let exportedFile {
                Text(exportedFile.url.lastPathComponent)
            }
        }
        .alert(alertTitle, isPresented: Binding(
            get: { errorMessage != nil },
            set: {
                if !$0 {
                    errorMessage = nil
                    showsSettingsAction = false
                }
            }
        )) {
            if showsSettingsAction {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
            }
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .sheet(isPresented: $showsShareSheet) {
            if let exportedFile {
                ExportActivityView(file: exportedFile)
                    .ignoresSafeArea()
            }
        }
        .sheet(isPresented: $showsFilesPicker) {
            if let exportedFile {
                ExportDocumentPicker(url: exportedFile.url)
                    .ignoresSafeArea()
            }
        }
    }

    private func photosSaveTitle(for format: ExportFormat) -> String? {
        switch format {
        case .png, .gif: "Save Image"
        case .mp4, .movAlpha: "Save Video"
        case .pngSequence: nil
        }
    }

    private func saveToPhotos(_ file: ExportedFile) {
        isSavingToPhotos = true
        Task {
            do {
                try await PhotoLibraryExporter.save(file)
                alertTitle = "Saved to Photos"
                showsSettingsAction = false
                errorMessage = file.format.isVideo
                    ? "The video was saved to your Photos library."
                    : "The image was saved to your Photos library."
            } catch PhotoLibrarySaveError.permissionDenied {
                alertTitle = "Photos Access Needed"
                showsSettingsAction = true
                errorMessage = "Allow Photos access in Settings to save exports to your gallery."
            } catch {
                alertTitle = "Couldn’t Save to Photos"
                showsSettingsAction = false
                errorMessage = error.localizedDescription
            }
            isSavingToPhotos = false
        }
    }

    private func startExport() {
        progress = 0
        exportedFile = nil
        showsDestinationPicker = false
        alertTitle = "Export Failed"
        showsSettingsAction = false
        let exportSettings = settings
        exportTask = Task {
            do {
                let url = try await ExportService.export(document: document, settings: exportSettings) {
                    progress = $0
                }
                guard !Task.isCancelled else { return }
                exportedFile = ExportedFile(url: url, format: exportSettings.format)
                showsDestinationPicker = true
            } catch is CancellationError {
                // Cancellation is user initiated.
            } catch {
                errorMessage = error.localizedDescription
            }
            exportTask = nil
        }
    }
}

private enum PhotoLibrarySaveError: LocalizedError {
    case permissionDenied
    case unsupportedFormat
    case saveFailed(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            "Photos access was denied."
        case .unsupportedFormat:
            "This export format can’t be saved to Photos."
        case .saveFailed(let message):
            message
        }
    }
}

private enum PhotoLibraryExporter {
    static func save(_ file: ExportedFile) async throws {
        let resourceType: PHAssetResourceType
        switch file.format {
        case .png, .gif:
            resourceType = .photo
        case .mp4, .movAlpha:
            resourceType = .video
        case .pngSequence:
            throw PhotoLibrarySaveError.unsupportedFormat
        }

        let status = await requestAddOnlyAuthorization()
        guard status == .authorized || status == .limited else {
            throw PhotoLibrarySaveError.permissionDenied
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges {
                let options = PHAssetResourceCreationOptions()
                options.originalFilename = file.url.lastPathComponent
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: resourceType, fileURL: file.url, options: options)
            } completionHandler: { success, error in
                if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: PhotoLibrarySaveError.saveFailed(
                        error?.localizedDescription ?? "Photos couldn’t save this export."
                    ))
                }
            }
        }
    }

    private static func requestAddOnlyAuthorization() async -> PHAuthorizationStatus {
        await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                continuation.resume(returning: status)
            }
        }
    }
}

private struct ExportActivityView: UIViewControllerRepresentable {
    let file: ExportedFile

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let item: Any
        if file.format == .png,
           let image = UIImage(contentsOfFile: file.url.path) {
            item = image
        } else {
            item = file.url
        }
        return UIActivityViewController(activityItems: [item], applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

private struct ExportDocumentPicker: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        UIDocumentPickerViewController(forExporting: [url], asCopy: true)
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}
}
