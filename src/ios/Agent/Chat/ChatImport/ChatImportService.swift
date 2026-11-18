//
//  ChatImportService.swift
//  OpenMinis fork — import chat history from other AI apps
//
//  Bridges the pure parser (ChatArchiveParser) and the app's ChatStore /
//  ProviderConfigStore:
//
//    file (.zip/.json/.jsonl/.md/.txt)
//        → extract zip (BackupZipExtractor) → parse each inner file
//        → [ImportedConversation]
//        → createSession + appendMessages + model binding
//
//  Roles map ImportedRole → MessageRole (`.other` folds into the following
//  user turn so a "system" preamble never shows as a bare bubble).
//

import Foundation

struct ChatImportResult {
    var importedSessions: Int
    var importedMessages: Int
    var skippedConversations: Int
    var notes: [String]
}

enum ChatImportService {

    // MARK: - Model picker support

    struct ModelOption: Identifiable {
        let id: String            // ModelEntry.id (compositeKey) — for the binding
        let modelId: String       // LLM API model id — for sessions.model_id
        let providerLabel: String
        let modelDisplayName: String
        var label: String { "\(providerLabel) · \(modelDisplayName)" }
    }

    /// All model entries across all enabled provider instances, for the
    /// import target-model picker.
    static func modelOptions() -> [ModelOption] {
        let store = ProviderConfigStore.shared
        let cfg = store.config
        var out: [ModelOption] = []
        for instance in cfg.instances where instance.isEnabled {
            for entry in store.entries(for: instance.id) where !entry.isHidden {
                out.append(ModelOption(
                    id: entry.id,
                    modelId: entry.model.id,
                    providerLabel: instance.label,
                    modelDisplayName: entry.model.displayName
                ))
            }
        }
        // Stable ordering: provider label, then model display name.
        out.sort { ($0.providerLabel, $0.modelDisplayName) < ($1.providerLabel, $1.modelDisplayName) }
        return out
    }

    /// First model entry of the default primary group — the sensible default
    /// when the user does not pick explicitly.
    static func defaultModelOption() -> ModelOption? {
        let store = ProviderConfigStore.shared
        guard let gid = store.config.defaultPrimaryGroupId,
              let group = store.group(for: gid),
              let entryId = group.memberEntryIds.first else { return nil }
        guard let entry = store.entry(for: entryId) else { return nil }
        let label = store.instance(for: entry.providerInstanceId)?.label ?? entry.providerInstanceId
        return ModelOption(id: entry.id, modelId: entry.model.id,
                           providerLabel: label,
                           modelDisplayName: entry.model.displayName)
    }

    // MARK: - Import entry points

    /// Parse a user-picked export (may be a .zip). Returns conversations
    /// WITHOUT writing anything — the UI previews first.
    static func parseExport(url: URL) throws -> ParsedArchive {
        let fm = FileManager.default
        let lower = url.lastPathComponent.lowercased()
        let notes = [String]()

        if lower.hasSuffix(".zip") || isZipMagic(at: url) {
            let tmp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
            var unzipNotes: [String] = []
            do {
                try BackupZipExtractor.extract(url, to: tmp)
            } catch {
                throw ImportError.unreadableZip(error.localizedDescription)
            }
            defer { try? fm.removeItem(at: tmp) }

            let files = (try? fm.contentsOfDirectory(
                at: tmp, includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles])) ?? []
            var convos: [ImportedConversation] = []
            for f in files.sorted(by: { $0.path < $1.path }) {
                let n = f.lastPathComponent.lowercased()
                guard n.hasSuffix(".json") || n.hasSuffix(".jsonl")
                    || n.hasSuffix(".ndjson") || n.hasSuffix(".md")
                    || n.hasSuffix(".txt") else { continue }
                guard let data = try? Data(contentsOf: f) else {
                    unzipNotes.append("跳过无法读取的文件 \(f.lastPathComponent)")
                    continue
                }
                let parsed = ChatArchiveParser.parse(data: data, fileName: f.lastPathComponent)
                convos.append(contentsOf: parsed.conversations)
                unzipNotes.append(contentsOf: parsed.notes)
            }
            let merged = dedupByID(convos)
            return ParsedArchive(source: "Zip 包", conversations: merged,
                                 notes: notes + unzipNotes)
        }

