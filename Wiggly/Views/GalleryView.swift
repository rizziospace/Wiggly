import SwiftUI
import UIKit

struct GalleryView: View {
    @ObservedObject var library: ProjectLibrary
    @State private var activeDocument: WiggleDocument?
    @State private var showingNewProject = false
    @State private var renameProject: ProjectSummary?
    @State private var renameText = ""

    private let columns = [GridItem(.adaptive(minimum: 220), spacing: 20)]

    var body: some View {
        NavigationStack {
            Group {
                if library.projects.isEmpty {
                    ContentUnavailableView {
                        Label("Start something wiggly", systemImage: "scribble.variable")
                    } description: {
                        Text("Create a canvas, pick up Apple Pencil, and draw in motion.")
                    } actions: {
                        Button("New Drawing") { showingNewProject = true }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 20) {
                            ForEach(library.projects) { project in
                                ProjectCard(project: project)
                                    .onTapGesture { activeDocument = library.load(id: project.id) }
                                    .contextMenu {
                                        Button("Rename", systemImage: "pencil") {
                                            renameText = project.name
                                            renameProject = project
                                        }
                                        Button("Duplicate", systemImage: "plus.square.on.square") {
                                            library.duplicate(project)
                                        }
                                        Divider()
                                        Button("Delete", systemImage: "trash", role: .destructive) {
                                            library.delete(project)
                                        }
                                    }
                            }
                        }
                        .padding(24)
                    }
                }
            }
            .navigationTitle("Wiggly")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("New Drawing", systemImage: "plus") { showingNewProject = true }
                }
            }
        }
        .sheet(isPresented: $showingNewProject) {
            NewProjectView { name, size in
                activeDocument = library.create(name: name, size: size)
            }
        }
        .fullScreenCover(item: $activeDocument) { document in
            EditorView(document: document, library: library)
        }
        .alert("Rename Drawing", isPresented: Binding(
            get: { renameProject != nil },
            set: { if !$0 { renameProject = nil } }
        )) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) {}
            Button("Rename") {
                if let renameProject { library.rename(renameProject, to: renameText) }
            }
        }
        .alert("Wiggly", isPresented: Binding(
            get: { library.lastError != nil },
            set: { if !$0 { library.lastError = nil } }
        )) {
            Button("OK") {}
        } message: {
            Text(library.lastError ?? "")
        }
    }
}

private struct DashboardThumbnail: View {
    let project: ProjectSummary
    @State private var image: UIImage?

    init(project: ProjectSummary) {
        self.project = project
        _image = State(initialValue: UIImage(contentsOfFile: project.thumbnailURL.path))
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18)
                .fill(.white)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "scribble.variable")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: project.modifiedAt) {
            image = UIImage(contentsOfFile: project.thumbnailURL.path)
        }
    }
}

private struct ProjectCard: View {
    let project: ProjectSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            DashboardThumbnail(project: project)
            .aspectRatio(CGFloat(project.width) / CGFloat(project.height), contentMode: .fit)
            .frame(maxWidth: .infinity, minHeight: 180, maxHeight: 260)
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .shadow(color: .black.opacity(0.08), radius: 14, y: 5)

            Text(project.name)
                .font(.headline)
                .lineLimit(1)
            Text("\(project.width) × \(project.height) • \(project.modifiedAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
    }
}

private struct NewProjectView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = "Untitled"
    @State private var preset = CanvasPreset.square
    @State private var width = 2048
    @State private var height = 2048
    let onCreate: (String, CGSize) -> Void

    var body: some View {
        NavigationStack {
            Form {
                TextField("Drawing name", text: $name)
                Picker("Canvas", selection: $preset) {
                    ForEach(CanvasPreset.allCases) { Text($0.title).tag($0) }
                }
                .onChange(of: preset) { _, value in
                    guard value != .custom else { return }
                    width = Int(value.size.width)
                    height = Int(value.size.height)
                }
                Section("Dimensions") {
                    Stepper("Width: \(width) px", value: $width, in: 256...4096, step: 128)
                    Stepper("Height: \(height) px", value: $height, in: 256...4096, step: 128)
                }
            }
            .navigationTitle("New Drawing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        onCreate(name, CGSize(width: width, height: height))
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }
}
