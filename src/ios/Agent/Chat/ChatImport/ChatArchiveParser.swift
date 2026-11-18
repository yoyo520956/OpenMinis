//
//  ChatArchiveParser.swift
//  OpenMinis fork — import chat history from other AI apps
//
//  PURE Foundation archive parser. No UIKit, no app-type, no zip dependency —
//  so it unit-tests standalone (`swift ChatArchiveParser.swift`).
//
//  It parses DATA bytes in these flavors (auto-detected from the head):
//    1. ChatGPT export  — items with `mapping` + `title` (zip's conversations.json
//                         is a JSON array of these; old export = JSONL of these).
//    2. Claude/Anthropic — top-level array of conversations with `chat_messages`
//                          + `uuid`/`name`.
//    3. Grok/xAI       — `{"conversations":[...]}` wrapper or flat
//                         conversation with `responses`/`messages`.
//    4. OpenAI Chat-Completions — `[{"role","content"}]` or `{"messages":[...]}`.
//    5. DeepSeek / Doubao / generic JSON — object with `messages`/`conversations`.
//    6. Plain Markdown / text transcript — alternating role markers
//                         ("## 用户"/"## 助手"/"Human:"/"Assistant:" …).
//
//  ZIP handling (ChatGPT/Claude official exports ship as .zip) is NOT here —
//  the service layer extracts the zip and feeds each inner .json/.jsonl to
//  `parse(data:fileName:)`. Keeps this file dependency-free.
//
//  Output: [ImportedConversation] → ImportedMessage(role, text, ts).
//  ChatImportService maps roles to the app's MessageRole and writes to ChatStore.
//

import Foundation

// MARK: - Normalized intermediate types (parser output)

enum ImportedRole: Equatable {
    case user
    case assistant
    /// Present in the source but not user/assistant (e.g. a "system" preamble).
    /// The service folds it into the next user message rather than a bare bubble.
    case other
}

struct ImportedMessage: Equatable {
    let role: ImportedRole
    let text: String
    let createdAt: Date?
}

struct ImportedConversation: Identifiable, Equatable {
    let id: String
    var title: String
    /// Human-readable source name ("ChatGPT", "Claude", "Grok/xAI", "DeepSeek",
    /// "Doubao", "OpenAI 风格", "Markdown").
    var source: String
    /// Model slug reported by the source, if any (e.g. "gpt-4o", "claude-3-5-sonnet").
    var sourceModel: String?
    var createdAt: Date?
    var messages: [ImportedMessage]

    var messageCount: Int { messages.count }
    /// Number of user/assistant turns (what will actually be imported).
    var displayCount: Int { messages.filter { $0.role != .other }.count }
}

struct ParsedArchive {
    var source: String                 // dominant detected format label
    var conversations: [ImportedConversation]
    /// Non-fatal warnings (e.g. unparseable blocks, dropped lines).
    var notes: [String]

    var isEmpty: Bool { conversations.isEmpty }
}

// MARK: - Parser entry point (pure, testable)

enum ChatArchiveParser {

    /// Parse one DATA blob (one inner file of a zip, or a standalone
    /// .json/.jsonl/.md/.txt). Auto-detects the flavor from the head.
    static func parse(data: Data, fileName: String) -> ParsedArchive {
        var notes: [String] = []
        guard let text = String(data: data, encoding: .utf8) else {
            return ParsedArchive(source: "unknown", conversations: [],
                                 notes: ["文件不是 UTF-8 文本（可能是二进制）"])
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ParsedArchive(source: "empty", conversations: [], notes: notes)
        }

        if trimmed.hasPrefix("[") || trimmed.hasPrefix("{") {
            return parseJSON(trimmed, fileName: fileName, notes: &notes)
        }
        if looksLikeJSONL(trimmed) {
            return parseJSONL(trimmed, fileName: fileName, notes: &notes)
        }
        let md = parseMarkdown(trimmed, sourceName: inferSource(from: fileName), notes: &notes)
        return ParsedArchive(source: md.source, conversations: md.conversations,
                             notes: notes + md.notes)
    }

    // MARK: - JSON (top-level array or object)

