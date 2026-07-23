import Testing
import Foundation
@testable import Writekin

struct HandleNormalizerTests {
    @Test func trimsAndLowercasesPlainText() {
        #expect(HandleNormalizer.normalize(" Me ") == "me")
    }

    @Test func lowercasesAndNormalizesGmailDomainCase() {
        #expect(HandleNormalizer.normalize("Jane.Doe.fakedonotemail@GMail.com") == "janedoefakedonotemail@gmail.com")
    }

    @Test func mapsGooglemailDomainToGmail() {
        #expect(HandleNormalizer.normalize("xfakedonotemail@googlemail.com") == "xfakedonotemail@gmail.com")
    }

    @Test func passesThroughNonEmailTrimmedAndLowercased() {
        #expect(HandleNormalizer.normalize("  Rachel Maxwell ") == "rachel maxwell")
    }

    @Test func removesDotsFromGmailLocalPartOnly() {
        #expect(HandleNormalizer.normalize("jane.doe.fakedonotemail@gmail.com") == "janedoefakedonotemail@gmail.com")
        #expect(HandleNormalizer.normalize("janedoefakedonotemail@gmail.com") == "janedoefakedonotemail@gmail.com")
    }

    @Test func doesNotRemoveDotsFromNonGmailDomains() {
        #expect(HandleNormalizer.normalize("first.last@example.com") == "first.last@example.com")
    }

    @Test func preservesPlusTagsInGmailLocalPart() {
        #expect(HandleNormalizer.normalize("jane.doe.fakedonotemail+news@gmail.com") == "janedoefakedonotemail+news@gmail.com")
    }

    @Test func removesDotsFromGooglemailLocalPartAfterDomainMapping() {
        #expect(HandleNormalizer.normalize("j.a.n.e.fakedonotemail@googlemail.com") == "janefakedonotemail@gmail.com")
    }

    @Test func handlesEmailWithNoAtSignAsPlainText() {
        #expect(HandleNormalizer.normalize(" Not.An.Email ") == "not.an.email")
    }
}
