//
//  BackupAndRestoreView.swift (fork: chat-import)
//  OpenMinis fork — add an "Import" tab for importing chat history from
//  ChatGPT / Claude / Grok/xAI / DeepSeek / 豆包 / generic exports.
//

import SwiftUI

/// Container for the three halves of the backup/restore/import feature.
struct BackupAndRestoreView: View {

    enum Tab: Hashable {
        case backup
        case restore
        case chatImport
    }

    /// Which half to show. Defaults to `.backup` so the existing path through
    /// the app is unchanged; the restore deep-link passes `.restore`.
    @State private var tab: Tab

    /// A package to open immediately in the restore tab — set when the user
    /// opened a `.minisbak` from Files / AirDrop.
    private let initialPackageURL: URL?

    init(initialTab: Tab = .backup, initialPackageURL: URL? = nil) {
        _tab = State(initialValue: initialTab)
        self.initialPackageURL = initialPackageURL
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text("Backup").tag(Tab.backup)
                Text("Restore").tag(Tab.restore)
                Text("导入聊天记录").tag(Tab.chatImport)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.top, 8)
            .padding(.bottom, 4)

            // All children are Forms that own their own scrolling, so they sit
            // directly under the picker rather than inside another container.
            // They are all kept alive (ZStack + opacity) so switching tabs
            // never destroys a half-filled flow ([T-restore-keep-tab-state]).
            ZStack {
                BackupSettingsView(embedded: true)
                    .opacity(tab == .backup ? 1 : 0)
                    .allowsHitTesting(tab == .backup)
                    .accessibilityHidden(tab != .backup)
                BackupRestoreView(initialPackageURL: initialPackageURL, embedded: true)
                    .opacity(tab == .restore ? 1 : 0)
                    .allowsHitTesting(tab == .restore)
                    .accessibilityHidden(tab != .restore)
                ChatImportView(embedded: true)
                    .opacity(tab == .chatImport ? 1 : 0)
                    .allowsHitTesting(tab == .chatImport)
                    .accessibilityHidden(tab != .chatImport)
            }
        }
        .navigationTitle("Backup & Restore")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Folder picker for choosing a backup destination.
struct BackupFolderPicker: UIViewControllerRepresentable {
    let onPick: (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        init(onPick: @escaping (URL) -> Void) { self.onPick = onPick }

        func documentPicker(_ controller: UIDocumentPickerViewController,
                            didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            onPick(url)
        }
    }
}

/// Applies a navigation title only when a view is presented standalone.
struct StandaloneTitle: ViewModifier {
    let title: String
    let active: Bool

    func body(content: Content) -> some View {
        if active {
            content
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
        } else {
            content
        }
    }
}
