import AppKit

/// Gives a specific window keyboard focus and brings its app to the front.
///
/// Since macOS 14, an app in the background can't reliably activate another app
/// through public API (setting AXFrontmost is often ignored). The window server's
/// own calls still work; yabai, AeroSpace and Amethyst use the same two. They're
/// looked up at runtime, so if a future macOS removes them Tessel falls back to
/// the Accessibility route instead of failing to launch.
enum WindowFocus {
    private typealias SetFrontProcess = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UInt32, UInt32) -> Int32
    private typealias PostEventRecord = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt8>) -> Int32
    private typealias ProcessForPID = @convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> Int32

    private static let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    private static let setFrontProcess = skyLight.flatMap { dlsym($0, "_SLPSSetFrontProcessWithOptions") }
        .map { unsafeBitCast($0, to: SetFrontProcess.self) }
    private static let postEventRecord = skyLight.flatMap { dlsym($0, "SLPSPostEventRecordTo") }
        .map { unsafeBitCast($0, to: PostEventRecord.self) }
    private static let processForPID = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "GetProcessForPID")
        .map { unsafeBitCast($0, to: ProcessForPID.self) }

    static var isAvailable: Bool { setFrontProcess != nil && postEventRecord != nil && processForPID != nil }

    /// Returns false when the window server route isn't available or refused.
    static func focus(pid: pid_t, windowID: CGWindowID) -> Bool {
        guard let setFrontProcess, let postEventRecord, let processForPID else { return false }
        var psn = ProcessSerialNumber()
        guard processForPID(pid, &psn) == 0 else { return false }
        // 0x200: activated as if by the user (kCPSUserGenerated).
        guard setFrontProcess(&psn, windowID, 0x200) == 0 else { return false }

        // Make that exact window key, not just the app's last-used window.
        var bytes = [UInt8](repeating: 0, count: 0xF8)
        bytes[0x04] = 0xF8
        bytes[0x3A] = 0x10
        withUnsafeBytes(of: windowID.littleEndian) { raw in
            for (i, b) in raw.enumerated() { bytes[0x3C + i] = b }
        }
        for i in 0x20..<0x30 { bytes[i] = 0xFF }
        for kind: UInt8 in [0x01, 0x02] {
            bytes[0x08] = kind
            _ = bytes.withUnsafeMutableBufferPointer { postEventRecord(&psn, $0.baseAddress!) }
        }
        return true
    }
}
