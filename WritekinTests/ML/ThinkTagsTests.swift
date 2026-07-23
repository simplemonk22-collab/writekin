import Testing
@testable import Writekin

struct ThinkTagsTests {
    @Test func passesPlainTextThrough() {
        #expect(ThinkTags.strip("Hey, sounds good — see you at 7.")
                == "Hey, sounds good — see you at 7.")
    }

    @Test func stripsLeadingThinkBlock() {
        let text = "<think>\nThe user wants a casual tone.\n</think>\n\nHey, sounds good."
        #expect(ThinkTags.strip(text) == "Hey, sounds good.")
    }

    @Test func stripsMultipleBlocksAnywhere() {
        let text = "<think>a</think>First part.<think>b</think> Second part."
        #expect(ThinkTags.strip(text) == "First part. Second part.")
    }

    @Test func dropsUnterminatedBlockEntirely() {
        // Token cap hit mid-thought: everything after <think> is reasoning,
        // not draft.
        let text = "Draft so far.<think>hmm, maybe I should"
        #expect(ThinkTags.strip(text) == "Draft so far.")
        #expect(ThinkTags.strip("<think>only reasoning, never closed") == "")
    }
}
