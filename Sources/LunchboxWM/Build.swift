/// Which kind of build this is. It's fixed when LunchboxWM is compiled: no setting or environment
/// variable can change it.
///
/// - Development builds take every script command (README, Scripting): scripts/build.sh passes
///   -DLUNCHBOX_DEV, and `swift build` and `swift test` make debug builds. The test VMs, the
///   WindowLab suite and Tyler's Mac run these.
/// - Release builds (scripts/release.sh, the download customers get) take only pause, resume,
///   retile and balance, since any process on the Mac can post a command.
///
/// Separately, the store's copy: scripts/release.sh passes -DLUNCHBOX_STORE for the signed,
/// notarized download sold on lunchboxwm.com. Only that copy asks for a license and updates itself
/// from the site. A copy built from the source (the repo is public, under the PolyForm Shield
/// license) is free to use: it tiles without a license and never updates itself to the store's copy.
/// `STORE=1 scripts/build.sh` makes a development build that behaves like the store's.
enum Build {
    #if DEBUG || LUNCHBOX_DEV
    /// scripts/release.sh refuses to ship a binary that contains this text.
    static let name = "development build (takes every script command)"
    #else
    static let name = "release build"
    #endif

    #if LUNCHBOX_STORE
    static let isStoreCopy = true
    /// scripts/release.sh checks the binary for this text.
    static let origin = "store copy from lunchboxwm.com (needs a license)"
    #else
    static let isStoreCopy = false
    static let origin = "built from source (free to use)"
    #endif
}
