import Testing
@testable import Writekin

struct QuoteTailExtractorTests {
    @Test func extractsTrailingQuotedRunWithoutPrefixes() {
        let raw = """
        Sounds good, see you then!
        Jane

        On Tue, 5 Oct 2004 12:38:00 -0500, Jeff York <jeff@example.com> wrote:
        >
        > Jane,
        > Can you help me with my sound problem?
        > It echoes in every application.
        """
        let context = QuoteTailExtractor.extract(raw)
        #expect(context == "Jane,\nCan you help me with my sound problem?\nIt echoes in every application.")
    }

    @Test func noQuotedTailReturnsNil() {
        #expect(QuoteTailExtractor.extract("Just a plain sent email.\nNo quoting at all.") == nil)
    }

    @Test func quoteInMiddleIsNotATail() {
        // A quoted run followed by more of the author's own text is inline
        // quoting, not a trailing inbound message.
        let raw = """
        > are you coming tonight?
        Yes I am! And below is my signature.
        """
        #expect(QuoteTailExtractor.extract(raw) == nil)
    }

    @Test func mboxBleedIsCutBeforeExtraction() {
        // Real Thunderbird artifact (research §4 item 8): body ends with the
        // quoted inbound message, then a lone "From" separator plus the NEXT
        // message's raw headers bleed in. The headers must not leak into context.
        let raw = """
        I'm proud of you actually :)

        On Jul 6, 2009, at 11:33 PM, Sam Jones <m@example.edu> wrote:
        >
        > http://xkcd.com/606/
        From
        Return-Path: <janedoefakedonotemail@gmail.com>
        Received: from ?192.168.10.103?
        Message-ID: <a1b2c3d4.5060700@example.com>
        """
        let context = QuoteTailExtractor.extract(raw)
        #expect(context == "http://xkcd.com/606/")
    }

    @Test func truncatesToLast1000Characters() {
        let longQuote = (0..<200).map { "> line number \($0) of the inbound message" }
            .joined(separator: "\n")
        let raw = "Short reply.\n\nOn Mon, Jan 1, 2024 at 9:00 AM, A <a@b.c> wrote:\n" + longQuote
        let context = try! #require(QuoteTailExtractor.extract(raw))
        #expect(context.count <= 1000)
        #expect(context.hasSuffix("line number 199 of the inbound message"))
    }

    @Test func introLineIsNotPartOfContext() {
        let raw = """
        Reply body.

        On Jan 1, 2024, Alice <alice@example.com> wrote:
        > hello jane
        """
        #expect(QuoteTailExtractor.extract(raw) == "hello jane")
    }

    @Test func crlfIsNormalized() {
        let raw = "Reply.\r\n\r\nOn Jan 1, Alice wrote:\r\n> hi\r\n> there"
        #expect(QuoteTailExtractor.extract(raw) == "hi\nthere")
    }

    @Test func signatureAfterQuoteIsIgnored() {
        // Real emails often end body / quoted reply / "-- " signature. The
        // signature lines aren't `>`-prefixed, so a naive backward walk hits
        // them first and finds no quoted tail. MailTextCleaner strips the
        // signature before looking for the quote; the extractor must mirror
        // that so the genuine quote tail is still found.
        let raw = """
        Sounds good, see you then!

        On Tue, 5 Oct 2004 12:38:00 -0500, Jeff York <jeff@example.com> wrote:
        > Jane,
        > Can you help me with my sound problem?
        --
        Jane
        http://example.com/
        """
        let context = QuoteTailExtractor.extract(raw)
        #expect(context == "Jane,\nCan you help me with my sound problem?")
    }

    @Test func nestedQuoteMarkersKeepDeeperLevels() {
        // Pins current behavior (reviewer-noted): only one leading ">" (plus
        // one following space) is stripped per line, so a deeper nested quote
        // marker like ">> deeper" is left as "> deeper" rather than fully
        // unwrapped.
        let raw = """
        Reply body.

        On Jan 1, 2024, Alice <alice@example.com> wrote:
        > hello jane
        >> deeper
        """
        #expect(QuoteTailExtractor.extract(raw) == "hello jane\n> deeper")
    }
}
