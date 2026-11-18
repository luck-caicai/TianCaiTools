import AppKit
import ApplicationServices
import Darwin

/// App activation alone can choose the wrong Space when one app has several windows.
/// Resolve these optional system bridges at runtime, without moving the user's cursor.
enum WindowActivation {
    private typealias FrontWindow = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UInt32, UInt32) -> Int32
    private typealias ProcessNumber = @convention(c) (Int32, UnsafeMutablePointer<ProcessSerialNumber>) -> Int32
    private typealias KeyRecord = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt8>) -> Int32
    private static let frontWindow: FrontWindow? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_SLPSSetFrontProcessWithOptions") else { return nil }
        return unsafeBitCast(symbol, to: FrontWindow.self)
    }()
    private static let processNumber: ProcessNumber? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "GetProcessForPID") else { return nil }
        return unsafeBitCast(symbol, to: ProcessNumber.self)
    }()
    private static let keyRecord: KeyRecord? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "SLPSPostEventRecordTo") else { return nil }
        return unsafeBitCast(symbol, to: KeyRecord.self)
    }()

    static var isAvailable: Bool { frontWindow != nil && processNumber != nil }
    static var canMakeKey: Bool { keyRecord != nil && processNumber != nil }

    static func front(pid: pid_t, windowID: CGWindowID?) -> Bool {
        guard let windowID, windowID != 0, let frontWindow, let processNumber else { return false }
        var number = ProcessSerialNumber()
        guard processNumber(pid, &number) == 0 else { return false }
        // Request the selected window as a user-initiated switch, without raising all app windows.
        return frontWindow(&number, windowID, 0x200) == 0
    }

    static func makeKey(pid: pid_t, windowID: CGWindowID?) -> Bool {
        guard let windowID, windowID != 0, let keyRecord, let processNumber else { return false }
        var number = ProcessSerialNumber()
        guard processNumber(pid, &number) == 0 else { return false }
        var success = true
        // Always deliver the matching up, including when down reports an error. No AX calls or
        // cancellation checks are placed between the two edges of this short process-local pair.
        for var bytes in WindowKeyRecords.pair(windowID: windowID) {
            let result = bytes.withUnsafeMutableBufferPointer { keyRecord(&number, $0.baseAddress!) }
            success = result == 0 && success
        }
        return success
    }
}