    private static func parseJSON(_ json: String, fileName: String,
                                  notes: inout [String]) -> ParsedArchive {
        guard let root = try? JSONSerialization.jsonObject(with: Data(json.utf8)),
              let root = root as? Any else {
            notes.append("JSON 解析失败（格式不合法或被截断）")
            return ParsedArchive(source: "JSON", conversations: [], notes: notes)
        }
        switch root {
        case let arr as [Any]:
            return parseJSONArray(arr, notes: &notes)
        case let dict as [String: Any]:
            // Wrapper shapes.
            if let convos = dict["conversations"] as? [Any], !convos.isEmpty {
                return parseJSONArray(convos, notes: &notes)   // Grok wrapper
            }
            if let msgs = dict["messages"] as? [Any], !msgs.isEmpty {
                let c = singleConversation(fromDict: dict, messages: msgs,
                                           source: "OpenAI 风格", notes: &notes)
                return ParsedArchive(source: c.source,
                                      conversations: c.displayCount > 0 ? [c] : [],
                                      notes: notes)
            }
            if dict["chat_messages"] != nil || dict["mapping"] != nil || dict["responses"] != nil {
                let c = singleConversation(fromDict: dict, messages: nil,
                                           source: "JSON", notes: &notes)
                return ParsedArchive(source: c.source,
                                     conversations: [c].filter { $0.displayCount > 0 },
                                     notes: notes)
            }
            notes.append("JSON 对象结构未识别（缺少 mapping/chat_messages/responses/messages）")
            return ParsedArchive(source: "JSON", conversations: [], notes: notes)
        default:
            notes.append("JSON 顶层不是数组或对象")
            return ParsedArchive(source: "JSON", conversations: [], notes: notes)
        }
    }

    private static func parseJSONArray(_ items: [Any], notes: inout [String]) -> ParsedArchive {
        var out: [ImportedConversation] = []
        for item in items {
            guard let dict = item as? [String: Any] else { continue }
            if dict["mapping"] != nil {                                   // ChatGPT
                out.append(parseChatGPT(dict))
            } else if dict["chat_messages"] != nil {                       // Claude/Anthropic
                out.append(parseClaude(dict))
            } else if dict["responses"] != nil || dict["conversation"] != nil {
                out.append(parseGrok(dict))                                // Grok/xAI
            } else if dict["messages"] != nil {                             // OpenAI/generic
                out.append(singleConversation(fromDict: dict,
                                               messages: dict["messages"] as? [Any],
                                               source: "OpenAI 风格", notes: &notes))
            } else {
                let c = singleConversation(fromDict: dict, messages: nil,
                                           source: "JSON", notes: &notes)
                if c.displayCount > 0 { out.append(c) }
            }
        }
        return ParsedArchive(source: dominantSource(out),
                             conversations: dedup(out), notes: notes)
    }

    // MARK: - ChatGPT (mapping + title)

    private static func parseChatGPT(_ dict: [String: Any]) -> ImportedConversation {
        let id = str(dict["id"]) ?? str(dict["conversation_id"]) ?? UUID().uuidString
        let title = str(dict["title"]) ?? "ChatGPT 会话"
        var modelSlug: String? = nil
        if let model = dict["model"] as? [String: Any] { modelSlug = str(model["slug"]) ?? str(model["id"]) }
        else if let m = dict["model_slug"] as? String { modelSlug = m }

        var msgs: [ImportedMessage] = []
        if let mapping = dict["mapping"] as? [String: Any] {
            for (_, nodeRaw) in mapping {
                guard let node = nodeRaw as? [String: Any],
                      let message = node["message"] as? [String: Any] else { continue }
                let roleRaw = ((message["author"] as? [String: Any])?["role"] as? String) ?? ""
                let role = normalizeRole(roleRaw)
                let text = extractChatGPTText(message["content"] as? [String: Any])
                guard !text.isEmpty else { continue }
                let ts = dateFromUnix(message["create_time"] ?? message["update_time"])
                msgs.append(ImportedMessage(role: role, text: text, createdAt: ts))
            }
        }
        sortByTime(&msgs)
        return ImportedConversation(id: id, title: title, source: "ChatGPT",
                                    sourceModel: modelSlug,
                                    createdAt: dateFromUnix(dict["create_time"]),
                                    messages: msgs)
    }

