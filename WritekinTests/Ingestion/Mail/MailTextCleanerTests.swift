import Testing
@testable import Writekin

struct MailTextCleanerTests {
    // MARK: - mbox bleed truncation

    @Test func truncatesAtMboxBleed() {
        // Real Thunderbird artifact: body ends, then a lone "From" separator
        // plus the NEXT message's raw headers bleed into raw_text.
        let raw = """
        Thanks, talk soon.

        From
        Return-Path: <janedoefakedonotemail@gmail.com>
        Received: from ?192.168.10.103?
        Content-Type: text/plain; charset=us-ascii
        """
        #expect(MailTextCleaner.clean(raw) == "Thanks, talk soon.")
    }

    @Test func mboxBleedGuardRequiresHeaderShapedNextLine() {
        // A body line starting with "From " followed by ordinary prose (not
        // a header-shaped line) must survive — this is not a real bleed.
        let raw = "From what I remember, we agreed on Tuesday.\nSee you then."
        #expect(MailTextCleaner.clean(raw) == raw)
    }

    // MARK: - stray header-line stripping

    @Test func stripsFromToCcBccSubjectHeaderLines() {
        let raw = """
        Here's the thread you asked about:

        From: Jane Doe <janedoefakedonotemail@gmail.com>
        To: Jeff York <jeff@example.com>
        Cc: Alice <alice@example.com>
        Bcc: Bob <bob@example.com>
        Subject: Re: dinner plans
        Let's do 7pm.
        """
        let cleaned = MailTextCleaner.clean(raw)
        #expect(!cleaned.contains("From:"))
        #expect(!cleaned.contains("To:"))
        #expect(!cleaned.contains("Cc:"))
        #expect(!cleaned.contains("Bcc:"))
        #expect(!cleaned.contains("Subject:"))
        #expect(cleaned.contains("Here's the thread you asked about:"))
        #expect(cleaned.contains("Let's do 7pm."))
    }

    @Test func stripsDateSentReplyToHeaderLines() {
        let raw = """
        Inline forwarded note:

        Date: Mon, 8 Jun 2009 14:02:00 PDT
        Sent: Monday, June 8, 2009 2:02 PM
        Reply-To: jane@example.com
        body text follows
        """
        let cleaned = MailTextCleaner.clean(raw)
        #expect(!cleaned.contains("PDT"))
        #expect(!cleaned.contains("Sent:"))
        #expect(!cleaned.contains("Reply-To:"))
        #expect(cleaned.contains("body text follows"))
    }

    @Test func stripsRoutingHeaderLines() {
        let raw = """
        Return-Path: <janedoefakedonotemail@gmail.com>
        Received: from mail.example.com by mx.example.com
        Message-ID: <a1b2c3d4.5060700@example.com>
        In-Reply-To: <abc123@example.com>
        References: <abc123@example.com> <def456@example.com>
        the actual message
        """
        let cleaned = MailTextCleaner.clean(raw)
        #expect(cleaned == "the actual message")
    }

    @Test func stripsMimeHeaderLines() {
        let raw = """
        MIME-Version: 1.0
        Content-Type: text/plain; charset=UTF-8
        Content-Transfer-Encoding: 7bit
        X-Mailer: Apple Mail (2.1234)
        actual message body
        """
        let cleaned = MailTextCleaner.clean(raw)
        #expect(cleaned == "actual message body")
    }

    @Test func headerLineStrippingIsCaseInsensitiveOnFieldName() {
        let raw = "from: jane@example.com\nreal content here"
        #expect(MailTextCleaner.clean(raw) == "real content here")
    }

    @Test func doesNotStripProseThatLooksLikeAWordAndColon() {
        // Closed list, no generic `word:` matching — "PS:" isn't a header field.
        let raw = "PS: call me later\nAlso: don't forget the keys"
        #expect(MailTextCleaner.clean(raw) == raw)
    }

    // MARK: - MIME plumbing stripping

