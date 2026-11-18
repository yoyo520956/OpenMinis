#!/usr/bin/env swift
//
//  ChatImportParserStandaloneTest.swift
//  Run: `swift ChatImportParserStandaloneTest.swift`
//
//  Validates the SHIPPING ChatArchiveParser.swift (the real file from the
//  repo, not a copy): it appends a `main` test body to the parser source,
//  compiles the combined file with `swift`, and runs it. Fails loudly if the
//  parser file can no longer be found or a fixture stops parsing.
//

import Foundation

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write("❌ \(msg)\n".data(using: .utf8)!)
    exit(1)
}

// Repo root: this file lives at <root>/src/ios/MinisTests/Standalone/.
let root = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()  // Standalone
    .deletingLastPathComponent()  // MinisTests
    .deletingLastPathComponent()  // ios
    .deletingLastPathComponent()  // src
let parserPath = root.appendingPathComponent("src/ios/Agent/Chat/ChatImport/ChatArchiveParser.swift")
guard let parserSrc = try? String(contentsOf: parserPath, encoding: .utf8) else {
    fail("shipped parser not found at \(parserPath.path)")
}

let testMain = """
// ---- test body appended to the shipping parser source ----
var failures = 0
func check(_ label: String, _ cond: Bool) {
    if cond { print("  ✅ \\(label)") }
    else { print("  ❌ \\(label)"); failures += 1 }
}

// 1. ChatGPT: top-level array, one conversation with mapping.
let chatgpt = Data("""
[
  {
    "id": "conv-1",
    "title": "帮我写一个排序",
    "create_time": 1700000000,
    "model": {"slug": "gpt-4o"},
    "mapping": {
      "a1": {"message": {"author": {"role": "user"},
             "content": {"parts": ["帮我写一个快排"], "content_type": "text"},
             "create_time": 1700000001}},
      "a2": {"message": {"author": {"role": "assistant"},
             "content": {"parts": ["def quicksort(a): ..."], "content_type": "text"},
             "create_time": 1700000005}},
      "a3": {"message": {"author": {"role": "user"},
             "content": {"parts": ["再写个归并"]}, "create_time": 1700000010}},
      "a4": {"message": {"author": {"role": "assistant"},
             "content": {"parts": ["def merge_sort(a): ..."]}, "create_time": 1700000015}}
    }
  }
]
""".utf8)
let r1 = ChatArchiveParser.parse(data: chatgpt, fileName: "chatgpt-export.json")
check("chatgpt: 1 conversation", r1.conversations.count == 1)
let c1 = r1.conversations.first
check("chatgpt: title", c1?.title == "帮我写一个排序")
check("chatgpt: 4 messages", c1?.displayCount == 4)
check("chatgpt: first is user", c1?.messages.first?.role == .user)
check("chatgpt: text extracted", c1?.messages.first?.text == "帮我写一个快排")
check("chatgpt: source label", c1?.source == "ChatGPT")
check("chatgpt: model slug", c1?.sourceModel == "gpt-4o")
check("chatgpt: sorted by time", (c1?.messages.map { $0.createdAt ?? .distantPast } ?? [])
      .sorted { $0 < $1 } == c1?.messages.map { $0.createdAt ?? .distantPast } ?? [])

// 2. Claude: top-level array with chat_messages.
let claude = Data("""
[
  {
    "uuid": "proj-1",
    "name": "Claude 会话",
    "created_at": "2024-01-01T00:00:00Z",
    "chat_messages": [
      {"sender": "human", "content": [{"type": "text", "text": "你好"}],
       "created_at": "2024-01-01T00:00:01Z"},
      {"sender": "assistant", "content": [{"type": "text", "text": "你好，有什么可以帮你？"}],
       "created_at": "2024-01-01T00:00:05Z"},
      {"sender": "human", "text": "再写个函数", "created_at": "2024-01-01T00:00:09Z"}
    ]
  }
]
""".utf8)
let r2 = ChatArchiveParser.parse(data: claude, fileName: "claude-export.json")
check("claude: 1 conversation", r2.conversations.count == 1)
check("claude: 3 messages", r2.conversations.first?.displayCount == 3)
check("claude: text via content array", r2.conversations.first?.messages.first?.text == "你好")
check("claude: source label", r2.conversations.first?.source == "Claude")

// 3. Grok: {"conversations":[{conversation, responses[$date/$numberLong]}]}.
let grok = Data("""
{
  "conversations": [
    {
      "conversation": {"id": "g1", "title": "grok 会话", "create_time": {"$date": {"$numberLong": "1700000000000"}}},
      "responses": [
        {"response": {"sender": "human", "message": "hi",
                      "create_time": {"$date": {"$numberLong": "1700000001000"}}}},
        {"response": {"sender": "grok", "message": "hello!",
                      "create_time": {"$date": {"$numberLong": "1700000002000"}}}}
      ]
    }
  ]
}
""".utf8)
let r3 = ChatArchiveParser.parse(data: grok, fileName: "grok-export.json")
check("grok: 1 conversation", r3.conversations.count == 1)
check("grok: 2 messages", r3.conversations.first?.displayCount == 2)
check("grok: $date parsed", r3.conversations.first?.messages.first?.createdAt != nil)
check("grok: source label", r3.conversations.first?.source == "Grok/xAI")

// 4. OpenAI style: {"messages":[{role, content}]}.
let openai = Data("""
{"title": "OpenAI 风格", "model": "gpt-4o-mini",
 "messages": [
   {"role": "user", "content": "你好"},
   {"role": "assistant", "content": [{"type": "text", "text": "你好！"}]}
 ]}
