import Foundation
import SwiftUI

struct Folder: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var apps: [String]
    /// Set for smart folders: a search such as "#设计 #常用" that decides the contents; `apps` stays empty.
    var query: String?
    /// Tint of the folder tile, a `FolderColor` raw value; nil is the plain glass.
    var color: String?

    init(id: String = UUID().uuidString, name: String, apps: [String], query: String? = nil) {
        self.id = id
        self.name = name
        self.apps = apps
        self.query = query
    }

    var isSmart: Bool { query != nil }
}

enum FolderColor: String, CaseIterable {
    case red, orange, yellow, green, mint, blue, purple, pink, gray

    var color: Color {
        switch self {
        case .red: Color(red: 1, green: 0.27, blue: 0.23)
        case .orange: Color(red: 1, green: 0.58, blue: 0)
        case .yellow: Color(red: 1, green: 0.8, blue: 0)
        case .green: Color(red: 0.2, green: 0.78, blue: 0.35)
        case .mint: Color(red: 0, green: 0.78, blue: 0.75)
        case .blue: Color(red: 0, green: 0.48, blue: 1)
        case .purple: Color(red: 0.69, green: 0.32, blue: 0.87)
        case .pink: Color(red: 1, green: 0.18, blue: 0.33)
        case .gray: Color(red: 0.56, green: 0.56, blue: 0.58)
        }
    }

    var title: String {
        switch self {
        case .red: String(localized: "红色")
        case .orange: String(localized: "橙色")
        case .yellow: String(localized: "黄色")
        case .green: String(localized: "绿色")
        case .mint: String(localized: "薄荷绿")
        case .blue: String(localized: "蓝色")
        case .purple: String(localized: "紫色")
        case .pink: String(localized: "粉色")
        case .gray: String(localized: "灰色")
        }
    }
}

/// One cell of the home grid.
enum LayoutItem: Codable, Hashable, Identifiable {
    case app(String)
    case folder(Folder)

    var id: String {
        switch self {
        case .app(let id): "app:" + id
        case .folder(let folder): "folder:" + folder.id
        }
    }

    var appIDs: [String] {
        switch self {
        case .app(let id): [id]
        case .folder(let folder): folder.apps
        }
    }
}

/// Per-app extras, edited from the right-click menu.
struct AppMeta: Codable, Hashable {
    /// Name shown under the icon instead of the app's own.
    var displayName: String?
    /// Extra names that only matter to search.
    var aliases: [String] = []
    /// Tag names.
    var tags: [String] = []
    var hidden = false
    /// Icon picked by the user: an SF Symbol ("symbol:…") or an image file in `CustomIcons`.
    var icon: String?

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName)
        aliases = try c.decodeIfPresent([String].self, forKey: .aliases) ?? []
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        hidden = try c.decodeIfPresent(Bool.self, forKey: .hidden) ?? false
        icon = try c.decodeIfPresent(String.self, forKey: .icon)
    }
}

/// `~/Library/Application Support/LaunchNew/{layout,meta}.json`
enum LayoutStore {
    struct LayoutFile: Codable {
        var version = 1
        var pages: [[LayoutItem]]
    }

    /// Tests point this at a temporary folder.
    nonisolated(unsafe) static var directoryOverride: URL?

    static var directory: URL {
        if let directoryOverride { return directoryOverride }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LaunchNew", isDirectory: true)
    }
    static var layoutURL: URL { directory.appendingPathComponent("layout.json") }
    static var metaURL: URL { directory.appendingPathComponent("meta.json") }

    static func loadLayout() -> [[LayoutItem]]? {
        guard let data = try? Data(contentsOf: layoutURL) else { return nil }
        return (try? JSONDecoder().decode(LayoutFile.self, from: data))?.pages
    }

    static func loadMeta() -> [String: AppMeta] {
        guard let data = try? Data(contentsOf: metaURL) else { return [:] }
        return (try? JSONDecoder().decode([String: AppMeta].self, from: data)) ?? [:]
    }

    static func save(layout: [[LayoutItem]]) {
        write(LayoutFile(pages: layout), to: layoutURL)
        AutoBackup.schedule()
        ICloudSync.localChanged()
    }

