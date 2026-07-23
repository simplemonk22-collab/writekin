import Testing
import Foundation
@testable import Writekin

struct MarkdownStripperTests {
    @Test func dropsFencedCodeBlocksBackticks() {
        let md = """
        before
        ```swift
        let x = 1
        print(x)
        ```
        after
        """
        let result = MarkdownStripper.strip(md)
        #expect(result.contains("before"))
        #expect(result.contains("after"))
        #expect(!result.contains("let x"))
        #expect(!result.contains("```"))
    }

    @Test func dropsFencedCodeBlocksTildes() {
        let md = """
        before
        ~~~
        code here
        ~~~
        after
        """
        let result = MarkdownStripper.strip(md)
        #expect(!result.contains("code here"))
        #expect(result.contains("before"))
        #expect(result.contains("after"))
    }

    @Test func keepsInlineCodeTextDropsBackticks() {
        let result = MarkdownStripper.strip("run `npm install` first")
        #expect(result == "run npm install first")
    }

    @Test func stripsHeadingMarkers() {
        #expect(MarkdownStripper.strip("# Title") == "Title")
        #expect(MarkdownStripper.strip("### Subheading here") == "Subheading here")
    }

    @Test func stripsBoldMarkers() {
        #expect(MarkdownStripper.strip("this is **bold** text") == "this is bold text")
        #expect(MarkdownStripper.strip("this is __bold__ text") == "this is bold text")
    }

    @Test func stripsItalicMarkers() {
        #expect(MarkdownStripper.strip("this is *italic* text") == "this is italic text")
        #expect(MarkdownStripper.strip("this is _italic_ text") == "this is italic text")
    }

    @Test func loneAsteriskSurvives() {
        #expect(MarkdownStripper.strip("3 * 4 = 12") == "3 * 4 = 12")
        #expect(MarkdownStripper.strip("a lone * mark") == "a lone * mark")
    }

    @Test func loneUnderscoreSurvives() {
        #expect(MarkdownStripper.strip("my_var_name stays") == "my_var_name stays")
    }

    @Test func stripsLinksKeepsText() {
        #expect(MarkdownStripper.strip("see [the docs](https://example.com/docs) for more")
                == "see the docs for more")
    }

    @Test func dropsImagesEntirely() {
        let result = MarkdownStripper.strip("before ![alt text](https://example.com/x.png) after")
        #expect(result == "before  after")
        #expect(!result.contains("alt text"))
        #expect(!result.contains("example.com"))
    }

    @Test func stripsBlockquoteMarkers() {
        #expect(MarkdownStripper.strip("> quoted text") == "quoted text")
    }

    @Test func stripsNestedBlockquoteMarkers() {
        #expect(MarkdownStripper.strip("> > deeply quoted") == "deeply quoted")
    }

    @Test func stripsListMarkers() {
        let md = """
        - first
        * second
        + third
        """
        let result = MarkdownStripper.strip(md)
        #expect(result == "first\nsecond\nthird")
    }

    @Test func stripsOrderedListMarkers() {
        let md = """
        1. first
        2) second
        """
        let result = MarkdownStripper.strip(md)
        #expect(result == "first\nsecond")
    }

    @Test func dropsHorizontalRules() {
        let md = """
        before
        ---
        after
        """
        let result = MarkdownStripper.strip(md)
        #expect(result == "before\nafter")
    }

    @Test func dropsHorizontalRuleVariants() {
        #expect(!MarkdownStripper.strip("***").contains("*"))
        #expect(!MarkdownStripper.strip("___").contains("_"))
    }

    @Test func stripsTablePipesAndSeparatorRows() {
        let md = """
        | Name | Age |
        |------|-----|
        | Alice | 30 |
        """
        let result = MarkdownStripper.strip(md)
        #expect(result == "Name Age\nAlice 30")
    }

    @Test func dropsReferenceLinkDefinitions() {
        let md = """
        See [my link][1] for details.
        [1]: https://example.com/page
        """
        let result = MarkdownStripper.strip(md)
        #expect(!result.contains("https://example.com/page"))
        #expect(result.contains("See [my link][1] for details."))
    }

    @Test func everythingElsePassesThrough() {
        let text = "Just plain prose with no markdown syntax at all."
        #expect(MarkdownStripper.strip(text) == text)
    }

    @Test func combinedRealisticDocument() {
        let md = """
        # My Notes

        This is **important** and this is *also* notable.

        - item one
        - item two

        > a quoted thought

        ```
        code.that.should.vanish()
        ```

        See [the reference](https://example.com) for more.
        """
        let result = MarkdownStripper.strip(md)
        #expect(result.contains("My Notes"))
        #expect(result.contains("This is important and this is also notable."))
        #expect(result.contains("item one"))
        #expect(result.contains("item two"))
        #expect(result.contains("a quoted thought"))
        #expect(!result.contains("code.that.should.vanish"))
        #expect(result.contains("See the reference for more."))
        #expect(!result.contains("https://example.com"))
    }
}
