import Foundation
import ProcessKit

/// Every operation has one body that runs on the calling thread and stops when its flag is set. The
/// async calls run it on a thread of its own (no I/O on the caller's actor, Swift's threads stay free),
/// stopped by cancelling the task or by the caller's flag; the `Sync` calls run it in place.
enum Work {
    static func run<T: Sendable>(_ cancel: Shell.CancelFlag?, _ body: @escaping @Sendable (Shell.CancelFlag) throws -> T) async throws -> T {
        try Task.checkCancellation()
        if cancel?.isCancelled == true { throw CancellationError() }
        let stop = Shell.CancelFlag()
        let finished = Shell.CancelFlag()
        defer { finished.cancel() }
        if let cancel {
            // The caller's flag stops this work without this work setting the caller's flag.
            Thread.detachNewThread {
                while !finished.isCancelled, !stop.isCancelled {
                    if cancel.isCancelled { stop.cancel(); break }
                    Thread.sleep(forTimeInterval: 0.05)
                }
            }
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, any Error>) in
                Thread.detachNewThread {
                    continuation.resume(with: Result { try body(stop) })
                }
            }
        } onCancel: {
            stop.cancel()
        }
    }

    /// Throws `CancellationError` once the flag is set.
    static func check(_ stop: Shell.CancelFlag) throws {
        if stop.isCancelled { throw CancellationError() }
    }
}

/// ditto, unzip, zip and tar through ProcessKit, stopped by the work's flag.
enum Tool {
    static func run(_ tool: String, _ arguments: [String], _ options: Shell.Options = Shell.Options(), stop: Shell.CancelFlag) throws -> Shell.Output {
        try Work.check(stop)
        var options = options
        options.cancel = stop
        return try Shell.runSync(tool, arguments, options: options)
    }
}
