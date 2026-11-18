//
//  ChatImportView.swift
//  OpenMinis fork — 导入其他 AI 的聊天记录
//
//  Settings → Backup & Restore → 「导入」 tab.
//  Flow: pick a file (zip/json/jsonl/md/txt) → auto-detect source
//  (ChatGPT / Claude / Grok/xAI / DeepSeek / 豆包 / 通用 / Markdown) →
//  preview conversations → choose target model → import into ChatStore.
//

import SwiftUI
import UniformTypeIdentifiers

private let importLogger = AppLogger(category: "ChatImport")

struct ChatImportView: View {
    var embedded = false

    @State private var parsed: ParsedArchive?
    @State private var selected: Set<String> = []
    @State private var isWorking = false
    @State private var statusText = ""
    @State private var showPicker = false
    @State private var errorText: String?
    @State private var result: ChatImportResult?
    @State private var fileName: String = ""

    // Model target (string tag: "default" or a ModelOption.id).
    @State private var modelOptions: [ChatImportService.ModelOption] = []
    @State private var chosenModelTag: String? = "default"
    @ObservedObject private var pstore = ProviderConfigStore.shared

    var body: some View {
        Form {
            if result == nil, parsed == nil {
                pickSection
            } else {
                if let parsed, result == nil {
                    previewSection(parsed)
                }
                if let result {
                    reportSection(result)
                }
            }
            if let errorText {
                Section {
                    Text(errorText)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
        }
        .modifier(StandaloneTitle(title: "导入聊天记录", active: !embedded))
        .fileImporter(isPresented: $showPicker,
                      allowedContentTypes: [UTType.json, UTType.zip,
                                            UTType.plainText, UTType.text,
                                            UTType.data],
                      allowsMultipleSelection: false) { res in
            switch res {
            case .success(let urls):
                if let url = urls.first { load(url) }
            case .failure(let error):
                errorText = error.localizedDescription
            }
        }
        .onAppear {
            modelOptions = ChatImportService.modelOptions()
        }
    }

    // MARK: - Pick file

    private var pickSection: some View {
        Section("导入其他 AI 的聊天记录") {
            LabeledContent("支持来源") {
                Text("ChatGPT · Claude · Grok/xAI · DeepSeek · 豆包 · 通用 JSON/JSONL/Markdown")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button("选择文件（.zip / .json / .jsonl / .md / .txt）") {
                showPicker = true
            }
        }
    }

    private func load(_ url: URL) {
        errorText = nil
        result = nil
        parsed = nil
        isWorking = true
        statusText = "解析中…"
        fileName = url.lastPathComponent
        Task {
            do {
                let archive = try await Task.detached {
                    try ChatImportService.parseExport(url: url)
                }.value
                if archive.isEmpty {
                    errorText = "未识别到可导入的对话（\(archive.notes.joined(separator: "；"))）"
                } else {
                    parsed = archive
                    selected = Set(archive.conversations.compactMap {
                        $0.displayCount > 0 ? $0.id : nil
                    })
                }
            } catch {
                errorText = error.localizedDescription
            }
            isWorking = false
            statusText = ""
        }
    }

    // MARK: - Preview

    private func previewSection(_ archive: ParsedArchive) -> some View {
        Section("识别结果（\(archive.conversations.count) 个会话 · 来源：\(archive.source)）") {
            ForEach(archive.conversations) { convo in
                DisclosureGroup {
                    modelPicker
                    LabeledContent("消息数") {
                        Text("\(convo.displayCount)").font(.caption).foregroundStyle(.secondary)
                    }
                    if let m = convo.sourceModel {
                        LabeledContent("原模型") { Text(m).font(.caption).foregroundStyle(.secondary) }
                    }
                } label: {
                    Label(convo.title, systemImage: selected.contains(convo.id) ? "checkmark.circle.fill" : "circle")
                        .lineLimit(2)
                }
                .contentShape(Rectangle())
                .onTapGesture { toggle(convo.id) }
            }
            if !archive.notes.isEmpty {
                Text(archive.notes.joined(separator: "\n"))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            importButton(archive)
        }
    }

    private func toggle(_ id: String) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    /// Target model picker for the imported sessions.
    private var modelPicker: some View {
        Section("目标模型") {
            if modelOptions.isEmpty {
                Text("未配置任何模型。导入的会话先不绑定模型，之后可在会话内选择。")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Picker("导入后会话使用的模型", selection: $chosenModelTag) {
                    Text("默认模型").tag("default")
                    ForEach(modelOptions) { opt in
                        Text(opt.label).tag(opt.id)
                    }
                }
                .font(.caption)
            }
        }
    }

    private func resolvedTargetModel() -> ChatImportService.ModelOption? {
        guard let tag = chosenModelTag else { return nil }
        if tag == "default" {
            return ChatImportService.defaultModelOption()
        }
        return modelOptions.first(where: { $0.id == tag })
    }

    private func importButton(_ archive: ParsedArchive) -> some View {
        Button {
            runImport(archive)
        } label: {
            HStack {
                Text("导入 \(selected.count) 个会话")
                if isWorking { ProgressView() }
            }
        }
        .disabled(selected.isEmpty || isWorking)
    }

    private func runImport(_ archive: ParsedArchive) {
        let chosen = archive.conversations.filter { selected.contains($0.id) }
        let target = resolvedTargetModel()
        isWorking = true
        Task {
            let res = await ChatImportService.importConversations(chosen,
                                                                  targetModel: target,
                                                                  source: archive.source)
            result = res
            parsed = nil
            isWorking = false
            importLogger.info("[ChatImport] imported \(res.importedSessions) sessions, \(res.importedMessages) messages")
        }
    }

    // MARK: - Report

    private func reportSection(_ r: ChatImportResult) -> some View {
        Section("导入完成") {
            LabeledContent("导入会话") { Text("\(r.importedSessions)").bold() }
            LabeledContent("导入消息") { Text("\(r.importedMessages)") }
            if r.skippedConversations > 0 {
                LabeledContent("跳过（空会话）") { Text("\(r.skippedConversations)") }
            }
            if !r.notes.isEmpty {
                Text(r.notes.joined(separator: "\n")).font(.caption).foregroundStyle(.secondary)
            }
            Button("继续导入其他文件") {
                result = nil
                parsed = nil
                selected = []
                errorText = nil
                fileName = ""
            }
        }
    }
}

// MARK: - Preview: conversation list with checkboxes

struct ChatImportPreviewRow: View {
    let convo: ImportedConversation
    let isSelected: Bool
    let onToggle: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Button(action: onToggle) {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .foregroundStyle(isSelected ? .accentColor : .secondary)
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 2) {
                Text(convo.title).lineLimit(2)
                HStack(spacing: 6) {
                    Text(convo.source).font(.caption2).foregroundStyle(.secondary)
                    Text("\(convo.displayCount) 条").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggle)
    }
}
