import Foundation

/// HCG Sentinel's product page on HCG Repo, shown in Settings › About.
///
/// A fixed HTTPS address with no query, fragment or account, session or device identifier. Sentinel never
/// requests it: iOS opens it in Safari, and only when the user taps the row.
public enum HCGRepoLink {
    public static let productPage = URL(string: "https://repo.hakmicapitalgroup.com/products/hcg-sentinel/")!

    /// HTTPS with a host and nothing that could carry an identifier (no query, fragment, user, password or port).
    public static func isOpenable(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host != nil && url.query == nil && url.fragment == nil
            && url.user == nil && url.password == nil && url.port == nil
    }
}
