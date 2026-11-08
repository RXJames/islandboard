/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * Originally from boring.notch project
 * Modified and adapted for Atoll (DynamicIsland)
 * See NOTICE for details.
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 */

import AtollExtensionKit
import SwiftUI
import Defaults
import AppKit
import UniformTypeIdentifiers

struct TabModel: Identifiable {
    let id: String
    let label: String
    let icon: String
    let view: NotchViews
    let experienceID: String?
    let accentColor: Color?

    init(label: String, icon: String, view: NotchViews, experienceID: String? = nil, accentColor: Color? = nil) {
        self.id = experienceID.map { "extension-\($0)" } ?? "system-\(view)-\(label)"
        self.label = label
        self.icon = icon
        self.view = view
        self.experienceID = experienceID
        self.accentColor = accentColor
    }
}

/// Which feature tabs are enabled. Mirrors the gating expressions used by the
/// settings; `fromDefaults()` is the on-demand form for callers (trackpad tab
/// swipe) that do not need SwiftUI invalidation.
struct TabEnablement {
    var homeVisible: Bool
    var shelf: Bool
    var timer: Bool
    var stats: Bool
    var usage: Bool
    var notes: Bool
    var terminal: Bool

    static func fromDefaults() -> TabEnablement {
        TabEnablement(
            homeVisible: Defaults[.enableMinimalisticUI]
                || Defaults[.showStandardMediaControls]
                || Defaults[.showCalendar]
                || Defaults[.showMirror],
            shelf: Defaults[.dynamicShelf],
            timer: Defaults[.enableTimerFeature] && Defaults[.timerDisplayMode] == .tab,
            stats: Defaults[.enableStatsFeature],
            usage: Defaults[.enableLLMUsageFeature],
            notes: Defaults[.enableNotes]
                || (Defaults[.enableClipboardManager] && Defaults[.clipboardDisplayMode] == .separateTab),
            terminal: Defaults[.enableTerminalFeature]
        )
    }
}

/// Single source of truth for the tab bar contents and the user's ordering.
enum TabCatalog {
    static func extensionTabModels(payloads: [ExtensionNotchExperiencePayload]) -> [TabModel] {
        payloads.compactMap { payload in
            guard let tab = payload.descriptor.tab else { return nil }
            let accent = payload.descriptor.accentColor.swiftUIColor
            let iconName = tab.iconSymbolName ?? "puzzlepiece.extension"
            return TabModel(
                label: tab.title,
                icon: iconName,
                view: .extensionExperience,
                experienceID: payload.descriptor.id,
                accentColor: accent
            )
        }
    }

    @MainActor
    static func extensionTabModels() -> [TabModel] {
        guard Defaults[.enableThirdPartyExtensions],
              Defaults[.enableExtensionNotchExperiences],
              Defaults[.enableExtensionNotchTabs] else { return [] }
        return extensionTabModels(
            payloads: ExtensionNotchExperienceManager.shared.activeExperiences
                .filter { $0.descriptor.tab != nil }
        )
    }

    static func build(_ enablement: TabEnablement, extensionTabs: [TabModel]) -> [TabModel] {
        var tabsArray: [TabModel] = []
        if enablement.homeVisible {
            tabsArray.append(TabModel(label: "Home", icon: "house.fill", view: .home))
        }
        if enablement.shelf {
            tabsArray.append(TabModel(label: "Shelf", icon: "tray.fill", view: .shelf))
        }
        if enablement.timer {
            tabsArray.append(TabModel(label: "Timer", icon: "timer", view: .timer))
        }
        if enablement.stats {
            tabsArray.append(TabModel(label: "Stats", icon: "chart.xyaxis.line", view: .stats))
        }
        if enablement.usage {
            tabsArray.append(TabModel(label: "Usage", icon: "chart.bar.doc.horizontal", view: .llmUsage))
        }
        if enablement.notes {
            let label = Defaults[.enableNotes] ? "Notes" : "Clipboard"
            let icon = Defaults[.enableNotes] ? "note.text" : "doc.on.clipboard"
            tabsArray.append(TabModel(label: label, icon: icon, view: .notes))
        }
        if enablement.terminal {
            tabsArray.append(TabModel(label: "Terminal", icon: "apple.terminal", view: .terminal))
        }
        tabsArray.append(contentsOf: extensionTabs)
        return tabsArray
    }

