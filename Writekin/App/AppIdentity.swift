import Foundation

/// THE single place the app's brand identity lives. Every user-facing
/// string and project URL references these constants, so renaming the app
/// is a change HERE plus the short build-side checklist below — not a hunt
/// through the codebase.
///
/// ## Rename checklist
/// 1. Change `appName` (and the URLs, if the repo moves) below.
/// 2. project.yml: `name:`, target names, `INFOPLIST_KEY_CFBundleDisplayName`,
///    and `SUFeedURL`; rename the source folders and `@testable import`s to
///    match the new module name; scripts/release.sh artifact names.
/// 3. Docs: README.md, NOTICE.md, RELEASING.md.
///
/// ## FROZEN — never change on a rename without a data migration
/// These identify EXISTING installs' data; changing any of them orphans
/// a user's database and settings:
/// - `PRODUCT_BUNDLE_IDENTIFIER` (com.scottgoci.writekin)
/// - the Application Support folder name ("Writekin")
/// - the database filename (writekin.sqlite)
/// - settings keys and the os.log subsystem string
enum AppIdentity {
    static let appName = "Writekin"

    static let repoURL = URL(string: "https://github.com/scouttyg/writekin")!
    static let readmeURL = URL(string: "https://github.com/scouttyg/writekin#readme")!
    static let issuesURL = URL(string: "https://github.com/scouttyg/writekin/issues")!
    static let licenseURL = URL(string: "https://github.com/scouttyg/writekin/blob/main/LICENSE.md")!

    static let copyrightLine = "© 2026 Scott Goci"
    static let licenseTagline = "Source-available, free for personal use"

    /// FROZEN (see header): identifies existing installs' log streams, so
    /// it must always equal the bundle identifier they shipped with.
    static let logSubsystem = "com.scottgoci.writekin"

    /// FROZEN (see header): the Application Support folder that holds the
    /// database and the Tools/Models/Adapters stores. Deliberately a literal,
    /// not derived from `appName` — a rebrand must not move user data.
    static var storageRoot: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/Writekin")
    }

    /// FROZEN (see header): the database filename inside `storageRoot`.
    static let databaseFileName = "writekin.sqlite"

    /// Prefix for temp work folders ("writekin-imessage-…") and default
    /// export names. Derived from `appName`: temp dirs are ephemeral and
    /// exports are user-visible, so both should follow the brand.
    static var lowercaseName: String { appName.lowercased() }
}
