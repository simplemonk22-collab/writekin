import Testing
import Foundation
@testable import Writekin

struct MailMessageParserTests {
    @Test func parsesSimpleMessage() {
        let msg = """
        From: Jane <me@x.com>
        To: Friend <f@y.org>
        Subject: hi
        Message-ID: <abc@x.com>
        Date: Tue, 5 Mar 2019 10:00:00 -0800

        Hello there,
        this is the body.
        """
        let parsed = MailMessageParser.parse(msg)
        #expect(parsed.messageID == "<abc@x.com>")
        #expect(parsed.from == ["me@x.com"])
        #expect(parsed.to == ["f@y.org"])
        #expect(parsed.textBody?.contains("this is the body.") == true)
        #expect(parsed.date != nil)
        #expect(parsed.hadTextPlainPart)
    }

    @Test func unfoldsContinuationHeaders() {
        let msg = "To: a@b.c,\n\td@e.f\nFrom: me@x.com\n\nbody"
        let parsed = MailMessageParser.parse(msg)
        #expect(parsed.to == ["a@b.c", "d@e.f"])
    }

    @Test func prefersTextPlainInMultipart() {
        let msg = """
        From: me@x.com
        MIME-Version: 1.0
        Content-Type: multipart/alternative; boundary="BB"

        --BB
        Content-Type: text/html

        <b>rich</b> body
        --BB
        Content-Type: text/plain

        plain body
        --BB--
        """
        let parsed = MailMessageParser.parse(msg)
        #expect(parsed.textBody == "plain body")
    }

    @Test func decodesQuotedPrintable() {
        let msg = """
        From: me@x.com
        Content-Type: text/plain; charset=UTF-8
        Content-Transfer-Encoding: quoted-printable

        caf=C3=A9 line=
        joined
        """
        let parsed = MailMessageParser.parse(msg)
        #expect(parsed.textBody == "café linejoined")
    }

    @Test func decodesBase64Body() {
        let body = Data("hello base64".utf8).base64EncodedString()
        let msg = "From: me@x.com\nContent-Transfer-Encoding: base64\n\n\(body)"
        let parsed = MailMessageParser.parse(msg)
        #expect(parsed.textBody == "hello base64")
    }

    @Test func fallsBackToHTML() {
        let msg = """
        From: me@x.com
        Content-Type: text/html

        <html><body><p>Hello <b>world</b></p></body></html>
        """
        let parsed = MailMessageParser.parse(msg)
        #expect(parsed.textBody?.contains("Hello world") == true)
        #expect(!parsed.hadTextPlainPart)
    }

    @Test func capturesThreadingHeaders() {
        let msg = "From: me@x.com\nIn-Reply-To: <p@x>\nReferences: <r1@x> <r2@x>\n\nbody"
        let parsed = MailMessageParser.parse(msg)
        #expect(parsed.inReplyTo == "<p@x>")
        #expect(parsed.references == ["<r1@x>", "<r2@x>"])
    }

    @Test func parsesHTMLFromBackgroundThread() async {
        let msg = """
        From: me@x.com
        Content-Type: text/html

        <html><body><p>Background <b>thread</b> test</p></body></html>
        """
        let parsed = await Task.detached {
            MailMessageParser.parse(msg)
        }.value
        #expect(parsed.textBody?.contains("Background thread test") == true)
        #expect(!parsed.hadTextPlainPart)
    }
}

extension MailMessageParserTests {
    @Test func htmlStripperDecodesEntitiesAndBlocks() {
        let html = """
        <html><head><style>p{color:red}</style></head><body>\
        <p>It&#8217;s done &amp; shipped</p><div>see you &lt;soon&gt;</div></body></html>
        """
        let text = MailMessageParser.htmlToText(html)
        #expect(text == "It’s done & shipped\nsee you <soon>")
    }
}
