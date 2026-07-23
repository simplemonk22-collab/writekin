import Testing
import Foundation
@testable import Writekin

/// `ModelRuntime.load` can't be exercised end-to-end in a fast unit test —
/// it drives real MLX model loading from disk. This covers the one piece of
/// pure decision logic in its fallback behavior (Task 12 review): an
/// adapter-application failure degrades to a base-model-only load rather
/// than failing the whole load, while a base-model load failure is never
/// swallowed by this helper.
struct ModelRuntimeTests {
    @Test func adapterApplyFailureDegradesToNoAdapter() {
        let requested = URL(fileURLWithPath: "/tmp/adapter-dir")
        #expect(ModelRuntime.loadedAdapterDirectory(requested: requested,
                                                     adapterApplyFailed: true) == nil)
    }

    @Test func adapterApplySuccessKeepsRequestedDirectory() {
        let requested = URL(fileURLWithPath: "/tmp/adapter-dir")
        #expect(ModelRuntime.loadedAdapterDirectory(requested: requested,
                                                     adapterApplyFailed: false) == requested)
    }

    @Test func noAdapterRequestedStaysNilRegardless() {
        #expect(ModelRuntime.loadedAdapterDirectory(requested: nil,
                                                     adapterApplyFailed: true) == nil)
        #expect(ModelRuntime.loadedAdapterDirectory(requested: nil,
                                                     adapterApplyFailed: false) == nil)
    }
}
