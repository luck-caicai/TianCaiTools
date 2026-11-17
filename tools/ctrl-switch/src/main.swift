import AppKit
import ApplicationServices
import ServiceManagement

if CommandLine.arguments.contains("--live-status") {
    let center = DistributedNotificationCenter.default()
    let request = UUID().uuidString
    var received = false
    let token = center.addObserver(forName: Notification.Name("local.ctrlswitch.statusResponse"),
        object: request, queue: .main) { notification in
            guard let json = notification.userInfo?["json"] as? String else { return }
            print(json)
            received = true
        }
    center.postNotificationName(Notification.Name("local.ctrlswitch.statusRequest"), object: nil,
        userInfo: ["request": request], deliverImmediately: true)
    let deadline = Date().addingTimeInterval(3)
    while !received, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
    center.removeObserver(token)
    if !received { fputs("No running CtrlSwitch responded.\n", stderr); exit(1) }
} else if CommandLine.arguments.contains("--diagnose") {
    let values: [String: Any] = [
        "name": "Ctrl 开关",
        "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development",
        "accessibilityGranted": AXIsProcessTrusted(),
        "bundleIdentifier": Bundle.main.bundleIdentifier ?? "",
        "bundlePath": Bundle.main.bundlePath,
        "launchAtLoginStatus": SMAppService.mainApp.status.rawValue,
        "architecture": "arm64",
        "screenRecordingGranted": CGPreflightScreenCaptureAccess(),
        "windowPreviewSupported": ProcessInfo.processInfo.isOperatingSystemAtLeast(
            OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)),
        "shortcuts": ["Ctrl+C", "Ctrl+V", "Ctrl+S", "Ctrl+A", "Ctrl+X", "Ctrl+F", "Ctrl+Z"]
    ]
    if let data = try? JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys]),
       let output = String(data: data, encoding: .utf8) { print(output) }
} else {
    let application = NSApplication.shared
    let delegate = AppDelegate()
    application.delegate = delegate
    withExtendedLifetime(delegate) { application.run() }
}
