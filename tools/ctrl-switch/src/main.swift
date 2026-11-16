import AppKit
import ApplicationServices
import ServiceManagement

if CommandLine.arguments.contains("--diagnose") {
    let values: [String: Any] = [
        "name": "Ctrl 开关",
        "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development",
        "accessibilityGranted": AXIsProcessTrusted(),
        "bundleIdentifier": Bundle.main.bundleIdentifier ?? "",
        "bundlePath": Bundle.main.bundlePath,
        "launchAtLoginStatus": SMAppService.mainApp.status.rawValue,
        "architecture": "arm64",
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
