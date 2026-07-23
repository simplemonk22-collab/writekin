import Testing
import Foundation
import GRDB
@testable import Writekin

struct FormDocumentFilterTests {
    func seed(_ db: AppDatabase, kind: String, clean: String, lang: String? = "en",
              raw: String? = nil, externalId: String = UUID().uuidString) throws {
        try db.writer.write { dbc in
            let sid: Int64
            if let s = try Source.fetchOne(dbc), let id = s.id { sid = id }
            else {
                var s = Source(id: nil, kind: "imessage", configJson: "{}", lastSyncedAt: nil)
                try s.insert(dbc); sid = s.id!
            }
            var item = Item.stub(sourceId: sid, externalId: externalId,
                                 rawText: raw ?? clean)
            item.kind = kind
            item.cleanText = clean
            item.wordCount = clean.components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }.count
            item.lang = lang
            try item.insert(dbc)
        }
    }

    func dropReasons(_ db: AppDatabase) throws -> [String?] {
        try db.writer.read { try Item.fetchAll($0).map(\.dropReason) }
    }

    // MARK: - Filename Token Markers (Short tokens split on non-alphanumerics)

    @Test func ndaTokenInFilenameDropsAsFormDocument() throws {
        let db = try AppDatabase.inMemory()
        try seed(db, kind: "doc", clean: "This is a normal document with sufficient words to pass all length checks and more content here to ensure it meets minimum word requirements for proper evaluation purposes and testing procedures",
                 externalId: "file:///Users/janedoe/Mutual_NDA_2023.pdf")
        try FilterPass(db: db).run()
        #expect(try dropReasons(db) == ["form_document"])
    }

    @Test func ndaTokenCaseInsensitiveFilenameMatch() throws {
        let db = try AppDatabase.inMemory()
        try seed(db, kind: "doc", clean: "This is a normal document with sufficient words to pass all length checks and more content here to ensure it meets minimum word requirements for proper evaluation purposes and testing procedures",
                 externalId: "file:///Users/janedoe/AGREEMENT_NDA_FINAL.pdf")
        try FilterPass(db: db).run()
        #expect(try dropReasons(db) == ["form_document"])
    }

    @Test func oneZeroNineNineTokenInFilenameDropsAsFormDocument() throws {
        let db = try AppDatabase.inMemory()
        try seed(db, kind: "doc", clean: "This is a normal document with sufficient words to pass all length checks and more content here to ensure it meets minimum word requirements for proper evaluation purposes and testing procedures",
                 externalId: "file:///Users/janedoe/Tax_Form_1099-MISC_2023.pdf")
        try FilterPass(db: db).run()
        #expect(try dropReasons(db) == ["form_document"])
    }

    @Test func w2FormTokenInFilenameDropsAsFormDocument() throws {
        let db = try AppDatabase.inMemory()
        try seed(db, kind: "doc", clean: "This is a normal document with sufficient words to pass all length checks and more content here to ensure it meets minimum word requirements for proper evaluation purposes and testing procedures",
                 externalId: "file:///Users/janedoe/2023_W2Form_Statement.pdf")
        try FilterPass(db: db).run()
        #expect(try dropReasons(db) == ["form_document"])
    }

    @Test func w2TokenInFilenameDropsAsFormDocument() throws {
        let db = try AppDatabase.inMemory()
        try seed(db, kind: "doc", clean: "This is a normal document with sufficient words to pass all length checks and more content here to ensure it meets minimum word requirements for proper evaluation purposes and testing procedures",
                 externalId: "file:///Users/janedoe/W2_Tax_2024.pdf")
        try FilterPass(db: db).run()
        #expect(try dropReasons(db) == ["form_document"])
    }

    @Test func wNineFormTokenInFilenameDropsAsFormDocument() throws {
        let db = try AppDatabase.inMemory()
        try seed(db, kind: "doc", clean: "This is a normal document with sufficient words to pass all length checks and more content here to ensure it meets minimum word requirements for proper evaluation purposes and testing procedures",
                 externalId: "file:///Users/janedoe/Contractor_W9Form_Signed.pdf")
        try FilterPass(db: db).run()
        #expect(try dropReasons(db) == ["form_document"])
    }

    @Test func wNineTokenInFilenameDropsAsFormDocument() throws {
        let db = try AppDatabase.inMemory()
        try seed(db, kind: "doc", clean: "This is a normal document with sufficient words to pass all length checks and more content here to ensure it meets minimum word requirements for proper evaluation purposes and testing procedures",
                 externalId: "file:///Users/janedoe/ContractorID_W9_Certificate.pdf")
        try FilterPass(db: db).run()
        #expect(try dropReasons(db) == ["form_document"])
    }

    @Test func wDashTwoTokenInFilenameDropsAsFormDocument() throws {
        let db = try AppDatabase.inMemory()
        try seed(db, kind: "doc", clean: "This is a normal document with sufficient words to pass all length checks and more content here to ensure it meets minimum word requirements for proper evaluation purposes and testing procedures",
                 externalId: "file:///Users/janedoe/Employee_W-2_Statement_2024.pdf")
        try FilterPass(db: db).run()
        #expect(try dropReasons(db) == ["form_document"])
    }

    @Test func wDashNineTokenInFilenameDropsAsFormDocument() throws {
        let db = try AppDatabase.inMemory()
        try seed(db, kind: "doc", clean: "This is a normal document with sufficient words to pass all length checks and more content here to ensure it meets minimum word requirements for proper evaluation purposes and testing procedures",
                 externalId: "file:///Users/janedoe/Consultant_W-9_Form.pdf")
        try FilterPass(db: db).run()
        #expect(try dropReasons(db) == ["form_document"])
    }

    @Test func notesTokenDoesNotMatchNdaToken() throws {
        let db = try AppDatabase.inMemory()
        try seed(db, kind: "doc", clean: "This is a normal document with sufficient words to pass all length checks and more content here to ensure it meets minimum word requirements for proper evaluation purposes and testing procedures",
                 externalId: "file:///Users/janedoe/veranda-notes.md")
        try FilterPass(db: db).run()
        let items = try db.writer.read { try Item.fetchAll($0) }
        #expect(items.first?.state == "kept")
        #expect(items.first?.dropReason == nil)
    }

    // MARK: - Filename Substring Markers (Long substrings)

    @Test func nonDisclosureSubstringInFilenameDropsAsFormDocument() throws {
        let db = try AppDatabase.inMemory()
        try seed(db, kind: "doc", clean: "This is a normal document with sufficient words to pass all length checks and more content here to ensure it meets minimum word requirements for proper evaluation purposes and testing procedures",
                 externalId: "file:///Users/janedoe/non-disclosure-agreement.pdf")
        try FilterPass(db: db).run()
        #expect(try dropReasons(db) == ["form_document"])
    }

    @Test func nonDisclosureSpaceSubstringInFilenameDropsAsFormDocument() throws {
        let db = try AppDatabase.inMemory()
        try seed(db, kind: "doc", clean: "This is a normal document with sufficient words to pass all length checks and more content here to ensure it meets minimum word requirements for proper evaluation purposes and testing procedures",
                 externalId: "file:///Users/janedoe/non disclosure agreement final.pdf")
        try FilterPass(db: db).run()
        #expect(try dropReasons(db) == ["form_document"])
    }

    @Test func receiptSubstringInFilenameDropsAsFormDocument() throws {
        let db = try AppDatabase.inMemory()
        try seed(db, kind: "doc", clean: "This is a normal document with sufficient words to pass all length checks and more content here to ensure it meets minimum word requirements for proper evaluation purposes and testing procedures",
                 externalId: "file:///Users/janedoe/Receipt_2024_05_15.pdf")
        try FilterPass(db: db).run()
        #expect(try dropReasons(db) == ["form_document"])
    }

    @Test func invoiceSubstringInFilenameDropsAsFormDocument() throws {
        let db = try AppDatabase.inMemory()
        try seed(db, kind: "doc", clean: "This is a normal document with sufficient words to pass all length checks and more content here to ensure it meets minimum word requirements for proper evaluation purposes and testing procedures",
                 externalId: "file:///Users/janedoe/Invoice_Q2_2024.pdf")
        try FilterPass(db: db).run()
        #expect(try dropReasons(db) == ["form_document"])
    }

    @Test func purchaseOrderSubstringInFilenameDropsAsFormDocument() throws {
        let db = try AppDatabase.inMemory()
        try seed(db, kind: "doc", clean: "This is a normal document with sufficient words to pass all length checks and more content here to ensure it meets minimum word requirements for proper evaluation purposes and testing procedures",
                 externalId: "file:///Users/janedoe/Purchase_Order_PO-2024-001.pdf")
        try FilterPass(db: db).run()
        #expect(try dropReasons(db) == ["form_document"])
    }

    @Test func statementOfWorkSubstringInFilenameDropsAsFormDocument() throws {
        let db = try AppDatabase.inMemory()
        try seed(db, kind: "doc", clean: "This is a normal document with sufficient words to pass all length checks and more content here to ensure it meets minimum word requirements for proper evaluation purposes and testing procedures",
                 externalId: "file:///Users/janedoe/Statement_of_Work_Client_ABC.pdf")
        try FilterPass(db: db).run()
        #expect(try dropReasons(db) == ["form_document"])
    }

    @Test func taxReturnSubstringInFilenameDropsAsFormDocument() throws {
        let db = try AppDatabase.inMemory()
        try seed(db, kind: "doc", clean: "This is a normal document with sufficient words to pass all length checks and more content here to ensure it meets minimum word requirements for proper evaluation purposes and testing procedures",
                 externalId: "file:///Users/janedoe/Tax_Return_2023_Filed.pdf")
        try FilterPass(db: db).run()
        #expect(try dropReasons(db) == ["form_document"])
    }

    @Test func leaseAgreementSubstringInFilenameDropsAsFormDocument() throws {
        let db = try AppDatabase.inMemory()
        try seed(db, kind: "doc", clean: "This is a normal document with sufficient words to pass all length checks and more content here to ensure it meets minimum word requirements for proper evaluation purposes and testing procedures",
                 externalId: "file:///Users/janedoe/Lease_Agreement_Apartment_2024.pdf")
        try FilterPass(db: db).run()
        #expect(try dropReasons(db) == ["form_document"])
    }

    // MARK: - Content Markers (First 500 chars, lowercased)

    @Test func mutualNonDisclosureAgreementMarkerInContentDropsAsFormDocument() throws {
        let db = try AppDatabase.inMemory()
        let content = "This mutual non-disclosure agreement is entered into by and between the parties as of the date below. " +
            "Both parties agree to maintain confidentiality of any proprietary information shared during the course of discussions."
        try seed(db, kind: "doc", clean: content, externalId: "content-test-1")
        try FilterPass(db: db).run()
        #expect(try dropReasons(db) == ["form_document"])
    }

    @Test func nonDisclosureAgreementMarkerInContentDropsAsFormDocument() throws {
        let db = try AppDatabase.inMemory()
        let content = "This non-disclosure agreement is entered into as of the date of this agreement. " +
            "The receiving party agrees to keep all shared information confidential and not to disclose it to any third party without prior written consent of the disclosing party."
        try seed(db, kind: "doc", clean: content, externalId: "content-test-2")
        try FilterPass(db: db).run()
        #expect(try dropReasons(db) == ["form_document"])
    }

    @Test func formOneZeroNintyNineMarkerInContentDropsAsFormDocument() throws {
        let db = try AppDatabase.inMemory()
        let content = "This Form 1099-NEC is provided by the payer to report nonemployee compensation. " +
            "The recipient should use this for tax filing purposes and keep it with their records for seven years."
        try seed(db, kind: "doc", clean: content, externalId: "content-test-3")
        try FilterPass(db: db).run()
        #expect(try dropReasons(db) == ["form_document"])
    }

    @Test func receiptHashMarkerInContentDropsAsFormDocument() throws {
        let db = try AppDatabase.inMemory()
        let content = "Receipt # 12345 dated 2024-05-20. Item description: office supplies. Quantity: 10. " +
            "Unit price: $5.00. Total amount: $50.00. Thank you for your purchase."
        try seed(db, kind: "doc", clean: content, externalId: "content-test-4")
        try FilterPass(db: db).run()
        #expect(try dropReasons(db) == ["form_document"])
    }

    @Test func invoiceHashMarkerInContentDropsAsFormDocument() throws {
        let db = try AppDatabase.inMemory()
        let content = "Invoice # INV-2024-001 for services rendered. Client: ABC Corporation. " +
            "Description of services provided in May and June 2024. Total billed amount is shown below."
        try seed(db, kind: "doc", clean: content, externalId: "content-test-5")
        try FilterPass(db: db).run()
        #expect(try dropReasons(db) == ["form_document"])
    }

    @Test func invoiceNumberMarkerInContentDropsAsFormDocument() throws {
        let db = try AppDatabase.inMemory()
        let content = "Invoice number 24-006 submitted for payment. Services provided to Client XYZ. " +
            "Professional consulting services from June 1 through June 30, 2024. Amount due thirty days from invoice date."
        try seed(db, kind: "doc", clean: content, externalId: "content-test-6")
        try FilterPass(db: db).run()
        #expect(try dropReasons(db) == ["form_document"])
    }

    @Test func amountDueMarkerInContentDropsAsFormDocument() throws {
        let db = try AppDatabase.inMemory()
        let content = "Amount due: $3,500.00 for the consulting services rendered during the month of June. " +
            "Payment terms are net thirty days. Please remit payment by July 30, 2024 via wire transfer or check."
        try seed(db, kind: "doc", clean: content, externalId: "content-test-7")
        try FilterPass(db: db).run()
        #expect(try dropReasons(db) == ["form_document"])
    }

    @Test func thisAgreementMarkerInContentDropsAsFormDocument() throws {
        let db = try AppDatabase.inMemory()
        let content = "This agreement is entered into on this 15th day of May, 2024, by and between Party A and Party B. " +
            "The parties agree to the terms and conditions set forth herein and acknowledge their understanding of all provisions."
        try seed(db, kind: "doc", clean: content, externalId: "content-test-8")
        try FilterPass(db: db).run()
        #expect(try dropReasons(db) == ["form_document"])
    }

    // MARK: - False Positive Guard (40+ word document with receipt mid-text)

    @Test func longDocWithReceiptMidTextIsNotFormDocument() throws {
        let db = try AppDatabase.inMemory()
        // 40+ words with "the receipt from dinner" appearing mid-text, not at start
        let content = "We had a great team lunch today at the new Italian place downtown. " +
            "Everyone enjoyed their meals and we talked about the project roadmap and upcoming milestones. " +
            "I kept the receipt from dinner in my wallet to submit for expense reimbursement to the accounting team. " +
            "The food was delicious and the atmosphere was wonderful for team bonding."
        try seed(db, kind: "doc", clean: content, externalId: "false-positive-guard")
        try FilterPass(db: db).run()
        let items = try db.writer.read { try Item.fetchAll($0) }
        #expect(items.first?.state == "kept")
        #expect(items.first?.dropReason == nil)
    }

    // MARK: - Kind Filtering (Only doc kind, not sms or email)

    @Test func smsKindIsNeverCheckedForFormDocument() throws {
        let db = try AppDatabase.inMemory()
        // SMS with invoice content and invoice filename - should NOT be flagged
        try seed(db, kind: "sms", clean: "Invoice #123 due today with ten more words here yes",
                 externalId: "file:///Invoice_2024.pdf")
        try FilterPass(db: db).run()
        let items = try db.writer.read { try Item.fetchAll($0) }
        #expect(items.first?.state == "kept")
        #expect(items.first?.dropReason == nil)
    }

    @Test func emailKindIsNeverCheckedForFormDocument() throws {
        let db = try AppDatabase.inMemory()
        // Email with NDA content and NDA filename - should NOT be flagged
        let content = "This non-disclosure agreement is entered into by both parties " +
            "and includes additional words to pass minimum word count for emails yes and more text here for proper document evaluation purposes and testing"
        try seed(db, kind: "email", clean: content,
                 externalId: "file:///NDA_2024.pdf")
        try FilterPass(db: db).run()
        let items = try db.writer.read { try Item.fetchAll($0) }
        #expect(items.first?.state == "kept")
        #expect(items.first?.dropReason == nil)
    }

    // MARK: - Edge Cases and Combinations

    @Test func formDocumentCheckHappensAfterGameShare() throws {
        let db = try AppDatabase.inMemory()
        // A doc that would trigger form_document, but also is a game share
        // Should be caught by game_share first (order matters)
        let content = "Wordle 123 4/6\n⬜🟨⬜⬜⬜\n🟩🟩⬜⬜🟩\n🟩🟩🟩🟩🟩"
        try seed(db, kind: "doc", clean: content,
                 externalId: "file:///NDA_2024.pdf")
        try FilterPass(db: db).run()
        #expect(try dropReasons(db) == ["game_share"])
    }

    @Test func botchFilenameTokenDoesNotMatchNda() throws {
        let db = try AppDatabase.inMemory()
        // "notarized" contains "nda" but should not match (token-based split)
        try seed(db, kind: "doc", clean: "This is a normal document with sufficient words to pass all checks and more content to ensure it reaches minimum word requirements for documents and testing purposes which are essential for validation",
                 externalId: "file:///Users/janedoe/notarized-document-2024.pdf")
        try FilterPass(db: db).run()
        let items = try db.writer.read { try Item.fetchAll($0) }
        #expect(items.first?.state == "kept")
        #expect(items.first?.dropReason == nil)
    }

    @Test func multipleMarkersBothFilenameAndContentTriggerFormDocument() throws {
        let db = try AppDatabase.inMemory()
        // Both filename AND content match - still should drop (only need one)
        let content = "This non-disclosure agreement is entered into by both parties " +
            "and contains additional words to pass minimum requirements for all checks"
        try seed(db, kind: "doc", clean: content,
                 externalId: "file:///Users/janedoe/NDA_Agreement_Final.pdf")
        try FilterPass(db: db).run()
        #expect(try dropReasons(db) == ["form_document"])
    }

    @Test func filenameMarkerOnly() throws {
        let db = try AppDatabase.inMemory()
        // Filename match only, neutral content
        try seed(db, kind: "doc", clean: "This is a normal document with sufficient words here yes",
                 externalId: "file:///Users/janedoe/Invoice_2024.pdf")
        try FilterPass(db: db).run()
        #expect(try dropReasons(db) == ["form_document"])
    }

    @Test func contentMarkerOnly() throws {
        let db = try AppDatabase.inMemory()
        // Content match only, generic filename
        let content = "Invoice # 5678 for services rendered in May and June. " +
            "Please remit payment within thirty days of invoice date per agreement."
        try seed(db, kind: "doc", clean: content,
                 externalId: "file:///Users/janedoe/document.pdf")
        try FilterPass(db: db).run()
        #expect(try dropReasons(db) == ["form_document"])
    }

    @Test func contentMarkerBeyondFiveHundredCharsIgnored() throws {
        let db = try AppDatabase.inMemory()
        // Place content marker well beyond 500 chars - should NOT trigger
        let prefix = String(repeating: "This is normal document content. ", count: 20) // ~640 chars
        let content = prefix + "This agreement is entered into by both parties " +
            "to establish a binding legal relationship."
        try seed(db, kind: "doc", clean: content, externalId: "beyond-500")
        try FilterPass(db: db).run()
        let items = try db.writer.read { try Item.fetchAll($0) }
        #expect(items.first?.state == "kept")
        #expect(items.first?.dropReason == nil)
    }

    @Test func contentMarkerAtExactFiveHundredCharBoundaryMatches() throws {
        let db = try AppDatabase.inMemory()
        // Craft content so that "amount due" starts right at 500 char boundary
        let prefix = String(repeating: "x", count: 487) // 487 chars
        let content = prefix + " Amount due for services rendered on agreement terms."
        try seed(db, kind: "doc", clean: content, externalId: "at-500-boundary")
        try FilterPass(db: db).run()
        #expect(try dropReasons(db) == ["form_document"])
    }

    @Test func caseInsensitiveContentMarkerMatching() throws {
        let db = try AppDatabase.inMemory()
        let content = "THIS MUTUAL NON-DISCLOSURE AGREEMENT is entered into by parties " +
            "as part of a confidentiality arrangement for shared proprietary information protection."
        try seed(db, kind: "doc", clean: content, externalId: "uppercase-marker")
        try FilterPass(db: db).run()
        #expect(try dropReasons(db) == ["form_document"])
    }

    @Test func caseInsensitiveFilenameTokenMatching() throws {
        let db = try AppDatabase.inMemory()
        try seed(db, kind: "doc", clean: "This is a normal document with sufficient words to pass all checks",
                 externalId: "file:///Users/janedoe/INVOICE-SUMMARY-2024.PDF")
        try FilterPass(db: db).run()
        #expect(try dropReasons(db) == ["form_document"])
    }

    @Test func externalIdWithoutSchemeUseLastPathComponent() throws {
        let db = try AppDatabase.inMemory()
        // externalId without file:// scheme - last path component should still be extracted
        try seed(db, kind: "doc", clean: "This is a normal document with sufficient words to pass all checks",
                 externalId: "/Users/janedoe/Contracts/NDA-2024.pdf")
        try FilterPass(db: db).run()
        #expect(try dropReasons(db) == ["form_document"])
    }

    @Test func shortFilenameWithTokenMarkerMatches() throws {
        let db = try AppDatabase.inMemory()
        try seed(db, kind: "doc", clean: "This is a normal document with sufficient words to pass checks",
                 externalId: "NDA.pdf")
        try FilterPass(db: db).run()
        #expect(try dropReasons(db) == ["form_document"])
    }

    @Test func emptyExternalIdDoesNotCrash() throws {
        let db = try AppDatabase.inMemory()
        // Edge case: empty externalId should not crash, just not match filename
        try seed(db, kind: "doc", clean: "This is a normal document with sufficient words to pass all checks and more content to ensure it reaches minimum word requirements for documents and testing purposes which are essential for validation",
                 externalId: "")
        try FilterPass(db: db).run()
        let items = try db.writer.read { try Item.fetchAll($0) }
        #expect(items.first?.state == "kept")
        #expect(items.first?.dropReason == nil)
    }

    @Test func filenameWithMultipleTokenMarkersStillDropsOnce() throws {
        let db = try AppDatabase.inMemory()
        // Filename with multiple matching tokens - should still be dropped with single reason
        try seed(db, kind: "doc", clean: "This is a normal document with sufficient words to pass checks",
                 externalId: "file:///NDA_1099_Form_2024.pdf")
        try FilterPass(db: db).run()
        #expect(try dropReasons(db) == ["form_document"])
    }

    @Test func cleanTextEmptyDoesNotMatchContentMarkers() throws {
        let db = try AppDatabase.inMemory()
        // Empty cleanText should not cause crash or false match
        try seed(db, kind: "doc", clean: "", 
                 externalId: "file:///NDA.pdf")
        try FilterPass(db: db).run()
        // Should drop on filename match alone
        #expect(try dropReasons(db) == ["form_document"])
    }

    @Test func formDocumentReasonIncludedInResetFilterDecisions() throws {
        let db = try AppDatabase.inMemory()
        try seed(db, kind: "doc", clean: "This is a normal document with sufficient words to pass all checks",
                 externalId: "file:///Invoice_2024.pdf")
        let pass = FilterPass(db: db)
        try pass.run()
        try pass.resetFilterDecisions()
        let items = try db.writer.read { try Item.fetchAll($0) }
        #expect(items.first?.state == "ingested")
        #expect(items.first?.dropReason == nil)
    }
}
