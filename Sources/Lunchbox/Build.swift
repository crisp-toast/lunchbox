/// Which kind of build this is. It's fixed when Lunchbox is compiled: no setting or environment
/// variable can change it.
///
/// - Development builds take every script command (README, Scripting): scripts/build.sh passes
///   -DLUNCHBOX_DEV, and `swift build` and `swift test` make debug builds. The test VMs, the
///   WindowLab suite and Tyler's Mac run these.
/// - Release builds (scripts/release.sh, the download customers get) take only pause, resume,
///   retile and balance, since any process on the Mac can post a command.
enum Build {
    #if DEBUG || LUNCHBOX_DEV
    /// scripts/release.sh refuses to ship a binary that contains this text.
    static let name = "development build (takes every script command)"
    #else
    static let name = "release build"
    #endif
}
