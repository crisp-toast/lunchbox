import AppKit

/// The apps from the one used last to the one used longest ago, as macOS keeps them for ⌘-Tab:
/// it goes back before Lunchbox started, so Sort My Windows knows which windows you used last
/// even right after setup. Private LaunchServices calls (the ones ⌘-Tab switchers use), looked up
/// when needed rather than linked, so a macOS without them just means no order: then it's empty.
enum AppOrder {
    private typealias FrontToBack = @convention(c) (Int32, UInt32) -> Unmanaged<CFArray>?
    private typealias Information = @convention(c) (Int32, CFTypeRef, CFString) -> Unmanaged<CFTypeRef>?

    private static let calls: (FrontToBack, Information)? = {
        guard let order = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_LSCopyApplicationArrayInFrontToBackOrder"),
              let info = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_LSCopyApplicationInformationItem") else { return nil }
        return (unsafeBitCast(order, to: FrontToBack.self), unsafeBitCast(info, to: Information.self))
    }()

    /// Process IDs, the app used last first.
    static func frontToBack() -> [pid_t] {
        guard let (order, info) = calls else { return [] }
        let session: Int32 = -2 // this login session
        guard let apps = order(session, 0xFFFF_FFFF)?.takeRetainedValue() as? [CFTypeRef] else { return [] }
        return apps.compactMap { app in
            (info(session, app, "pid" as CFString)?.takeRetainedValue() as? NSNumber).map { pid_t($0.int32Value) }
        }
    }
}
