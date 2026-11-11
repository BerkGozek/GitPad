import Foundation
import libgit2

/// Process-wide libgit2 setup and small C-interop helpers. Nothing outside GitKit imports libgit2.
enum LibGit2 {
    /// `git_libgit2_init` must run once per process before any other call. A `static let`
    /// initializer is lazy and thread-safe, so touching it from anywhere is enough.
    private static let initialized: Bool = {
        git_libgit2_init()
        return true
    }()

    static func ensureInitialized() {
        _ = initialized
    }

    /// Converts a negative libgit2 return code into a typed, redacted `GitError`.
    static func check(_ code: Int32, context: OperationContext? = nil) throws {
        guard code < 0 else { return }
        throw GitError.from(code: code, context: context)
    }

    static func string(_ pointer: UnsafePointer<CChar>?) -> String? {
        pointer.map { String(cString: $0) }
    }
}

/// libgit2 linked version, e.g. "1.9.2".
public func libgit2Version() -> String {
    LibGit2.ensureInitialized()
    var major: Int32 = 0, minor: Int32 = 0, patch: Int32 = 0
    git_libgit2_version(&major, &minor, &patch)
    return "\(major).\(minor).\(patch)"
}

/// An owned C string array for libgit2 (`git_strarray`). Free happens in `deinit`, so it can be
/// used without closures (closures that capture C pointers upset Swift 6's region checker).
final class CStringArray {
    private let strings: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
    private let count: Int
    var array: git_strarray

    init(_ values: [String]) {
        count = values.count
        strings = .allocate(capacity: max(1, values.count))
        for (i, value) in values.enumerated() {
            strings[i] = strdup(value)
        }
        array = git_strarray(strings: strings, count: values.count)
    }

    deinit {
        for i in 0..<count { free(strings[i]) }
        strings.deallocate()
    }
}

/// An owned C array of object pointers (e.g. commit parents for `git_commit_create`).
final class CPointerArray {
    let pointer: UnsafeMutablePointer<OpaquePointer?>
    let count: Int

    init(_ values: [OpaquePointer?]) {
        count = values.count
        pointer = .allocate(capacity: max(1, values.count))
        pointer.initialize(from: values, count: values.count)
    }

    deinit {
        pointer.deallocate()
    }
}

extension git_oid {
    var hexString: String {
        var copy = self
        var buffer = [CChar](repeating: 0, count: Int(GIT_OID_MAX_HEXSIZE) + 1)
        git_oid_tostr(&buffer, buffer.count, &copy)
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }
}

/// Wraps a raw pointer so it can cross a concurrency boundary. Only used where ownership is
/// handed over completely (the sender never touches the pointer again).
struct UnsafeTransfer<T>: @unchecked Sendable {
    let value: T
}
