import Testing
import Foundation
@testable import Writekin

struct CancelFlagTests {
    @Test func cancelFlagIsThreadSafe() async throws {
        let flag = CancelFlag()
        #expect(!flag.isSet)
        await Task.detached {
            flag.set()
        }.value
        #expect(flag.isSet)
    }
}