    /// ChatGPT `content`: {"parts": ["a","b"], "content_type":"text"} or {"content":"..."}.
    private static func extractChatGPTText(_ content: [String: Any]?) -> String {
        guard let content else { return "" }
        if let parts = content["parts"] as? [Any] {
            let pieces = parts.compactMap { p -> String? in
                switch p {
                case let s as String: return s
                case let d as [String: Any]:
                    return str(d["text"]) ?? str(d["content"])
                default: return nil
                }
            }
            if !pieces.isEmpty { return pieces.joined(separator: "\n") }
        }
        if let c = content["content"] as? String { return c }
        return ""
    }

    // MARK: - Claude / Anthropic (chat_messages)

    private static func parseClaude(_ dict: [String: Any]) -> ImportedConversation {
        let id = str(dict["uuid"]) ?? str(dict["id"]) ?? UUID().uuidString
        let title = str(dict["name"]) ?? str(dict["title"]) ?? "Claude 会话"
        var modelSlug: String? = nil
        if let model = dict["model"] as? [String: Any] { modelSlug = str(model["id"]) }

        var msgs: [ImportedMessage] = []
        if let chatMessages = dict["chat_messages"] as? [Any] {
            for raw in chatMessages {
                guard let m = raw as? [String: Any] else { continue }
                let sender = (str(m["sender"]) ?? "").lowercased()
                let role: ImportedRole = (sender == "human" || sender == "user")
                    ? .user : .assistant
                let text = extractClaudeText(m)
                guard !text.isEmpty else { continue }
                let ts = dateFromISO8601(str(m["created_at"]))
                msgs.append(ImportedMessage(role: role, text: text, createdAt: ts))
            }
        }
        sortByTime(&msgs)
        return ImportedConversation(id: id, title: title, source: "Claude",
                                    sourceModel: modelSlug,
                                    createdAt: dateFromISO8601(str(dict["created_at"])),
                                    messages: msgs)
    }

    /// Claude content: String, or array of {type:"text", text}.
    private static func extractClaudeText(_ m: [String: Any]) -> String {
        if let c = m["content"] as? [Any] {
            let pieces = c.compactMap { item -> String? in
                guard let d = item as? [String: Any],
                      (str(d["type"]) ?? "") == "text",
                      let t = d["text"] as? String else { return nil }
                return t
            }
            if !pieces.isEmpty { return pieces.joined(separator: "\n") }
        }
        if let t = m["text"] as? String { return t }
        if let c = m["content"] as? String { return c }
        return ""
    }

    // MARK: - Grok / xAI

    private static func parseGrok(_ item: [String: Any]) -> ImportedConversation {
        // Wrapped: {conversation:{...}, responses:[...]}
        if let conv = item["conversation"] as? [String: Any] {
            let id = str(conv["id"]) ?? UUID().uuidString
            let title = str(conv["title"]) ?? "Grok 会话"
            var msgs: [ImportedMessage] = []
            if let responses = item["responses"] as? [Any] {
                for rw in responses {
                    guard let r = rw as? [String: Any] else { continue }
                    let inner = (r["response"] as? [String: Any]) ?? r
                    let sender = (str(inner["sender"]) ?? "").lowercased()
                    let role: ImportedRole = (sender == "human" || sender == "user")
                        ? .user : .assistant
                    let text = extractGrokText(inner["message"])
                    guard !text.isEmpty else { continue }
                    let ts = extractGrokDate(inner["create_time"])
                    msgs.append(ImportedMessage(role: role, text: text, createdAt: ts))
                }
            }
            sortByTime(&msgs)
            return ImportedConversation(id: id, title: title, source: "Grok/xAI",
                                        sourceModel: nil,
                                        createdAt: extractGrokDate(conv["create_time"]),
                                        messages: msgs)
        }
        // Flat: {messages:[...]} or {id, text}
        var msgs: [ImportedMessage] = []
        if let messages = item["messages"] as? [Any] {
            for mw in messages {
                guard let m = mw as? [String: Any] else { continue }
                let sender = (str(m["sender"]) ?? "user").lowercased()
                let role: ImportedRole = (sender == "assistant" || sender == "ai")
                    ? .assistant : .user
                let text = extractGrokText(m["message"] ?? m["text"])
                guard !text.isEmpty else { continue }
                let ts = extractGrokDate(m["create_time"])
                msgs.append(ImportedMessage(role: role, text: text, createdAt: ts))
            }
        }
        sortByTime(&msgs)
        return ImportedConversation(id: str(item["id"]) ?? UUID().uuidString,
                                    title: str(item["title"]) ?? "Grok 会话",
                                    source: "Grok/xAI", sourceModel: nil,
                                    createdAt: nil, messages: msgs)
    }

