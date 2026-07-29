import SwiftUI

struct ContentView: View {
    @StateObject private var library = ProjectLibrary()

    var body: some View {
        GalleryView(library: library)
    }
}

#Preview {
    ContentView()
}
