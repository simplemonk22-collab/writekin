import Testing
import Foundation
@testable import Writekin

struct DetectionCoreTests {
    @Test func parsesStandardRFC822Date() {
        let date = parseRFC822Date("Tue, 5 Mar 2019 10:00:00 -0800")
        #expect(date != nil)
        let components = Calendar(identifier: .gregorian).dateComponents(
            in: TimeZone(identifier: "UTC")!, from: date!)
        #expect(components.year == 2019)
        #expect(components.month == 3)
        #expect(components.day == 5)
    }

    @Test func parsesDateWithoutWeekday() {
        #expect(parseRFC822Date("5 Mar 2019 10:00:00 -0800") != nil)
    }

    @Test func parsesNamedTimeZones() {
        #expect(parseRFC822Date("Tue, 5 Mar 2019 10:00:00 GMT") != nil)
        #expect(parseRFC822Date("Mon, 1 Apr 2002 09:00:00 EST") != nil)
    }

    @Test func rejectsGarbage() {
        #expect(parseRFC822Date("not a date") == nil)
    }

    @Test func recognizesPosixPermissionErrors() {
        let eperm = NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))
        let eacces = NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))
        let cocoa = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)
        let other = NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError)
        #expect(isPermissionDenied(eperm))
        #expect(isPermissionDenied(eacces))
        #expect(isPermissionDenied(cocoa))
        #expect(!isPermissionDenied(other))
    }
}
