import Foundation

/// A tiny thread-safe boolean flag used to propagate cancellation into
/// `Task.detached` work that does not inherit the parent task's structured
/// cancellation. The coordinator sets this alongside cancelling `runTask`;
/// passes poll `isSet` cooperatively at each batch boundary.
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    func set() {
        lock.lock(); flag = true; lock.unlock()
    }

    var isSet: Bool {
        lock.lock(); defer { lock.unlock() }; return flag
    }
}
