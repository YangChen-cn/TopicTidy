import Foundation

/// Single source of truth for the product version and identity.
///
/// `scripts/build_app.sh`, the release workflow and the Homebrew tap all read
/// this value; the app bundle's `CFBundleShortVersionString` is generated from
/// it, so the two cannot drift.
public enum AppInfo {
    public static let version = "0.10.1"
    public static let name = "TopicTidy"
    public static let tagline = "本地、可解释、可撤销的 Downloads 整理器"
    public static let author = "Yang Chen"
    public static let repository = "https://github.com/YangChen-cn/TopicTidy"
    public static let license = "MIT"

    /// Version shown to people: the bundle's, when running inside the app.
    public static var displayVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? version
    }
}