    /// User-permitted order first (relative to the saved list); ids the order
    /// does not mention (brand-new features) keep their canonical relative
    /// order at the end, so upgrades never hide tabs.
    static func ordered(_ tabs: [TabModel], by order: [String]) -> [TabModel] {
        guard !order.isEmpty else { return tabs }
        let known = tabs.filter { order.contains($0.id) }
            .sorted { order.firstIndex(of: $0.id)! < order.firstIndex(of: $1.id)! }
        let fresh = tabs.filter { !order.contains($0.id) }
        return known + fresh
    }

    /// Remove `draggedID` and re-insert it so exactly `index` entries
    /// precede it (clamped to the ends). The gap model of the drag: the
    /// gap travels, the list follows.
    static func moved(_ ids: [String], dragging draggedID: String, to index: Int) -> [String] {
        var result = ids
        guard let from = result.firstIndex(of: draggedID) else { return ids }
        result.remove(at: from)
        result.insert(draggedID, at: min(max(index, 0), result.count))
        return result
    }

    @MainActor
    static func enabledTabs() -> [TabModel] {
        ordered(build(TabEnablement.fromDefaults(), extensionTabs: extensionTabModels()),
                by: Defaults[.tabOrder])
    }
}

/// Live state of a tab-reorder drag inside the tab bar. Mirrors
/// `ShelfSelectionModel.isDragging`: it vetoes notch auto-close (the pointer
/// legitimately leaves the notch while dragging) and suppresses the
/// horizontal page-tab gesture so the two never fight.
@MainActor final class TabBarInteractionState {
    static let shared = TabBarInteractionState()
    var isReordering = false
    private init() {}
}

/// Preference carrying every tab's global frame for hit-testing the reorder drag.
private struct TabFrameKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

struct TabSelectionView: View {
    @ObservedObject var coordinator = DynamicIslandViewCoordinator.shared
    @ObservedObject private var extensionNotchExperienceManager = ExtensionNotchExperienceManager.shared
    @StateObject private var quickShareService = QuickShareService.shared
    @Default(.quickShareProvider) private var quickShareProvider
    @State private var showQuickSharePopover = false
    @Default(.enableTimerFeature) var enableTimerFeature
    @Default(.enableStatsFeature) var enableStatsFeature
    @Default(.enableColorPickerFeature) var enableColorPickerFeature
    @Default(.timerDisplayMode) var timerDisplayMode
    @Default(.enableThirdPartyExtensions) private var enableThirdPartyExtensions
    @Default(.enableExtensionNotchExperiences) private var enableExtensionNotchExperiences
    @Default(.enableExtensionNotchTabs) private var enableExtensionNotchTabs
    @Default(.showCalendar) private var showCalendar
    @Default(.showMirror) private var showMirror
    @Default(.showStandardMediaControls) private var showStandardMediaControls
    @Default(.enableMinimalisticUI) private var enableMinimalisticUI
    @Default(.tabOrder) private var tabOrder
    @Namespace var animation

