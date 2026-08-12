import Foundation

/// Single source of truth for the app version, for both apps.
/// `scripts/make_app.sh` extracts this value to stamp Info.plist and name the DMG, and
/// `Windows/App/ImageHub.csproj` reads this file at build time to stamp ImageHub.exe --
/// the two have to agree, because they check the same GitHub release and compare it
/// against their own version. CI asserts the exe really does report this number.
enum AppVersion {
    /// 1.7.0 rather than 1.6.4: this release adds a whole platform.
    static let marketing = "1.7.0"

    /// Prefers the bundle version when running from a built .app, falls back to
    /// the compiled-in constant when running via `swift run`.
    static var current: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? marketing
    }
}
