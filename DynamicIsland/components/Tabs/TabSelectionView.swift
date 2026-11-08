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

    /// Move `draggedID` onto the slot currently occupied by `targetID`.
    static func reorder(_ ids: [String], dragging draggedID: String, onto targetID: String) -> [String] {
        var result = ids
        guard let from = result.firstIndex(of: draggedID),
              let targetIndex = result.firstIndex(of: targetID),
              from != targetIndex else { return ids }
        result.remove(at: from)
        let to = targetIndex > from ? targetIndex - 1 : targetIndex
        result.insert(draggedID, at: to)
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
    @State private var draggedTabID: String?
    @State private var dragOriginX: CGFloat = 0
    @State private var dragTranslation: CGFloat = 0
    @State private var tabFrames: [String: CGRect] = [:]
    var body: some View {
        HStack(spacing: tabSpacing) {
            ForEach(Array(tabs.enumerated()), id: \.element.id) { idx, tab in
                let isSelected = isSelected(tab)
                let activeAccent = tab.accentColor ?? .white

                // Render the tab button
                TabButton(label: tab.label, icon: tab.icon, selected: isSelected) {
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
                // Drag-to-reorder via a plain gesture — deliberately NOT
                // `.onDrag`: a pasteboard drag session spawns a drag-image
                // window at the very top of the screen, which macOS treats as
                // "window dragged to the top edge" and exposes Mission
                // Control right next to the notch.
                .offset(x: draggedTabID == tab.id ? dragTranslation : 0)
                .zIndex(draggedTabID == tab.id ? 1 : 0)
                .scaleEffect(draggedTabID == tab.id ? 1.15 : 1)
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: TabFrameKey.self,
                            value: [tab.id: proxy.frame(in: .global)]
                        )
                    }
                )
                .highPriorityGesture(reorderGesture(for: tab))
                .animation(.smooth, value: draggedTabID)
            }
        }
        .onPreferenceChange(TabFrameKey.self) { tabFrames = $0 }
        .onDisappear {
            if TabBarInteractionState.shared.isReordering {
                TabBarInteractionState.shared.isReordering = false
            }
        }
        .clipShape(Capsule())
        .onAppear {
            ensureValidSelection(with: tabs)
        }
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
    @State private var lastTranslate: CGFloat = 0

    /// Drag horizontally over a neighbouring tab; when the dragged icon's
    /// centre crosses it, swap live and keep the icon under the finger by
    /// shifting the translation by exactly the slot distance.
    private func reorderGesture(for tab: TabModel) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                if draggedTabID != tab.id {
                    draggedTabID = tab.id
                    dragTranslation = 0
                    lastTranslate = 0
                    TabBarInteractionState.shared.isReordering = true
                }
                dragTranslation += value.translation.width - lastTranslate
                lastTranslate = value.translation.width
                swapIfCrossed(tab)
            }
            .onEnded { _ in
                withAnimation(.smooth) {
                    dragTranslation = 0
                }
                draggedTabID = nil
                lastTranslate = 0
                TabBarInteractionState.shared.isReordering = false
            }
    }

    private func swapIfCrossed(_ tab: TabModel) {
        guard let base = tabFrames[tab.id] else { return }
        let dragCenterX = base.midX + dragTranslation
        let ids = tabs.map(\.id)
        for other in tabs where other.id != tab.id {
            guard let frame = tabFrames[other.id],
                  frame.minX <= dragCenterX, dragCenterX <= frame.maxX else { continue }
            let movingRight = frame.midX > base.midX
            let next = TabCatalog.reorder(ids, dragging: tab.id, onto: other.id)
            guard next != ids else { return }
            // Compensate so the icon stays glued to the finger after the slot shift.
            dragTranslation += (movingRight ? -1 : 1) * (frame.width + tabSpacing)
            withAnimation(.smooth) {
                Defaults[.tabOrder] = next
            }
            return
        }
    }
}

#Preview {
    DynamicIslandHeader().environmentObject(DynamicIslandViewModel())
}
