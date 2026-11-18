import AppKit
import ApplicationServices
import Darwin

/// App activation alone can choose the wrong Space when one app has several windows.
/// Resolve this small, optional system bridge at runtime; no synthetic mouse events.
enum WindowActivation {
    private typealias FrontWindow = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UInt32, UInt32) -> Int32
    private typealias ProcessNumber = @convention(c) (Int32, UnsafeMutablePointer<ProcessSerialNumber>) -> Int32
    private static let frontWindow: FrontWindow? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_SLPSSetFrontProcessWithOptions") else { return nil }
        return unsafeBitCast(symbol, to: FrontWindow.self)
    }()
    private static let processNumber: ProcessNumber? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "GetProcessForPID") else { return nil }
        return unsafeBitCast(symbol, to: ProcessNumber.self)
    }()

    static var isAvailable: Bool { frontWindow != nil && processNumber != nil }

    static func front(pid: pid_t, windowID: CGWindowID?) -> Bool {
        guard let windowID, windowID != 0, let frontWindow, let processNumber else { return false }
        var number = ProcessSerialNumber()
        guard processNumber(pid, &number) == 0 else { return false }
        // Request the selected window as a user-initiated switch, without raising all app windows.
        return frontWindow(&number, windowID, 0x200) == 0
    }
}