    @Test func stripsMultipartBoundaryMarkerLines() {
        let raw = """
        the message body

        ------=_NextPart_000_0011_01C9E5B2.12345678
        more body after a spurious boundary marker
        """
        let cleaned = MailTextCleaner.clean(raw)
        #expect(!cleaned.contains("NextPart"))
        #expect(cleaned.contains("the message body"))
        #expect(cleaned.contains("more body after a spurious boundary marker"))
    }

    @Test func stripsWrappedBoundaryAndCharsetFragmentLines() {
        let raw = """
        body text

        boundary="----=_NextPart_000_0011"
        charset="utf-8"
        more body
        """
        let cleaned = MailTextCleaner.clean(raw)
        #expect(!cleaned.contains("boundary="))
        #expect(!cleaned.contains("charset="))
        #expect(cleaned.contains("body text"))
        #expect(cleaned.contains("more body"))
    }

    @Test func signatureDelimiterBehaviorIsUnchanged() {
        // The "-- " / "--" signature cut must stay byte-identical: neither
        // is long enough to match the MIME boundary-marker pattern.
        let raw = "Sounds good.\n\n-- \nJane Doe\nsent from my phone"
        #expect(MailTextCleaner.clean(raw) == "Sounds good.")
    }

    // MARK: - existing behavior must stay green

    @Test func stripsSignatureAndQuotedTail() {
        let raw = """
        Sounds good, see you at 7.

        On Mar 5, 2019, John wrote:
        > are we still on for dinner
        > tonight?

        --\u{20}
        Jane Doe
        sent from my phone
        """
        #expect(MailTextCleaner.clean(raw) == "Sounds good, see you at 7.")
    }

    @Test func stripsForwardedBoilerplate() {
        let raw = "my comment\n\nBegin forwarded message:\nFrom: x@y.z\nbody"
        #expect(MailTextCleaner.clean(raw) == "my comment")
    }

    @Test func keepsInlineQuotesInMiddle() {
        let raw = "> you said this\n\nand I reply inline here with enough text"
        let cleaned = MailTextCleaner.clean(raw)
        #expect(cleaned.contains("I reply inline"))
    }

    @Test func cutsGmailForwardedBanner() {
        let raw = "FYI, relevant to us\n\n---------- Forwarded message ---------\nFrom: Someone <s@x.com>\ntheir whole email body here"
        #expect(MailTextCleaner.clean(raw) == "FYI, relevant to us")
    }

    @Test func cutsOutlookOriginalMessageBanner() {
        let raw = "see below\n-----Original Message-----\nFrom: a@b.c\nbody"
        #expect(MailTextCleaner.clean(raw) == "see below")
    }

    @Test func dashedProseIsNotAForwardMarker() {
        let raw = "the plan -- forwarded message or not -- stays the same and here is more of my text"
        #expect(MailTextCleaner.clean(raw).contains("stays the same"))
    }

    @Test func rewrappedQuoteThreadIsCutAtIntro() {
        // Gmail hard-wraps long quoted lines; continuation fragments lose
        // their ">" prefix (the bare "web" line), which used to stop the
        // trailing backward walk and strand the quote's upper half.
        let raw = """
        Here is my actual reply text with plenty of words in it today.

        On Fri, Aug 31, 2012 at 11:55 AM, Pat Miller <pmiller@example.edu> wrote:

        > In your opinion, are we going to be able to finish this
        > before the deadline hits?
        >
        > > It's most likely because there was nothing saved in the shared
        web
        > > folder yet -- that's where it keeps all the earlier drafts.
        > >
        > > Take another look in 2 minutes and let me know.
        """
        let cleaned = MailTextCleaner.clean(raw)
        #expect(cleaned.contains("my actual reply text"))
        #expect(!cleaned.contains("deadline"))
        #expect(!cleaned.contains("wrote:"))
        #expect(!cleaned.contains("earlier drafts"))
    }

    @Test func inlineReplyBelowQuoteSurvivesMajorityCut() {
        let raw = """
        On Fri, Aug 31, 2012 at 11:55 AM, Pat Miller <s@u.edu> wrote:

        > can you look at the first thing
        My answer to the first thing is right here with plenty of words.
        > and also the second thing
        And here is a long answer to the second thing as well, more words.
        """
        let cleaned = MailTextCleaner.clean(raw)
        #expect(cleaned.contains("answer to the first thing"))
        #expect(cleaned.contains("answer to the second thing"))
    }