""".utf8)
let r4 = ChatArchiveParser.parse(data: openai, fileName: "openai.json")
check("openai: 1 conversation", r4.conversations.count == 1)
check("openai: 2 messages", r4.conversations.first?.displayCount == 2)
check("openai: content array text", r4.conversations.first?.messages.last?.text == "你好！")

// 5. DeepSeek community JSON: {"title","created_at","messages":[{role, content}]}.
let deepseek = Data("""
{"title": "deepseek 对话", "created_at": "2024-02-02T08:00:00Z",
 "messages": [
   {"role": "user", "content": "解释一下 TCP"},
   {"role": "assistant", "content": "TCP 是可靠传输…"}
 ]}
""".utf8)
let r5 = ChatArchiveParser.parse(data: deepseek, fileName: "deepseek-chat.json")
check("deepseek: 1 conversation", r5.conversations.count == 1)
check("deepseek: 2 messages", r5.conversations.first?.displayCount == 2)

// 6. Generic JSONL: one line per {role, content}.
let jsonl = Data("""
{"role":"user","content":"问题一","created_at":"2024-03-03T00:00:01Z"}
{"role":"assistant","content":"答案一","created_at":"2024-03-03T00:00:05Z"}
{"role":"user","content":"问题二","created_at":"2024-03-03T00:00:09Z"}
""".utf8)
let r6 = ChatArchiveParser.parse(data: jsonl, fileName: "history.jsonl")
check("jsonl: 1 conversation (default bucket)", r6.conversations.count == 1)
check("jsonl: 3 messages", r6.conversations.first?.displayCount == 3)

// 7. ChatGPT-style JSONL (mapping per line).
let cgptL = Data("""
{"id":"c1","title":"线1","mapping":{"n1":{"message":{"author":{"role":"user"},"content":{"parts":["a"]},"create_time":1700000001}}}}
{"id":"c2","title":"线2","mapping":{"n2":{"message":{"author":{"role":"user"},"content":{"parts":["b"]},"create_time":1700000002}}}}
""".utf8)
let r7 = ChatArchiveParser.parse(data: cgptL, fileName: "chatgpt.jsonl")
check("chatgpt jsonl: 2 conversations", r7.conversations.count == 2)

// 8. Markdown with ## 用户 / ## 助手.
let md = Data("""
# 豆包对话
## 用户
帮我翻译 hello
## 助手
hello 的翻译是“你好”。
## 用户
谢谢
## 助手
不客气～
""".utf8)
let r8 = ChatArchiveParser.parse(data: md, fileName: "doubao.md")
check("markdown: 1 conversation", r8.conversations.count == 1)
check("markdown: 4 turns", r8.conversations.first?.displayCount == 4)
check("markdown: first user text", r8.conversations.first?.messages.first?.text == "帮我翻译 hello")

// 9. Markdown with **用户** / **DeepSeek** bold markers.
let md2 = Data("""
**用户**：什么是 HTTP？
**DeepSeek**：HTTP 是超文本传输协议…
""".utf8)
let r9 = ChatArchiveParser.parse(data: md2, fileName: "ds.md")
check("markdown bold: 2 turns", r9.conversations.first?.displayCount == 2)

// 10. Garbage → empty with notes, never crash.
let bad = Data("this is not json or markdown at all\njust words", encoding: .utf8)!
let r10 = ChatArchiveParser.parse(data: bad, fileName: "x.txt")
check("garbage: 0 conversations", r10.conversations.isEmpty)

print(failures == 0 ? "ALL PASS" : "\(failures) FAILURES")
exit(failures == 0 ? 0 : 1)
"""

let combined = parserSrc + "\n" + testMain
let tmp = FileManager.default.temporaryDirectory
    .appendingPathComponent("ChatImportParserTest-\(UUID().uuidString).swift")
try! combined.write(to: tmp, atomically: true, encoding: .utf8)

let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
task.arguments = ["swift", tmp.path]
let pipe = Pipe()
task.standardOutput = pipe
task.standardError = pipe
try task.run()
task.waitUntilExit
let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
print(out)
try? FileManager.default.removeItem(at: tmp)

guard task.terminationStatus == 0 else {
    fail("parser self-test exited with status \(task.terminationStatus)")
}
print("✅ ChatImportParserStandaloneTest passed (shipped parser verified)")