    private var tabs: [TabModel] {
        // The @Default properties above keep this view reactive to feature
        // toggles; TabCatalog owns the shared gating/order logic.
        let enablement = TabEnablement(
            homeVisible: homeTabVisible,
            shelf: Defaults[.dynamicShelf],
            timer: enableTimerFeature && timerDisplayMode == .tab,
            stats: Defaults[.enableStatsFeature],
            usage: Defaults[.enableLLMUsageFeature],
            notes: Defaults[.enableNotes]
                || (Defaults[.enableClipboardManager] && Defaults[.clipboardDisplayMode] == .separateTab),
            terminal: Defaults[.enableTerminalFeature]
        )
        return TabCatalog.ordered(
            TabCatalog.build(
                enablement,
                extensionTabs: extensionTabsEnabled
                    ? TabCatalog.extensionTabModels(payloads: extensionTabPayloads)
                    : []
            ),
            by: tabOrder
        )
    }
    // Dock-style reorder state. The live order is NOT committed while
    // dragging: `previewOrder` is a scratch copy, the dragged icon floats
    // in an overlay following the finger, and its old slot renders as a
    // gap that slides between neighbours. Positions are decided against
    // frames captured at drag start, so animated neighbour movement can
    // never feed back into the hit test (the old live-swap version raced
    // its own preference updates and stuttered).
    @State private var draggedTabID: String?
    @State private var previewOrder: [String] = []
    @State private var dragPointerX: CGFloat = 0
    @State private var dragStartFrames: [String: CGRect] = [:]
    @State private var gapWidth: CGFloat = 32
    @State private var tabFrames: [String: CGRect] = [:]

    private static let dragSpace = "atollTabDrag"
    private var dragSettle: Animation { .spring(response: 0.28, dampingFraction: 0.82) }

    private var displayOrder: [String] {
        draggedTabID == nil ? tabs.map(\.id) : previewOrder
    }