    /// Grok message body: String, Array of chunks, or a dict.
    private static func extractGrokText(_ v: Any?) -> String {
        switch v {
        case let s as String: return s
        case let arr as [Any]:
            return arr.compactMap { chunk -> String? in
                if let d = chunk as? [String: Any] { return str(d["text"]) ?? str(d["content"]) }
                if let s = chunk as? String { return s }
                return nil
            }.joined(separator: "\n")
        case let d as [String: Any]:
            return str(d["text"]) ?? str(d["content"]) ?? ""
        default:
            return ""
        }
    }

    /// Grok timestamps: {"$date":{"$numberLong":"..."}}, a number (ms or s),
    /// or an ISO string.
    private static func extractGrokDate(_ v: Any?) -> Date? {
        if let d = v as? [String: Any] {
            if let date = d["$date"] as? [String: Any],
               let ms = str(date["$numberLong"]) ?? str(date["$numberDouble"]) {
                return dateFromMillis(ms)
            }
        }
        if let n = v as? NSNumber {
            let ms = n.int64Value
            return ms > 10_000_000_000 ? dateFromMillis("\(ms)") : dateFromUnix("\(ms)")
        }
        if let s = v as? String {
            return dateFromMillis(s) ?? dateFromISO8601(s)
        }
        return nil
    }

    // MARK: - Generic "messages" single conversation

    private static func singleConversation(fromDict dict: [String: Any], messages: [Any]?,
                                           source: String, notes: inout [String]) -> ImportedConversation {
        let items = messages ?? (dict["messages"] as? [Any]) ?? []
        // Fall through to the specialized parsers when this dict is really one
        // of those shapes and we were called with no messages.
        if items.isEmpty {
            if dict["mapping"] != nil { return parseChatGPT(dict) }
            if dict["chat_messages"] != nil { return parseClaude(dict) }
            if dict["responses"] != nil || dict["conversation"] != nil { return parseGrok(dict) }
            notes.append("该会话缺少可解析的消息字段")
        }
        var msgs: [ImportedMessage] = []
        for raw in items {
            guard let m = raw as? [String: Any] else { continue }
            let role = normalizeRole(str(m["role"]) ?? "user")
            let text = extractOpenAIText(m["content"] ?? m["text"])
            guard !text.isEmpty else { continue }
            let ts = dateFromMillis(str(m["created_at"] ?? m["timestamp"]))
                ?? dateFromISO8601(str(m["created_at"] ?? m["timestamp"]))
            msgs.append(ImportedMessage(role: role, text: text, createdAt: ts))
        }
        sortByTime(&msgs)
        let title = str(dict["title"]) ?? str(dict["name"])
            ?? firstUserText(msgs).map { String($0.prefix(40)) } ?? "导入会话"
        let id = str(dict["id"]) ?? str(dict["uuid"]) ?? UUID().uuidString
        return ImportedConversation(id: id, title: title, source: source,
                                    sourceModel: str(dict["model"]),
                                    createdAt: dateFromISO8601(str(dict["created_at"])),
                                    messages: msgs)
    }

    /// OpenAI content: String, or [{type:"text",text:"..."}].
    private static func extractOpenAIText(_ v: Any?) -> String {
        switch v {
        case let s as String: return s
        case let arr as [Any]:
            return arr.compactMap { item -> String? in
                guard let d = item as? [String: Any] else { return nil }
                return str(d["text"]) ?? str(d["content"])
            }.joined(separator: "\n")
        default: return ""
        }
    }

    // MARK: - JSONL (newline-delimited)