    static func save(meta: [String: AppMeta]) {
        write(meta.filter { $0.value != AppMeta() }, to: metaURL)
        AutoBackup.schedule()
        ICloudSync.localChanged()
    }

    private static func write<T: Encodable>(_ value: T, to url: URL) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(value).write(to: url, options: .atomic)
        } catch {
            NSLog("LaunchNew: failed to save \(url.lastPathComponent): \(error)")
        }
    }
}

enum LayoutOps {
    /// Drops uninstalled / hidden apps, appends new apps at the end, and repacks pages
    /// so none exceeds `perPage`. Empty pages are removed.
    static func reconcile(_ pages: [[LayoutItem]], installed: [AppItem], hidden: Set<String>, perPage: Int) -> [[LayoutItem]] {
        let valid = Set(installed.map(\.id)).subtracting(hidden)
        var placed = Set<String>()

        var result: [[LayoutItem]] = pages.map { page in
            page.compactMap { item in
                switch item {
                case .app(let id):
                    guard valid.contains(id), placed.insert(id).inserted else { return nil }
                    return item
                case .folder(var folder):
                    if folder.isSmart { return item }
                    folder.apps = folder.apps.filter { valid.contains($0) && placed.insert($0).inserted }
                    return folder.apps.isEmpty ? nil : .folder(folder)
                }
            }
        }

        let newApps = installed.filter { valid.contains($0.id) && !placed.contains($0.id) }
        if !newApps.isEmpty {
            if result.isEmpty { result = [[]] }
            result[result.count - 1].append(contentsOf: newApps.map { .app($0.id) })
        }
        return repack(result, perPage: perPage)
    }

    /// Pushes overflow forward page by page and removes empty pages.
    static func repack(_ pages: [[LayoutItem]], perPage: Int) -> [[LayoutItem]] {
        var result = pages
        var i = 0
        while i < result.count {
            if result[i].count > perPage {
                let overflow = Array(result[i][perPage...])
                result[i].removeLast(result[i].count - perPage)
                if i + 1 < result.count {
                    result[i + 1].insert(contentsOf: overflow, at: 0)
                } else {
                    result.append(overflow)
                }
            }
            i += 1
        }
        result.removeAll { $0.isEmpty }
        return result
    }

    /// Default layout: everything alphabetically, like a fresh Launchpad.
    static func alphabetical(_ apps: [AppItem], perPage: Int) -> [[LayoutItem]] {
        repack([apps.map { .app($0.id) }], perPage: perPage)
    }
}

/// Folder names for apps' `LSApplicationCategoryType`, used when dropping one app onto another.
enum AppCategoryName {
    static func folderName(for categories: [String?]) -> String {
        let known = categories.compactMap { $0 }
        if let first = known.first, known.allSatisfy({ $0 == first }), let name = names[first] {
            return name
        }
        return String(localized: "未命名文件夹")
    }

    /// Tag name for a category, used for the one-time initial tags.
    static func tagName(for category: String?) -> String? {
        category.flatMap { names[$0] }
    }

    private static let names: [String: String] = [
        "public.app-category.developer-tools": String(localized: "开发工具"),
        "public.app-category.productivity": String(localized: "效率"),
        "public.app-category.utilities": String(localized: "实用工具"),
        "public.app-category.social-networking": String(localized: "社交"),
        "public.app-category.music": String(localized: "音乐"),
        "public.app-category.video": String(localized: "影音"),
        "public.app-category.entertainment": String(localized: "娱乐"),
        "public.app-category.photography": String(localized: "摄影"),
        "public.app-category.graphics-design": String(localized: "设计"),
        "public.app-category.education": String(localized: "教育"),
        "public.app-category.finance": String(localized: "财务"),
        "public.app-category.business": String(localized: "商务"),
        "public.app-category.news": String(localized: "新闻"),
        "public.app-category.reference": String(localized: "参考"),
        "public.app-category.lifestyle": String(localized: "生活"),
        "public.app-category.games": String(localized: "游戏"),
        "public.app-category.weather": String(localized: "天气"),
        "public.app-category.travel": String(localized: "旅行"),
        "public.app-category.healthcare-fitness": String(localized: "健康"),
        "public.app-category.medical": String(localized: "医疗"),
        "public.app-category.sports": String(localized: "运动"),
        "public.app-category.video-games": String(localized: "游戏"),
    ]
}

