import Combine
import Foundation
import SwiftUI
import UIKit

struct ProjectSummary: Identifiable, Hashable {
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
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
    private var pendingSaves: [UUID: Task<Void, Never>] = [:]

    private var projectsDirectory: URL {
        let root = URL.applicationSupportDirectory.appending(path: "Wiggly/Projects", directoryHint: .isDirectory)
        let legacyRoot = URL.applicationSupportDirectory.appending(path: "AmberWiggle/Projects", directoryHint: .isDirectory)
        if !FileManager.default.fileExists(atPath: root.path),
           FileManager.default.fileExists(atPath: legacyRoot.path) {
            try? FileManager.default.createDirectory(
                at: root.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? FileManager.default.moveItem(at: legacyRoot, to: root)
        }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    init() {
        reload()
    }

    func reload() {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: projectsDirectory,
            includingPropertiesForKeys: nil
        )) ?? []
        projects = urls.compactMap { url in
            guard url.pathExtension == "json",
                  let data = try? Data(contentsOf: url),
                  let document = try? decoder.decode(WiggleDocument.self, from: data) else { return nil }
            return summary(for: document)
        }
        .sorted { $0.modifiedAt > $1.modifiedAt }
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

    func scheduleAutosave(_ document: WiggleDocument) {
        pendingSaves[document.id]?.cancel()
        let documentURL = documentURL(id: document.id)
        let thumbnailURL = thumbnailURL(id: document.id)
        let thumbnailSize = thumbnailRenderSize(for: document)
        pendingSaves[document.id] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }

            do {
                let worker = Task.detached(priority: .utility) {
                    try Task.checkCancellation()
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    encoder.dateEncodingStrategy = .iso8601
                    let data = try encoder.encode(document)
                    try Task.checkCancellation()
                    try data.write(to: documentURL, options: .atomic)

                    try Task.checkCancellation()
                    if let cgImage = AnimatedDrawingRenderer.image(
                        document: document,
                        phase: 0,
                        outputSize: thumbnailSize
                    ), let thumbnailData = UIImage(cgImage: cgImage).pngData() {
                        try Task.checkCancellation()
                        try thumbnailData.write(to: thumbnailURL, options: .atomic)
                    }
                }
                try await withTaskCancellationHandler(
                    operation: { try await worker.value },
                    onCancel: { worker.cancel() }
                )

                guard !Task.isCancelled, let self else { return }
                let item = self.summary(for: document)
                self.projects.removeAll { $0.id == document.id }
                self.projects.append(item)
                self.projects.sort { $0.modifiedAt > $1.modifiedAt }
                self.pendingSaves[document.id] = nil
            } catch {
                guard !Task.isCancelled else { return }
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

    private func thumbnailRenderSize(for document: WiggleDocument) -> CGSize {
        let width = CGFloat(max(1, document.width))
        let height = CGFloat(max(1, document.height))
        let scale = 512 / max(width, height)
        return CGSize(width: max(1, width * scale), height: max(1, height * scale))
    }

    private func writeThumbnail(for document: WiggleDocument) {
        guard let cgImage = AnimatedDrawingRenderer.image(
            document: document,
            phase: 0,
            outputSize: thumbnailRenderSize(for: document)
        ), let data = UIImage(cgImage: cgImage).pngData() else { return }
        try? data.write(to: thumbnailURL(id: document.id), options: .atomic)
    }
}
