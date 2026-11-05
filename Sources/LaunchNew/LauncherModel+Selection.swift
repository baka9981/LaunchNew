import AppKit
import SwiftUI

// Keyboard selection, opening apps and the per-icon status (new, running, badges).

extension LauncherModel {
    // MARK: - Keyboard selection

    /// Entries the arrow keys move through: the open folder's apps, or the grid pages.
    private var selectablePages: [[GridEntry]] {
        guard let folder = openFolder else { return pages }
        let apps = folder.1.map(GridEntry.app)
        return stride(from: 0, to: max(apps.count, 1), by: folderPerPage).map {
            Array(apps[$0..<min($0 + folderPerPage, apps.count)])
        }
    }

    func isValid(_ pos: GridPos) -> Bool {
        let p = selectablePages
        return p.indices.contains(pos.page) && p[pos.page].indices.contains(pos.slot)
    }

    func moveSelection(dx: Int, dy: Int) {
        let p = selectablePages
        let cols = openFolderID != nil ? folderColumns : columns
        let visiblePage = openFolderID != nil ? (folderScrolls ? 0 : folderPage) : currentPage
        guard var pos = selection, isValid(pos) else {
            if p.indices.contains(visiblePage), !p[visiblePage].isEmpty { selection = GridPos(page: visiblePage, slot: 0) }
            return
        }
        if dx != 0 {
            pos.slot += dx
            if pos.slot < 0 {
                if pos.page > 0 { pos.page -= 1; pos.slot = p[pos.page].count - 1 } else { pos.slot = 0 }
            } else if pos.slot >= p[pos.page].count {
                if pos.page + 1 < p.count { pos.page += 1; pos.slot = 0 } else { pos.slot = p[pos.page].count - 1 }
            }
        }
        if dy != 0 {
            let target = pos.slot + dy * cols
            if target >= 0 && target < p[pos.page].count { pos.slot = target }
        }
        selection = pos
        if openFolderID != nil {
            if pos.page != folderPage { goToFolderPage(pos.page) }
        } else if pos.page != currentPage {
            goToPage(pos.page)
        }
    }

    func activateSelection() {
        if let pos = selection, isValid(pos) {
            activate(selectablePages[pos.page][pos.slot])
        } else if isSearching, case .app(let app)? = pages.first?.first {
            launch(app)
        }
    }

    func activate(_ entry: GridEntry) {
        switch entry {
        case .app(let app):
            if !isEditing { launch(app) }
        case .folder(let folder, _):
            openFolder(folder.id)
        }
    }



    func updateFrequentApps() {
        guard settings.showFrequent else {
            if !frequentApps.isEmpty { frequentApps = [] }
            return
        }
        let limit = columns
        var byID: [String: AppItem] = [:]
        for app in visibleApps { byID[app.id] = app }
        var result = recentIDs.compactMap { byID[$0] }
        if result.count < limit {
            let taken = Set(result.map(\.id))
            let rest = visibleApps.filter { !taken.contains($0.id) && $0.lastUsedDate != nil && $0.custom == nil && $0.id != Bundle.main.bundleIdentifier }
                .sorted { $0.lastUsedDate! > $1.lastUsedDate! }
            result += rest.prefix(limit - result.count)
        }
        let apps = Array(result.prefix(limit))
        if apps != frequentApps { frequentApps = apps }
    }

    func launch(_ app: AppItem) {
        RecentLaunches.record(app.id)
        recentIDs = RecentLaunches.load()
        updateFrequentApps()
        if newAppIDs.contains(app.id) {
            newApps?.new[app.id] = nil
            newApps.map(NewApps.save)
            newAppIDs.remove(app.id)
        }
        onLaunch?(app)
    }

    func updateNewApps() {
        let state = NewApps.update(newApps ?? NewApps.load(), apps: catalog.apps)
        if state != newApps { NewApps.save(state) }
        newApps = state
        let ids = Set(state.new.keys)
        if ids != newAppIDs { newAppIDs = ids }
    }

    func isNew(_ entry: GridEntry) -> Bool {
        guard settings.showNewDot, !newAppIDs.isEmpty else { return false }
        switch entry {
        case .app(let app): return newAppIDs.contains(app.id)
        case .folder(_, let apps): return apps.contains { newAppIDs.contains($0.id) }
        }
    }

    func isRunning(_ entry: GridEntry) -> Bool {
        guard settings.showRunningDot, case .app(let app) = entry else { return false }
        return runningIDs.contains(app.id)
    }

    func badge(_ entry: GridEntry) -> String? {
        guard settings.showBadges, !badges.isEmpty else { return nil }
        switch entry {
        case .app(let app): return badges[app.id]
        case .folder(_, let apps): return DockBadges.sum(apps.compactMap { badges[$0.id] })
        }
    }

    /// 1…9 for the first nine items of the page on screen, while ⌘ is held.
    func shortcutNumber(of entry: GridEntry) -> Int? {
        guard showShortcutNumbers, openFolderID == nil, pages.indices.contains(currentPage),
              let index = pages[currentPage].firstIndex(where: { $0.id == entry.id }), index < 9 else { return nil }
        return index + 1
    }

    /// ⌘1…⌘9.
    func openShortcut(_ number: Int) {
        guard openFolderID == nil, pages.indices.contains(currentPage), number >= 1,
              number <= pages[currentPage].count else { return }
        showShortcutNumbers = false
        activate(pages[currentPage][number - 1])
    }
    func close() { onClose?() }

    /// Click on empty space: leave the folder / jiggle mode first, then close the launcher.
    func backgroundTapped() {
        if showGuide {
            finishGuide()
        } else if showWhatsNew {
            finishWhatsNew()
        } else if showSettings {
            closeSettings()
        } else if sheet != nil {
            sheet = nil
        } else if showHiddenApps {
            closeHiddenApps()
        } else if openFolderID != nil {
            closeFolder()
        } else if !multiSelection.isEmpty {
            withAnimation(.easeOut(duration: 0.15)) { multiSelection = [] }
        } else if isEditing {
            isEditing = false
        } else if settings.clickBackgroundToClose {
            close()
        }
    }

    /// Esc: finish renaming, close the folder, leave jiggle mode, clear the search, then close.
    func escape() {
        if showGuide {
            finishGuide()
        } else if showWhatsNew {
            finishWhatsNew()
        } else if showSettings {
            closeSettings()
        } else if sheet != nil {
            sheet = nil
        } else if showHiddenApps {
            closeHiddenApps()
        } else if isRenaming {
            renameEndRequest += 1
        } else if openFolderID != nil {
            closeFolder()
        } else if !multiSelection.isEmpty {
            withAnimation(.easeOut(duration: 0.15)) { multiSelection = [] }
        } else if isEditing {
            isEditing = false
        } else if isSearching {
            query = ""
        } else {
            close()
        }
    }
}