/// Everything needed to restore a layout elsewhere: pages, folders and per-app extras.
struct LayoutBackup: Codable {
    var app = "LaunchNew"
    var version = 1
    var pages: [[LayoutItem]]
    var meta: [String: AppMeta]
    /// Launch items that aren't apps; missing in older backups.
    var custom: [CustomItem]?
    /// The layout profile the pages belong to ("" is the default one).
    var profile: String?
    /// The other layout profiles; missing in older backups and in iCloud layouts.
    var profiles: [String: [[LayoutItem]]]?

    init(pages: [[LayoutItem]], meta: [String: AppMeta], custom: [CustomItem]? = nil) {
        self.pages = pages
        self.meta = meta
        self.custom = custom
    }

    /// A backup of everything: the pages on screen, launch items and every layout profile.
    init(pages: [[LayoutItem]], meta: [String: AppMeta], custom: [CustomItem], profiles file: LayoutProfiles.File) {
        self.init(pages: pages, meta: meta, custom: custom)
        profile = file.current
        profiles = file.saved.filter { $0.key != file.current }
    }
}

/// Options for rebuilding the layout from scratch ("整理布局 › 自定义规则").
struct LayoutRules: Equatable {
    enum Order: String, CaseIterable { case name, recentlyAdded }
    var keepFolders = true
    var groupByCategory = true
    /// Smallest category that gets its own folder.
    var minFolderSize = 3
    var systemAppsFolder = true
    var foldersFirst = true
    var order: Order = .name
}

extension LayoutOps {
    static func arranged(_ installed: [AppItem], current: [[LayoutItem]], hidden: Set<String>,
                         rules: LayoutRules, perPage: Int) -> [[LayoutItem]] {
        let apps = installed.filter { !hidden.contains($0.id) }
        let byID = Dictionary(apps.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var used = Set<String>()
        var folders: [Folder] = []

        // Existing folders (smart ones always survive).
        for case .folder(var folder) in current.joined() {
            if folder.isSmart { folders.append(folder); continue }
            guard rules.keepFolders else { continue }
            folder.apps = folder.apps.filter { byID[$0] != nil && !used.contains($0) }
            guard folder.apps.count >= 2 else { continue }
            used.formUnion(folder.apps)
            folders.append(folder)
        }

        var remaining = apps.filter { !used.contains($0.id) }
        func byName(_ a: AppItem, _ b: AppItem) -> Bool { a.name.localizedStandardCompare(b.name) == .orderedAscending }

        if rules.systemAppsFolder {
            let system = remaining.filter { $0.url.path.hasPrefix("/System/Applications/") }
            if system.count >= 2 {
                folders.append(Folder(name: String(localized: "系统"), apps: system.sorted(by: byName).map(\.id)))
                let ids = Set(system.map(\.id))
                remaining.removeAll { ids.contains($0.id) }
            }
        }
        if rules.groupByCategory {
            let groups = Dictionary(grouping: remaining) { AppCategoryName.tagName(for: $0.category) ?? "" }
            for (name, members) in groups where !name.isEmpty && members.count >= max(2, rules.minFolderSize) {
                folders.append(Folder(name: name, apps: members.sorted(by: byName).map(\.id)))
                let ids = Set(members.map(\.id))
                remaining.removeAll { ids.contains($0.id) }
            }
        }

        func newest(_ ids: [String]) -> Date { ids.compactMap { byID[$0]?.addedDate }.max() ?? .distantPast }
        func before(_ a: (String, Date), _ b: (String, Date)) -> Bool {
            if rules.order == .recentlyAdded, a.1 != b.1 { return a.1 > b.1 }
            return a.0.localizedStandardCompare(b.0) == .orderedAscending
        }
        let folderItems = folders
            .map { (LayoutItem.folder($0), ($0.name, newest($0.apps))) }
            .sorted { before($0.1, $1.1) }
        let appItems = remaining
            .map { (LayoutItem.app($0.id), ($0.name, $0.addedDate ?? .distantPast)) }
            .sorted { before($0.1, $1.1) }
        let items = rules.foldersFirst
            ? folderItems.map(\.0) + appItems.map(\.0)
            : (folderItems + appItems).sorted { before($0.1, $1.1) }.map(\.0)
        return repack([items], perPage: perPage)
    }
}