    @Test func decodesResidualQuotedPrintable() {
        let raw = "The link isn=92t correct =96 try again=85 and a literal 5=3D5."
        let cleaned = MailTextCleaner.clean(raw)
        #expect(cleaned.contains("isn\u{2019}t correct \u{2013} try again\u{2026}"))
        #expect(cleaned.contains("5=5"))
    }

    @Test func joinsQuotedPrintableSoftLineBreaks() {
        let raw = "This sentence was wrapped by quoted-printable enco=\nding into two lines."
        let cleaned = MailTextCleaner.clean(raw)
        #expect(cleaned.contains("encoding into two lines"))
    }

    // MARK: - device/app signature footers

    @Test func stripsSentFromMyIphoneFooter() {
        let raw = "running late, be there in 20\n\nSent from my iPhone"
        #expect(MailTextCleaner.clean(raw) == "running late, be there in 20")
    }

    @Test func stripsFromMyIphoneVariantAndTrailingPeriod() {
        let raw = "sounds good see you then\n\nFrom my iPhone."
        #expect(MailTextCleaner.clean(raw) == "sounds good see you then")
    }

    @Test func stripsIphoneFooterAboveQuotedTail() {
        let raw = """
        yes let's do it

        Sent from my iPhone

        On Mar 5, 2019, John wrote:
        > are we still on
        """
        #expect(MailTextCleaner.clean(raw) == "yes let's do it")
    }

    @Test func stripsGoogleTalkFooter() {
        let raw = "ok calling you in five\n\nSent from Google Talk"
        #expect(MailTextCleaner.clean(raw) == "ok calling you in five")
        let bare = "ok calling you in five\n\nGoogle Talk"
        #expect(MailTextCleaner.clean(bare) == "ok calling you in five")
    }

    @Test func proseMentioningIphoneOrGoogleTalkSurvives() {
        let raw = "I sent that photo from my iPhone earlier, and we can chat on Google Talk tonight if you want."
        #expect(MailTextCleaner.clean(raw) == raw)
    }

    @Test func wrappedTwoLineQuoteIntroIsFullyStripped() {
        let raw = """
        Here is my reply with plenty of words to keep it healthy today.

        On Fri, Aug 31, 2012 at 11:55 AM, Dana
        Reed <dreed@example.com> wrote:

        > the quoted question she asked
        > and its second line
        """
        let cleaned = MailTextCleaner.clean(raw)
        #expect(cleaned.contains("my reply with plenty"))
        #expect(!cleaned.contains("reed"))
        #expect(!cleaned.contains("wrote:"))
        #expect(!cleaned.lowercased().contains("on fri"))
    }

    @Test func proseEndingInWroteSurvives() {
        let raw = "I finished the chapter that my grandfather wrote:\nit was about the farm, and it was wonderful to read this weekend."
        let cleaned = MailTextCleaner.clean(raw)
        #expect(cleaned.contains("grandfather wrote:"))
        #expect(cleaned.contains("wonderful to read"))
    }

    /// Google Drive share notifications append a "courtesy copy" footer to
    /// the AUTHOR's own message — the footer (and its support.google.com
    /// line, which got mined as a "signoff") is cut; the message survives.
    @Test func serviceCourtesyCopyFooterIsStripped() {
        let raw = """
        Here is the business plan so far. Let me know what you think.

        Jane

        This is a courtesy copy of an email for your record only. It's not the same \
        email your collaborators received. Visit \
        https://support.google.com/drive/?p=courtesy_copy to learn more.
        """
        let cleaned = MailTextCleaner.clean(raw)
        #expect(cleaned.contains("business plan so far"))
        #expect(cleaned.hasSuffix("Jane"))
        #expect(!cleaned.contains("courtesy copy"))
        #expect(!cleaned.contains("support.google.com"))
    }
}