    private static func parseJSONL(_ text: String, fileName: String,
                                   notes: inout [String]) -> ParsedArchive {
        let lines = text.split(separator: "\n").map(String.init)
        var groups: [String: [ImportedMessage]] = [:]
        var titles: [String: String] = [:]
        var sources: [String: String] = [:]
        var order: [String] = []

        for lineRaw in lines {
            let line = lineRaw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty,
                  let d = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            else { continue }

            // Bucket key: prefer an explicit conversation/thread id.
            let key = str(d["conversation_id"]) ?? str(d["thread_id"])
                ?? str(d["conversationId"]) ?? "default"

            if d["mapping"] != nil {                     // ChatGPT JSONL
                let convo = parseChatGPT(d)
                let k = convo.id
                if sources[k] == nil { order.append(k); sources[k] = "ChatGPT"; titles[k] = convo.title }
                groups[k] = convo.messages
                continue
            }
            if d["type"] != nil, let message = d["message"] as? [String: Any] {
                // Claude Code style JSONL: {type:"user"/"assistant", message:{...}}
                let role = normalizeRole(str(d["type"]) ?? "user")
                let text = extractClaudeText(message)
                if !text.isEmpty {
                    groups[key, default: []].append(ImportedMessage(
                        role: role, text: text,
                        createdAt: dateFromISO8601(str(message["created_at"]) ?? str(d["timestamp"]))))
                }
                if sources[key] == nil {
                    titles[key] = str(d["title"]) ?? fileName
                    sources[key] = "Claude"
                    order.append(key)
                }
                continue
            }
            // Generic line: {role, content|text}.
            if d["role"] != nil {
                let role = normalizeRole(str(d["role"]) ?? "user")
                let text = extractOpenAIText(d["content"] ?? d["text"])
                if !text.isEmpty {
                    groups[key, default: []].append(ImportedMessage(
                        role: role, text: text,
                        createdAt: dateFromISO8601(str(d["created_at"] ?? d["timestamp"]))))
                }
                if sources[key] == nil {
                    titles[key] = fileName.replacingOccurrences(of: ".", with: " ")
                    sources[key] = "通用 JSONL"
                    order.append(key)
                }
            }
        }

        var out: [ImportedConversation] = []
        for key in order {
            let messages = (groups[key] ?? []).sorted {
                ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast)
            }
            guard !messages.isEmpty else { continue }
            out.append(ImportedConversation(
                id: key, title: titles[key] ?? "JSONL 会话",
                source: sources[key] ?? "通用", sourceModel: nil,
                createdAt: messages.first?.createdAt, messages: messages))
        }
        return ParsedArchive(source: dominantSource(out), conversations: out, notes: notes)
    }

    private static func looksLikeJSONL(_ text: String) -> Bool {
        let first = text.split(separator: "\n").first.map(String.init) ?? ""
        let t = first.trimmingCharacters(in: .whitespaces)
        return t.hasPrefix("{") && text.contains("\n{")
    }

    // MARK: - Markdown / plain transcript

    private static func parseMarkdown(_ text: String, sourceName: String,
                                     notes: inout [String])
        -> (source: String, conversations: [ImportedConversation], notes: [String]) {
        // A marker line is a short line that names a role: "## 用户", "Human:",
        // "Assistant:", "## DeepSeek", "**用户**:" etc.
        let userMarkers = ["用户", "user", "human", "你", "question", "q", "客户", "我"]
        let assistantMarkers = ["助手", "assistant", "ai", "model", "deepseek", "豆包",
                                "gpt", "chatgpt", "claude", "gemini", "grok", "回答",
                                "答案", "客服", "ai 助手"]

        func markerRole(_ line: String) -> ImportedRole? {
            let stripped = line.trimmingCharacters(in: .whitespaces)
            guard stripped.count < 40 else { return nil }
            var clean = stripped.lowercased()
            while clean.hasPrefix("#") { clean.removeFirst() }
            clean = clean.trimmingCharacters(in: .whitespaces)
            // "**用户**:" / "用户:" — strip bold markers and colon
            clean = clean.replacingOccurrences(of: "*", with: "")
            clean = clean.replacingOccurrences(of: "：", with: ":")
            clean = clean.replacingOccurrences(of: ":", with: "")
            clean = clean.trimmingCharacters(in: .whitespaces)
            if clean.isEmpty { return nil }
            if userMarkers.contains(clean) { return .user }
            if assistantMarkers.contains(clean) { return .assistant }
            return nil
        }

        struct Block { var role: ImportedRole; var text: String }
        var blocks: [Block] = []
        var currentRole: ImportedRole?
        var pending = ""

        func flush() {
            if let r = currentRole {
                let t = pending.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { blocks.append(Block(role: r, text: t)) }
            }
            currentRole = nil
            pending = ""
        }

        for line in text.split(separator: "\n").map(String.init) {
            if let r = markerRole(line) {
                flush()
                currentRole = r
            } else if currentRole != nil {
                pending += line + "\n"
            }
        }
        flush()

        guard !blocks.isEmpty else {
            notes.append("Markdown 未识别到 用户/助手 标记，无法解析（可用 "## 用户"/"## 助手"、"Human:"/"Assistant:" 或 "**用户**" 等标记）")
            return (sourceName, [], notes)
        }

        // Merge consecutive same-role blocks into single turns.
        var msgs: [ImportedMessage] = []
        var lastRole = blocks[0].role
        var buf = blocks[0].text
        for b in blocks.dropFirst() {
            if b.role == lastRole {
                buf += "\n" + b.text
            } else {
                msgs.append(ImportedMessage(role: lastRole, text: buf, createdAt: nil))
                buf = b.text
                lastRole = b.role
            }
        }
        msgs.append(ImportedMessage(role: lastRole, text: buf, createdAt: nil))

        let title = firstUserText(msgs).map { String($0.prefix(40)) } ?? "Markdown 会话"
        let convo = ImportedConversation(id: UUID().uuidString, title: title,
                                         source: sourceName, sourceModel: nil,
                                         createdAt: nil, messages: msgs)
        return ("Markdown", [convo], notes)
    }

    // MARK: - Helpers

    private static func normalizeRole(_ raw: String) -> ImportedRole {
        let l = raw.lowercased()
        if l == "user" || l == "human" || l == "you" || l == "用户" { return .user }
        if l == "assistant" || l == "ai" || l == "model" || l == "bot"
            || l == "助手" || l == "deepseek" || l == "豆包" { return .assistant }
        if l == "system" || l == "developer" { return .other }
        return .other
    }

    private static func sortByTime(_ msgs: inout [ImportedMessage]) {
        msgs.sort { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) }
    }

    private static func dominantSource(_ convos: [ImportedConversation]) -> String {
        var counts: [String: Int] = [:]
        for c in convos { counts[c.source, default: 0] += 1 }
        return counts.max { $0.value < $1.value }?.key ?? "未知"
    }

    /// Same thread can appear twice (zip + standalone json).
    private static func dedup(_ convos: [ImportedConversation]) -> [ImportedConversation] {
        var seen = Set<String>(); var out: [ImportedConversation] = []
        for c in convos where c.displayCount > 0 {
            if seen.insert(c.id).inserted { out.append(c) }
        }
        return out
    }

    private static func firstUserText(_ msgs: [ImportedMessage]) -> String? {
        msgs.first(where: { $0.role == .user })?.text
    }

    private static func inferSource(from fileName: String) -> String {
        let l = fileName.lowercased()
        if l.contains("doubao") || l.contains("豆包") { return "Doubao(豆包)" }
        if l.contains("deepseek") { return "DeepSeek" }
        if l.contains("grok") || l.contains("xai") { return "Grok/xAI" }
        if l.contains("claude") { return "Claude" }
        if l.contains("chatgpt") || l.contains("gpt") { return "ChatGPT" }
        return "Markdown"
    }

    // MARK: - Small value/JSON/date helpers (pure)

    private static func str(_ v: Any?) -> String? {
        (v as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    private static func dateFromUnix(_ v: Any?) -> Date? {
        let s: String?
        if let n = v as? NSNumber { s = String(n.int64Value) }
        else if let s0 = v as? String { s = s0 }
        else { s = nil }
        guard let s, let secs = Double(s) else { return nil }
        return Date(timeIntervalSince1970: secs > 10_000_000_000 ? secs / 1000 : secs)
    }

    private static func dateFromMillis(_ s: String) -> Date? {
        guard let v = Double(s) else { return nil }
        return Date(timeIntervalSince1970: (v > 10_000_000_000 ? v / 1000 : v))
    }

    private static func dateFromISO8601(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        let norm = s.replacingOccurrences(of: "Z", with: "+00:00")
        var dfm = ISO8601DateFormatter()
        dfm.formatOptions = [.withInternetDateTime, .parseFromDateTimeFormat]
        if let d = dfm.date(from: norm) { return d }
        dfm = ISO8601DateFormatter()
        return dfm.date(from: s)
    }
}
