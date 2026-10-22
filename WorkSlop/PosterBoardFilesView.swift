import SwiftUI
import UniformTypeIdentifiers

/// Import-first PosterBoard file management: the user brings
/// .tendies files; the engine's PosterBoard stage delivers them on
/// the next apply. Plain table, no animation behind the content.
struct PosterBoardFilesView: View {
    @State private var importing = false
    @State private var note: String?
    @State private var files: [String] = TendiesStore.list(kind: "Tendies")

    var body: some View {
        List {
            Section {
                Button("Import PosterBoard file (.tendies)") { importing = true }
                    .accessibilityIdentifier("pb-import")
                if files.isEmpty {
                    Text("Nothing imported. PosterBoard delivers nothing until at least one .tendies is here.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(files, id: \.self) { name in
                        Label(name, systemImage: "doc")
                            .font(.footnote)
                    }
                    .onDelete { offsets in
                        TendiesStore.delete(at: offsets, from: files, kind: "Tendies")
                        files = TendiesStore.list(kind: "Tendies")
                    }
                }
            } header: {
                Text("PosterBoard (.tendies)")
            } footer: {
                Text("Imported files ride the next apply when the Tendies toggle is staged.")
            }

            if let note {
                Section {
                    Text(note)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("PosterBoard Files")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $importing,
                      allowedContentTypes: [UTType(filenameExtension: "tendies") ?? .data],
                      allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls):
                var imported = 0
                for url in urls {
                    guard url.pathExtension.lowercased() == "tendies" else { continue }
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    if TendiesStore.save(url: url, kind: "Tendies") { imported += 1 }
                }
                files = TendiesStore.list(kind: "Tendies")
                note = imported > 0
                    ? "Imported \(imported) .tendies file(s). They ride the next engine apply."
                    : "Nothing imported - this table takes .tendies only."
            case .failure:
                note = "Import cancelled."
            }
        }
    }
}

// MARK: - Tendies store (PosterBoard imports)

enum TendiesStore {
    static func dir(kind: String) -> URL {
        let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(kind, isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static func list(kind: String) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: dir(kind: kind).path))?.sorted() ?? []
    }

    static func save(url: URL, kind: String) -> Bool {
        // No import-time cap: imports are never refused; the
        // engine decides how much rides one apply.
        let dest = dir(kind: kind).appendingPathComponent(url.lastPathComponent)
        do {
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.copyItem(at: url, to: dest)
            return true
        } catch {
            return false
        }
    }

    static func urls(kind: String) -> [URL] {
        list(kind: kind).map { dir(kind: kind).appendingPathComponent($0) }
    }

    static func delete(at offsets: IndexSet, from files: [String], kind: String) {
        for i in offsets {
            try? FileManager.default.removeItem(at: dir(kind: kind).appendingPathComponent(files[i]))
        }
    }
}
