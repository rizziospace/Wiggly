import Combine
import Foundation
import ImageIO
import SwiftUI
import UIKit

/// Serializes document encoding away from the main actor. JSONEncoder does not
/// cooperatively cancel while it is walking a large value graph, so allowing a
/// detached encoder per edit can create several simultaneous full-document
/// encodes. Actor isolation guarantees there is only one encoder doing work.
private actor ProjectSaveCoordinator {
    func save(_ document: WiggleDocument, to url: URL) throws {
        try Task.checkCancellation()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(document)
        try Task.checkCancellation()
        try data.write(to: url, options: .atomic)
    }
}

struct ProjectSummary: Identifiable, Hashable, Sendable {
    let id: UUID
    var name: String
    var modifiedAt: Date
    var width: Int
    var height: Int
    var thumbnailURL: URL
}

@MainActor
final class ProjectLibrary: ObservableObject {
    @Published private(set) var projects: [ProjectSummary] = []
    @Published var lastError: String?

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
    private var pendingSaves: [UUID: Task<Void, Never>] = [:]
    private var reloadTask: Task<Void, Never>?
    private let saveCoordinator = ProjectSaveCoordinator()

    private var projectsDirectory: URL {
        let root = URL.applicationSupportDirectory.appending(path: "Wiggly/Projects", directoryHint: .isDirectory)
        let legacyRoot = URL.applicationSupportDirectory.appending(path: "AmberWiggle/Projects", directoryHint: .isDirectory)
        
        // Ensure new directory exists; migrate from legacy location if needed
        if !FileManager.default.fileExists(atPath: root.path) {
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
        // Migrate from legacy location if it exists and root is empty or missing files
        if FileManager.default.fileExists(atPath: legacyRoot.path) {
            let legacyFiles = (try? FileManager.default.contentsOfDirectory(at: legacyRoot, includingPropertiesForKeys: nil)) ?? []
            let rootFiles = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
            if legacyFiles.count > rootFiles.count {
                for file in legacyFiles {
                    let destination = root.appendingPathComponent(file.lastPathComponent)
                    if !FileManager.default.fileExists(atPath: destination.path) {
                        try? FileManager.default.moveItem(at: file, to: destination)
                    }
                }
                // Optionally remove legacy directory after successful migration
                // try? FileManager.default.removeItem(at: legacyRoot)
            }
        }
        
        return root
    }

    init() {
        reload()
    }

    func reload() {
        reloadTask?.cancel()
        let directory = projectsDirectory
        var urls = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey]
        )) ?? []
        // Fallback to legacy location if directory is empty
        if urls.isEmpty {
            let legacyDir = URL.applicationSupportDirectory.appending(path: "AmberWiggle/Projects", directoryHint: .isDirectory)
            let legacyUrls = (try? FileManager.default.contentsOfDirectory(at: legacyDir, includingPropertiesForKeys: [.isRegularFileKey])) ?? []
            if !legacyUrls.isEmpty {
                urls = legacyUrls
            }
        }

        // Decoding every document can be expensive when a project contains many
        // strokes. Keep it off the main actor so the gallery appears immediately.
        reloadTask = Task { [weak self] in
            let summaries = await Task.detached(priority: .userInitiated) {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                return urls.compactMap { url -> ProjectSummary? in
                    guard url.pathExtension == "json",
                          let data = try? Data(contentsOf: url),
                          let document = try? decoder.decode(WiggleDocument.self, from: data) else { return nil }
                    return ProjectSummary(
                        id: document.id,
                        name: document.name,
                        modifiedAt: document.modifiedAt,
                        width: document.width,
                        height: document.height,
                        thumbnailURL: directory.appending(path: "\(document.id.uuidString)-render-v6.png")
                    )
                }
                .sorted { $0.modifiedAt > $1.modifiedAt }
            }.value

            guard !Task.isCancelled, let self else { return }
            self.projects = summaries
            self.reloadTask = nil
        }
    }

    @discardableResult
    func create(name: String, size: CGSize) -> WiggleDocument {
        let document = WiggleDocument.blank(name: name.isEmpty ? "Untitled" : name, size: size)
        saveImmediately(document)
        return document
    }

    func load(id: UUID) -> WiggleDocument? {
        do {
            let data = try Data(contentsOf: documentURL(id: id))
            return try decoder.decode(WiggleDocument.self, from: data)
        } catch {
            lastError = "Couldn’t open this drawing: \(error.localizedDescription)"
            return nil
        }
    }

    func loadAsync(id: UUID) async -> WiggleDocument? {
        let url = documentURL(id: id)
        do {
            return try await Task.detached(priority: .userInitiated) {
                let data = try Data(contentsOf: url)
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                return try decoder.decode(WiggleDocument.self, from: data)
            }.value
        } catch {
            lastError = "Couldn’t open this drawing: \(error.localizedDescription)"
            return nil
        }
    }

    func thumbnailImage(for project: ProjectSummary) async -> UIImage? {
        let documentURL = documentURL(id: project.id)
        let thumbnailURL = project.thumbnailURL
        let pngData: Data? = await Task.detached(priority: .utility) { () -> Data? in
            if let cached = try? Data(contentsOf: thumbnailURL), !cached.isEmpty {
                return cached
            }

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard let data = try? Data(contentsOf: documentURL),
                  let document = try? decoder.decode(WiggleDocument.self, from: data),
                  let cgImage = AnimatedDrawingRenderer.image(
                    document: document,
                    phase: 0,
                    outputSize: Self.thumbnailRenderSize(for: document)
                  ) else { return nil }

            guard let rendered = UIImage(cgImage: cgImage).pngData() else { return nil }
            try? rendered.write(to: thumbnailURL, options: .atomic)
            return rendered
        }.value

        guard let pngData else { return nil }
        return UIImage(data: pngData)
    }

    func scheduleAutosave(_ document: WiggleDocument) {
        pendingSaves[document.id]?.cancel()
        let documentURL = documentURL(id: document.id)
        let coordinator = saveCoordinator
        pendingSaves[document.id] = Task(priority: .utility) { [weak self] in
            // Wait for a real idle window. Rapid Pencil-up/Pencil-down cycles
            // should not continuously serialize a growing document.
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }

            do {
                try await coordinator.save(document, to: documentURL)

                guard !Task.isCancelled, let self else { return }
                // Regenerate the dashboard thumbnail on the same background task
                // so gallery cards reflect the latest edits. writeThumbnail runs
                // synchronously here (off the main actor) rather than in
                // saveImmediately, which is called on the main actor per stroke.
                self.writeThumbnail(for: document)
                let item = self.summary(for: document)
                self.projects.removeAll { $0.id == document.id }
                self.projects.append(item)
                self.projects.sort { $0.modifiedAt > $1.modifiedAt }
                self.pendingSaves[document.id] = nil
            } catch {
                guard !Task.isCancelled else { return }
                self?.pendingSaves[document.id] = nil
                self?.lastError = "Couldn’t save this drawing: \(error.localizedDescription)"
            }
        }
    }

    func saveImmediately(_ document: WiggleDocument) {
        pendingSaves[document.id]?.cancel()
        pendingSaves[document.id] = nil
        do {
            let data = try encoder.encode(document)
            try data.write(to: documentURL(id: document.id), options: .atomic)
            writeThumbnail(for: document)
            let item = summary(for: document)
            projects.removeAll { $0.id == document.id }
            projects.append(item)
            projects.sort { $0.modifiedAt > $1.modifiedAt }
        } catch {
            lastError = "Couldn’t save this drawing: \(error.localizedDescription)"
        }
    }

    func rename(_ project: ProjectSummary, to name: String) {
        guard var document = load(id: project.id) else { return }
        document.name = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled" : name
        document.modifiedAt = Date()
        saveImmediately(document)
    }

    func duplicate(_ project: ProjectSummary) {
        guard var document = load(id: project.id) else { return }
        document.id = UUID()
        document.name += " Copy"
        document.createdAt = Date()
        document.modifiedAt = Date()
        saveImmediately(document)
    }

    func delete(_ project: ProjectSummary) {
        pendingSaves[project.id]?.cancel()
        do {
            try? FileManager.default.removeItem(at: project.thumbnailURL)
            try? FileManager.default.removeItem(at: legacyThumbnailURL(id: project.id))
            try FileManager.default.removeItem(at: documentURL(id: project.id))
            projects.removeAll { $0.id == project.id }
        } catch {
            lastError = "Couldn’t delete this drawing: \(error.localizedDescription)"
        }
    }

    private func documentURL(id: UUID) -> URL {
        projectsDirectory.appending(path: "\(id.uuidString).json")
    }

    private func thumbnailURL(id: UUID) -> URL {
        // Bump when thumbnail rendering changes so previously cached images do
        // not preserve obsolete brush geometry after an app update.
        projectsDirectory.appending(path: "\(id.uuidString)-render-v6.png")
    }

    private func legacyThumbnailURL(id: UUID) -> URL {
        projectsDirectory.appending(path: "\(id.uuidString).png")
    }

    private func summary(for document: WiggleDocument) -> ProjectSummary {
        ProjectSummary(
            id: document.id,
            name: document.name,
            modifiedAt: document.modifiedAt,
            width: document.width,
            height: document.height,
            thumbnailURL: thumbnailURL(id: document.id)
        )
    }

    private nonisolated static func thumbnailRenderSize(for document: WiggleDocument) -> CGSize {
        let width = CGFloat(max(1, document.width))
        let height = CGFloat(max(1, document.height))
        let scale = 512 / max(width, height)
        return CGSize(width: max(1, width * scale), height: max(1, height * scale))
    }

    private func decodedThumbnail(at url: URL) -> UIImage? {
        guard let data = try? Data(contentsOf: url),
              !data.isEmpty,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              CGImageSourceGetStatus(source) == .statusComplete,
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
              let image = CGImageSourceCreateImageAtIndex(
                source,
                0,
                [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
              )
        else { return nil }
        return UIImage(cgImage: image)
    }

    private func writeThumbnail(for document: WiggleDocument) {
        guard let cgImage = AnimatedDrawingRenderer.image(
            document: document,
            phase: 0,
            outputSize: Self.thumbnailRenderSize(for: document)
        ), let data = UIImage(cgImage: cgImage).pngData() else { return }
        try? data.write(to: thumbnailURL(id: document.id), options: .atomic)
    }
}