    private var draggedTab: TabModel? {
        guard let id = draggedTabID else { return nil }
        return tabs.first { $0.id == id }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            HStack(spacing: tabSpacing) {
                ForEach(displayOrder, id: \.self) { id in
                    // The dragged tab MUST stay in the hierarchy as the
                    // exact same view: its DragGesture owns the session, and
                    // swapping it for another branch (e.g. a gap) destroys
                    // the gesture mid-drag — the drag freezes, onEnded never
                    // fires and the reorder veto leaks, sticking the notch
                    // open. It rides the slot as an invisible host instead.
                    if let tab = tabs.first(where: { $0.id == id }) {
                        tabButton(tab)
                            .opacity(draggedTabID == tab.id ? 0 : 1)
                    }
                }
            }

            if let tab = draggedTab {
                // The lifted icon: follows the finger, casts a shadow,
                // ignores touches so the drag stays with its source view.
                tabButton(tab, floating: true)
                    .frame(width: gapWidth, height: 26)
                    .shadow(color: .black.opacity(0.35), radius: 8, y: 4)
                    .offset(x: dragPointerX - gapWidth / 2, y: 0)
                    .allowsHitTesting(false)
            }
        }
        .coordinateSpace(name: Self.dragSpace)
        .onPreferenceChange(TabFrameKey.self) { tabFrames = $0 }
        .onDisappear {
            if TabBarInteractionState.shared.isReordering {
                TabBarInteractionState.shared.isReordering = false
                draggedTabID = nil
            }
        }
        .onAppear {
            ensureValidSelection(with: tabs)
        }
    }

    /// One tab bar item. `floating` renders the lifted drag copy (bigger,
    /// no tap action, no gesture); both variants carry the same
    /// matched-geometry id so releasing glides the icon into its slot.
    @ViewBuilder
    private func tabButton(_ tab: TabModel, floating: Bool = false) -> some View {
        let isSelected = isSelected(tab)
        let activeAccent = tab.accentColor ?? .white

        let base = TabButton(label: tab.label, icon: tab.icon, selected: isSelected) {
            if tab.view == .extensionExperience {
                coordinator.selectedExtensionExperienceID = tab.experienceID
            }
            coordinator.currentView = tab.view
        }
        .frame(height: 26)
        .foregroundStyle(isSelected ? activeAccent : .gray)
        .background {
            if isSelected {
                Capsule()
                    .fill((tab.accentColor ?? Color(nsColor: .secondarySystemFill)).opacity(0.25))
                    .shadow(color: (tab.accentColor ?? .clear).opacity(0.4), radius: 8)
                    .matchedGeometryEffect(id: "capsule", in: animation)
            } else {
                Capsule()
                    .fill(Color.clear)
                    .matchedGeometryEffect(id: "capsule", in: animation)
                    .hidden()
            }
        }
        .background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: TabFrameKey.self,
                    value: [tab.id: proxy.frame(in: .named(Self.dragSpace))]
                )
            }
        )
        .scaleEffect(floating ? 1.15 : 1)

        if floating {
            base
        } else {
            draggable(base, tab)
        }
    }

    // Drag-to-reorder via a plain gesture — deliberately NOT
    // `.onDrag`: a pasteboard drag session spawns a drag-image
    // window at the very top of the screen, which macOS treats as
    // "window dragged to the top edge" and exposes Mission
    // Control right next to the notch.
    @ViewBuilder
    private func draggable(_ view: some View, _ tab: TabModel) -> some View {
        view.highPriorityGesture(reorderGesture(for: tab))
    }

    private var extensionTabsEnabled: Bool {
        enableThirdPartyExtensions && enableExtensionNotchExperiences && enableExtensionNotchTabs
    }

    private var extensionTabPayloads: [ExtensionNotchExperiencePayload] {
        extensionNotchExperienceManager.activeExperiences.filter { $0.descriptor.tab != nil }
    }

    private var homeTabVisible: Bool {
        if enableMinimalisticUI {
            return true
        }
        return showStandardMediaControls || showCalendar || showMirror
    }

    private func isSelected(_ tab: TabModel) -> Bool {
        if tab.view == .extensionExperience {
            return coordinator.currentView == .extensionExperience
                && coordinator.selectedExtensionExperienceID == tab.experienceID
        }
        return coordinator.currentView == tab.view
    }

    private func ensureValidSelection(with tabs: [TabModel]) {
        guard !tabs.isEmpty else { return }
        if tabs.contains(where: { isSelected($0) }) {
            return
        }
        guard let first = tabs.first else { return }
        if first.view == .extensionExperience {
            coordinator.selectedExtensionExperienceID = first.experienceID
        } else {
            coordinator.selectedExtensionExperienceID = nil
        }
        coordinator.currentView = first.view
    }

    private let tabSpacing: CGFloat = 24

    /// Drag horizontally; the neighbours part around a gap that tracks the
    /// finger, and the order commits once on release.
    private func reorderGesture(for tab: TabModel) -> some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .named(Self.dragSpace))
            .onChanged { value in
                if draggedTabID != tab.id {
                    beginDrag(tab)
                }
                guard draggedTabID == tab.id else { return }
                dragPointerX = value.location.x
                updateGapInsertion()
            }
            .onEnded { _ in
                endDrag()
            }
    }

    private func beginDrag(_ tab: TabModel) {
        guard let own = tabFrames[tab.id] else { return }
        gapWidth = own.width
        dragStartFrames = tabFrames
        previewOrder = tabs.map(\.id)
        draggedTabID = tab.id
        TabBarInteractionState.shared.isReordering = true
    }

    /// Where the gap belongs: the count of neighbours whose (frozen,
    /// drag-start) centre sits left of the finger. Frozen frames keep the
    /// decision stable while the neighbours are mid-animation.
    private func updateGapInsertion() {
        guard let dragID = draggedTabID else { return }
        let neighbours = previewOrder.filter { $0 != dragID }
        let insertAt = neighbours.count { (dragStartFrames[$0]?.midX ?? .infinity) < dragPointerX }
        guard previewOrder.firstIndex(of: dragID) != insertAt else { return }
        let order = TabCatalog.moved(previewOrder, dragging: dragID, to: insertAt)
        withAnimation(dragSettle) {
            previewOrder = order
        }
    }

    private func endDrag() {
        guard draggedTabID != nil else { return }
        let finalOrder = previewOrder
        withAnimation(dragSettle) {
            // Same-id matched geometry: the floating icon glides from the
            // finger into the gap as it becomes a real slot again.
            Defaults[.tabOrder] = finalOrder
            draggedTabID = nil
            previewOrder = []
        }
        TabBarInteractionState.shared.isReordering = false
    }
}

#Preview {
    DynamicIslandHeader().environmentObject(DynamicIslandViewModel())
}
