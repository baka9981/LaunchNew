import Foundation

/// `launchnew://` links, for Shortcuts ("Open URL"), scripts and other launchers.
///
///     launchnew://open                 launchnew://toggle            launchnew://close
///     launchnew://search?q=微信         launchnew://folder?name=工具   launchnew://page?n=2
///     launchnew://settings?tab=general  launchnew://profile?name=工作
enum URLCommand: Equatable {
    case open, toggle, close
    case search(String)
    case folder(String)
    /// 1-based, like the dots.
    case page(Int)
    case settings(SettingsTab?)
    /// Switches to a named layout.
    case profile(String)

    static let scheme = "launchnew"

    init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme,
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        // launchnew://search?q=… puts the command in the host; launchnew:search?q=… in the path.
        let name = (parts.host ?? parts.path).trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
        let query = Dictionary((parts.queryItems ?? []).map { ($0.name.lowercased(), $0.value ?? "") },
                               uniquingKeysWith: { a, _ in a })
        switch name {
        case "", "open", "show": self = .open
        case "toggle": self = .toggle
        case "close", "hide": self = .close
        case "search":
            self = .search(query["q"] ?? query["query"] ?? "")
        case "folder":
            guard let folder = query["name"], !folder.isEmpty else { return nil }
            self = .folder(folder)
        case "page":
            guard let n = Int(query["n"] ?? query["page"] ?? ""), n >= 1 else { return nil }
            self = .page(n)
        case "profile", "layout":
            guard let profile = query["name"] else { return nil }
            self = .profile(profile)
        case "settings":
            self = .settings(query["tab"].flatMap { SettingsTab(rawValue: $0.lowercased()) })
        default:
            return nil
        }
    }
}
