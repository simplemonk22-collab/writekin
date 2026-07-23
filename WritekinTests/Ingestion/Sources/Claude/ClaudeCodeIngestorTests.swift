import Testing
import Foundation
import GRDB
@testable import Writekin

struct ClaudeCodeIngestorTests {
    private func line(_ dict: [String: Any]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: dict), encoding: .utf8)!
    }

    @Test func parsesStringAndBlockUserMessages() {
        let transcript = [
            line(["type": "user", "uuid": "a", "sessionId": "s1",
                  "timestamp": "2026-06-12T18:23:13.897Z",
                  "message": ["role": "user", "content": "hey can you fix the sidebar"]]),
            line(["type": "user", "uuid": "b",
                  "message": ["role": "user",
                              "content": [["type": "text", "text": "second message here"]]]]),
        ].joined(separator: "\n")
        let messages = ClaudeCodeStore.userMessages(inTranscript: transcript)
        #expect(messages.count == 2)
        #expect(messages[0].text == "hey can you fix the sidebar")
        #expect(messages[0].sessionID == "s1")
        #expect(messages[0].timestamp != nil)
        #expect(messages[1].text == "second message here")
    }

    @Test func skipsEverythingThatIsNotTheUsersWriting() {
        let transcript = [
            // Tool result delivered as a user-role message.
            line(["type": "user", "uuid": "t",
                  "message": ["role": "user",
                              "content": [["type": "tool_result", "content": "build ok"]]]]),
            // Subagent (sidechain) traffic.
            line(["type": "user", "uuid": "s", "isSidechain": true,
                  "message": ["role": "user", "content": "subagent prompt"]]),
            // Slash command + harness artifacts.
            line(["type": "user", "uuid": "c",
                  "message": ["role": "user", "content": "<command-name>/compact</command-name>"]]),
            line(["type": "user", "uuid": "i",
                  "message": ["role": "user", "content": "[Request interrupted by user]"]]),
            // Non-user record types.
            line(["type": "assistant", "uuid": "x",
                  "message": ["role": "assistant", "content": "AI text"]]),
            line(["type": "mode", "mode": "normal"]),
            // Malformed line must not be fatal.
            "not json at all {",
            // The one real message.
            line(["type": "user", "uuid": "r",
                  "message": ["role": "user", "content": "the actual thing I typed"]]),
        ].joined(separator: "\n")
        let messages = ClaudeCodeStore.userMessages(inTranscript: transcript)
        #expect(messages.map(\.text) == ["the actual thing I typed"])
    }

    /// Claude Desktop agent-mode audit records use `session_id` and
    /// `_audit_timestamp` — same records otherwise.
    @Test func parsesDesktopAuditKeyVariants() {
        let transcript = line(["type": "user", "uuid": "d1",
                               "session_id": "3466153d",
                               "_audit_timestamp": "2026-02-09T21:55:30.944Z",
                               "message": ["role": "user",
                                           "content": "I need to pull out key terms from these docs"]])
        let messages = ClaudeCodeStore.userMessages(inTranscript: transcript)
        #expect(messages.count == 1)
        #expect(messages[0].sessionID == "3466153d")
        #expect(messages[0].timestamp != nil)
    }

    @Test func containsCodeDetectsFencesAndSymbolDensityButNotProse() {
        #expect(FilterPass.containsCode("here's the diff ```swift\nlet x = 1\n``` thoughts?"))
        #expect(FilterPass.containsCode(
            "func foo() { return bar(); } if (x == 1) { baz(); } else { qux(); } let y = z;"))
        #expect(!FilterPass.containsCode(
            "hey can you make the sidebar fade out when there is no compose model installed"))
        #expect(!FilterPass.containsCode("short {msg}"))
    }

    @Test func chatFilterRulesDropCodeAndPastes() throws {
        let db = try AppDatabase.inMemory()
        let prose12 = "please make the header simpler and move the gear to the right side"
        try seedChat(db, clean: "fix this: func a() { b(); } func c() { d(); } while (x == y) { z(); } done { ok };")
        try seedChat(db, clean: Array(repeating: "word", count: 301).joined(separator: " "))
        try seedChat(db, clean: prose12)
        try FilterPass(db: db).run()
        let byReason = try db.writer.read { try Item.fetchAll($0) }
            .map { ($0.dropReason, $0.state) }
        #expect(byReason[0].0 == "code_content")
        #expect(byReason[1].0 == "likely_paste")
        #expect(byReason[2].1 == "kept")
    }

    private func seedChat(_ db: AppDatabase, clean: String) throws {
        try db.writer.write { dbc in
            let sourceId: Int64
            if let existing = try Source.filter(Column("kind") == "claude_code").fetchOne(dbc) {
                sourceId = existing.id!
            } else {
                var source = Source(id: nil, kind: "claude_code", configJson: "{}", lastSyncedAt: nil)
                try source.insert(dbc)
                sourceId = source.id!
            }
            var item = Item.stub(sourceId: sourceId, externalId: UUID().uuidString,
                                 rawText: clean)
            item.kind = "chat"
            item.cleanText = clean
            item.wordCount = clean.components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }.count
            item.lang = "en"
            try item.insert(dbc)
        }
    }
}
