import Foundation

enum DetectError: Error, Equatable {
    case permissionDenied
}

func isPermissionDenied(_ error: Error) -> Bool {
    let ns = error as NSError
    if ns.domain == NSCocoaErrorDomain, ns.code == NSFileReadNoPermissionError { return true }
    if ns.domain == NSPOSIXErrorDomain, ns.code == Int(EPERM) || ns.code == Int(EACCES) { return true }
    if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
        return isPermissionDenied(underlying)
    }
    return false
}
