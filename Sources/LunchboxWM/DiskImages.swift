import DiskArbitration
import Foundation

/// The disk images mounted right now, by volume name. An app downloaded as a .dmg opens in a
/// small Finder window of its own ("drag the app to Applications"), titled with the image's
/// name and drawn at the size its maker chose: tiled, it would stretch around a fixed picture.
///
/// Read from the mount table and Disk Arbitration only: nothing looks inside a volume, so macOS
/// never asks about access to removable volumes.
enum DiskImages {
    private static let lock = NSLock()
    private static var cache: (at: Date, names: Set<String>)?

    /// Whether a disk image with this volume name is mounted (checked at most every 2 s).
    static func isMounted(named name: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if cache == nil || Date().timeIntervalSince(cache!.at) > 2 { cache = (Date(), mountedNames()) }
        return cache!.names.contains(name)
    }

    private static func mountedNames() -> Set<String> {
        var list: UnsafeMutablePointer<statfs>?
        let count = getmntinfo_r_np(&list, MNT_NOWAIT)
        guard count > 0, let list, let session = DASessionCreate(kCFAllocatorDefault) else { return [] }
        defer { free(list) }
        var names: Set<String> = []
        for i in 0..<Int(count) {
            var mount = list[i]
            let on = withUnsafeBytes(of: &mount.f_mntonname) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            let from = withUnsafeBytes(of: &mount.f_mntfromname) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            guard on.hasPrefix("/Volumes/"), from.hasPrefix("/dev/"),
                  let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, String(from.dropFirst(5))),
                  let info = DADiskCopyDescription(disk) as? [String: Any],
                  (info[kDADiskDescriptionDeviceModelKey as String] as? String)?.trimmingCharacters(in: .whitespaces) == "Disk Image"
            else { continue }
            if let name = info[kDADiskDescriptionVolumeNameKey as String] as? String { names.insert(name) }
            names.insert((on as NSString).lastPathComponent)
        }
        return names
    }
}