        // Security-scoped file: read before the scope closes.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            throw ImportError.unreadable("无法读取该文件")
        }
        let parsed = ChatArchiveParser.parse(data: data,
                                             fileName: url.lastPathComponent)
        return ParsedArchive(source: parsed.source, conversations: parsed.conversations,
                             notes: notes + parsed.notes)
    }

    /// Write the selected conversations into ChatStore as brand-new sessions.
    /// `targetModel` picks which model the imported sessions continue with.
    static func importConversations(
        _ selected: [ImportedConversation],
        targetModel: ModelOption?,
        source: String
    ) async -> ChatImportResult {
        let store = ChatStore.shared

        // Resolve the target model id. If none was configured/picked, sessions
        // still get created (modelId = "") and can be rebound later in the UI.
        let sessionModelId = targetModel?.modelId ?? ""

        var result = ChatImportResult(importedSessions: 0, importedMessages: 0,
                                      skippedConversations: 0, notes: [])

        for convo in selected {
            guard !convo.messages.isEmpty else {
                result.skippedConversations += 1
                continue
            }

            // ImportedRole → MessageRole, folding `.other` into the next
            // user turn (a system preamble / tool note is not a chat bubble).
            var parts: [(MessageRole, String)] = []
            var pendingOther: [String] = []
            for m in convo.messages {
                switch m.role {
                case .other:
                    pendingOther.append(m.text)
                case .user:
                    let text = pendingOther.isEmpty ? m.text
                        : pendingOther.joined(separator: "\n\n") + "\n\n" + m.text
                    pendingOther = []
                    parts.append((.user, text))
                case .assistant:
                    parts.append((.assistant, m.text))
                }
            }
            _ = pendingOther   // trailing system text after the last turn: dropped
            guard !parts.isEmpty else {
                result.skippedConversations += 1
                continue
            }

            let session = await store.createSession(
                modelId: sessionModelId,
                title: "\(convo.title)（来自 \(convo.source)）",
                source: "import:\(source)"
            )

            let baseTime = convo.createdAt ?? Date()
            var raws: [RawMessage] = []
            var idx = 0
            for (role, text) in parts {
                idx += 1
                let raw = RawMessage(
                    id: UUID().uuidString,
                    sessionId: session.id,
                    role: role,
                    parts: [.text(text)],
                    createdAt: baseTime.addingTimeInterval(Double(idx) * 0.001),
                    tokenUsage: nil,
                    reasoningContent: nil
                )
                raws.append(raw)
            }
            await store.appendMessages(raws)

            // Bind the chosen model so the in-session picker shows it (mirrors
            // SessionModelPicker.bindToEntry).
            if let target = targetModel {
                let pstore = ProviderConfigStore.shared
                let source: SessionModelSource = .directEntry(modelEntryId: target.id)
                let binding = SessionModelBinding(
                    sessionId: session.id,
                    primarySource: source,
                    subModelSource: pstore.binding(for: session.id)?.subModelSource
                )
                pstore.setBinding(binding, for: session.id)
                NotificationCenter.default.post(
                    name: .sessionModelBindingChanged, object: nil,
                    userInfo: ["sessionId": session.id]
                )
            }

            result.importedSessions += 1
            result.importedMessages += raws.count
        }

        if result.importedSessions == 0, !selected.isEmpty {
            result.notes.append("没有可导入的会话（全部为空）")
        }
        return result
    }

    // MARK: - Errors & utilities

    enum ImportError: LocalizedError {
        case unreadable(String)
        case unreadableZip(String)

        var errorDescription: String? {
            switch self {
            case .unreadable(let m): return m
            case .unreadableZip(let m): return "解压 zip 失败：\(m)"
            }
        }
    }

    private static func isZipMagic(at url: URL) -> Bool {
        guard let h = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? h.close() }
        let head = (try? h.readData(ofLength: 4)) ?? Data()
        return head.prefix(2) == Data([0x50, 0x4B])
    }

    private static func dedupByID(_ convos: [ImportedConversation]) -> [ImportedConversation] {
        var seen = Set<String>(); var out: [ImportedConversation] = []
        for c in convos where c.displayCount > 0 {
            if seen.insert(c.id).inserted { out.append(c) }
        }
        return out
    }
}
