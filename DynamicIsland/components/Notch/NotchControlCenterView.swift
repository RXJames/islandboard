/*
 * IslandBoard (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
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

import SwiftUI
import Combine
import Defaults

/// Control Center-style tab: editable tiles for Wi-Fi, Focus, Night Shift,
/// Dark Mode, volume, brightness and keyboard light. The Edit button reveals
/// per-tile controls - tap `Aa` to cycle through the three sizes, the colour
/// well to re-tint, the minus to hide - and tiles reorder with the same
/// Dock-style gap animation as the tab bar. Everything persists immediately.
/// The Focus tile click turns Focus off; while Focus is off, holding the
/// button shows a row of the user's modes above the grid and releasing over
/// one switches to it.
struct NotchControlCenterView: View {
    @ObservedObject private var state = ControlCenterState.shared
    @ObservedObject private var coordinator = DynamicIslandViewCoordinator.shared
    @State private var configs: [ControlTileConfig] = ControlCenterLayout.load()
    @State private var editing = false
    @State private var toast: String?
    /// Drives the iOS-style jiggle while editing (toggles forever once set).
    @State private var wiggle = false
    // Reorder drag session (whole tile, edit mode only), modelled on the tab
    // bar: the order is a scratch copy while dragging, the dragged tile keeps
    // its slot at zero opacity so the gap rides the pointer, and a floating
    // copy follows the finger. Insertion is decided against frames frozen at
    // drag start, so neighbour movement can never feed back into the hit test.
    @State private var dragKind: ControlTileKind?
    @State private var previewConfigs: [ControlTileConfig] = []
    @State private var dragTranslation: CGSize = .zero
    @State private var dragStartFrames: [ControlTileKind: CGRect] = [:]
    @State private var dragStartRows: [[ControlTileKind]] = []
    @State private var dragTileWidth: CGFloat = 0
    @State private var tileFrames: [ControlTileKind: CGRect] = [:]
    // Corner-grip resize session: continuous stretch width following the
    // pointer; a size commits once the drag reaches 80% toward it.
    @State private var resizeKind: ControlTileKind?
    @State private var resizeBaseWidth: CGFloat = 0
    @State private var resizeLiveWidth: CGFloat?
    // Focus press-and-hold picker: a row of mode icons appears above the
    // grid while the button is held; releasing over one selects it.
    @State private var focusPicking = false
    @State private var focusPressActive = false
    @State private var focusWasOnAtPress = false
    @State private var focusNeedsAccessAtPress = false
    @State private var hoveredFocusMode: String?
    @State private var focusIconFrames: [String: CGRect] = [:]
    private static let gap: CGFloat = 10
    static let tileHeight: CGFloat = 56
    /// The grid scrolls past this; below it the notch hugs the content.
    static let maxVisibleHeight: CGFloat = 300
    private static let dragSettle = Animation.spring(response: 0.28, dampingFraction: 0.82)

    var body: some View {
        VStack(spacing: 12) {
            topBar
            GeometryReader { geo in
                ScrollView(.vertical, showsIndicators: false) {
                    grid(containerWidth: geo.size.width)
                        .padding(.bottom, 4)
                }
                .scrollEdgeBlurFix()
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            ControlCenterState.shared.start()
            updatePreferredHeight()
        }
        .onChange(of: configs) { _, _ in updatePreferredHeight() }
        .onChange(of: focusPicking) { _, _ in updatePreferredHeight() }
        .onChange(of: editing) { _, isEditing in
            if isEditing {
                withAnimation(.easeInOut(duration: 0.32).repeatForever(autoreverses: true)) {
                    wiggle = true
                }
            } else {
                withAnimation(.easeOut(duration: 0.25)) { wiggle = false }
                // Leaving edit mode always releases any dangling interaction
                // veto (gesture ended callbacks can be missed mid-session).
                dragKind = nil
                previewConfigs = []
                dragTranslation = .zero
                dragStartFrames = [:]
                dragStartRows = []
                resizeKind = nil
                resizeLiveWidth = nil
                endFocusPress()
                ControlCenterState.shared.isInteracting = false
            }
            updatePreferredHeight()
        }
        .onDisappear {
            endFocusPress()
            dragKind = nil
            previewConfigs = []
            ControlCenterState.shared.isInteracting = false
        }
        .overlay(alignment: .bottom) {
            if let toast {
                Text(toast)
                    .font(.caption)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, 4)
                    .transition(.opacity)
            }
        }
        .onChange(of: state.lastError) { _, value in
            guard let value else { return }
            toast = value
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                if toast == value { toast = nil }
                state.lastError = nil
            }
        }
    }

    /// Mirrors this view's layout metrics (padding + header + tile rows +
    /// optional hidden strip) so the notch window can size itself to the
    /// grid; consumed by ``dynamicNotchSize``.
    private func updatePreferredHeight() {
        let rows = ControlCenterLayout.packRows(in: configs).count
        var height: CGFloat = 8 + 18 + 12 + 12
        if focusPicking { height += 12 } // the mode row is taller than the header
        if rows > 0 {
            height += CGFloat(rows) * Self.tileHeight + CGFloat(max(0, rows - 1)) * Self.gap
        } else {
            height += 40
        }
        if editing && configs.contains(where: { !$0.visible }) {
            height += 12 + 28
        }
        coordinator.controlCenterPreferredHeight = min(height, Self.maxVisibleHeight)
    }

    /// The Focus picker replaces the header while the button is held so the
    /// mode row always sits above the tiles, never outside the notch window.
    @ViewBuilder
    private var topBar: some View {
        if focusPicking {
            focusPickerRow
        } else {
            header
        }
    }

    private var header: some View {
        HStack {
            Image(systemName: "switch.2")
                .foregroundStyle(.secondary)
            Text("Control Center")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            Button(editing ? "Done" : "Edit") {
                withAnimation(.smooth(duration: 0.2)) { editing.toggle() }
            }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(editing ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
        }
        .frame(height: 18)
    }

    // MARK: Focus picker

    private var focusPickerRow: some View {
        HStack(spacing: 8) {
            Text("Focus")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            if state.focusNeedsPermission {
                Text("Full Disk Access required")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if state.focusModes.isEmpty {
                Text("No Focus modes found")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(state.focusModes) { mode in
                    focusModeIcon(mode)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(height: 30)
        .onPreferenceChange(FocusIconFramesKey.self) { focusIconFrames = $0 }
    }

    private func focusModeIcon(_ mode: FocusModeInfo) -> some View {
        let hovered = hoveredFocusMode == mode.identifier
        let tint = Self.focusModeTint(mode)
        return Image(systemName: mode.symbol)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.35), radius: 1, y: 0.5)
            .frame(width: 28, height: 28)
            .background(Circle().fill(tint.opacity(hovered ? 1.0 : 0.78)))
            .overlay(
                Circle().strokeBorder(.white.opacity(hovered ? 0.95 : 0.4), lineWidth: 1)
            )
            .scaleEffect(hovered ? 1.12 : 1)
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: FocusIconFramesKey.self,
                        value: [mode.identifier: proxy.frame(in: .global)])
                }
            )
            .help(mode.name)
            .accessibilityLabel(Text(mode.name))
    }

    /// Pastel, per-mode tint so the chips read apart at a glance on the dark
    /// notch glass (the old shared 7% white circle was almost invisible).
    /// Do Not Disturb keeps Control Center's indigo; custom modes get a
    /// stable colour derived from their semantic identifier so the same mode
    /// always looks the same across launches.
    private static func focusModeTint(_ mode: FocusModeInfo) -> Color {
        if mode.isDefault { return Color(red: 0.55, green: 0.52, blue: 0.95) }
        let palette: [Color] = [
            Color(red: 0.38, green: 0.64, blue: 0.96),
            Color(red: 0.36, green: 0.79, blue: 0.61),
            Color(red: 0.97, green: 0.67, blue: 0.33),
            Color(red: 0.95, green: 0.55, blue: 0.70),
            Color(red: 0.33, green: 0.76, blue: 0.78),
            Color(red: 0.67, green: 0.54, blue: 0.93),
            Color(red: 0.95, green: 0.81, blue: 0.38)
        ]
        var hash = 0
        for byte in mode.semanticID.utf8 {
            hash = (hash &* 31 &+ Int(byte)) & 0x7fff_ffff
        }
        return palette[hash % palette.count]
    }

    /// Press-and-hold on the Focus tile. Focus on: a click turns it off.
    /// Focus off: the mode row appears while held and the release point picks
    /// the mode. The gesture lives on the tile (high priority) so the panel's
    /// hover-exit veto keeps the notch open for the whole interaction.
    private var focusPressGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                if !focusPressActive {
                    focusPressActive = true
                    focusWasOnAtPress = state.focusOn
                    NSLog("AtollFocus: press focusOn=%@ needsFDA=%@",
                          state.focusOn ? "yes" : "no",
                          state.focusNeedsPermission ? "yes" : "no")
                    if state.focusNeedsPermission {
                        focusNeedsAccessAtPress = true
                    } else if !focusWasOnAtPress {
                        ControlCenterState.shared.isInteracting = true
                        withAnimation(.smooth(duration: 0.18)) { focusPicking = true }
                        // Modes may have been added in Settings since launch.
                        state.reloadFocusModes()
                    }
                }
                guard focusPicking else { return }
                let hit = focusModeHitTest(value.location)
                if hit != hoveredFocusMode {
                    withAnimation(.easeOut(duration: 0.12)) { hoveredFocusMode = hit }
                }
            }
            .onEnded { value in
                let hit = focusPicking ? focusModeHitTest(value.location) : nil
                let turnOff = focusPressActive && focusWasOnAtPress
                let needsAccess = focusNeedsAccessAtPress
                endFocusPress()
                if needsAccess {
                    state.requestFocusPermission()
                } else if turnOff {
                    state.turnFocusOff()
                } else if let hit,
                          let mode = state.focusModes.first(where: { $0.identifier == hit }) {
                    state.selectFocusMode(mode)
                }
            }
    }

    private func focusModeHitTest(_ point: CGPoint) -> String? {
        focusIconFrames.first { $0.value.contains(point) }?.key
    }

    private func endFocusPress() {
        focusPressActive = false
        focusPicking = false
        focusNeedsAccessAtPress = false
        hoveredFocusMode = nil
        focusIconFrames = [:]
        ControlCenterState.shared.isInteracting = false
    }

    // MARK: Grid

    private func grid(containerWidth: CGFloat) -> some View {
        let columns = ControlCenterLayout.columns
        // No minimum: tiles shrink/grow with the notch width so a row of
        // 4 spans always ends exactly at the right edge.
        let cell = max(24, (containerWidth - Self.gap * CGFloat(columns - 1)) / CGFloat(columns))
        let display = dragKind == nil ? configs : previewConfigs
        let rows = ControlCenterLayout.packRows(in: display)
        return VStack(spacing: Self.gap) {
            ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                HStack(spacing: Self.gap) {
                    ForEach(Array(row.enumerated()), id: \.element.id) { colIndex, config in
                        tile(config,
                             width: CGFloat(config.size.columnSpan) * cell
                                 + Self.gap * CGFloat(config.size.columnSpan - 1),
                             cell: cell,
                             stagger: Double(rowIndex + colIndex) * 0.11)
                    }
                }
            }
            if editing {
                hiddenStrip
            } else if rows.isEmpty {
                Text("All tiles hidden - tap Edit to bring them back.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 12)
            }
        }
        .coordinateSpace(name: "ccGrid")
        .onPreferenceChange(TileFramesKey.self) { tileFrames = $0 }
        .overlay(alignment: .topLeading) {
            floatingTile
        }
    }

    /// The lifted copy that rides the pointer (the real tile stays in the
    /// flow at zero opacity, so its slot is the gap that neighbours spring
    /// around - exactly the tab bar's reorder model).
    @ViewBuilder
    private var floatingTile: some View {
        if let kind = dragKind,
           let config = previewConfigs.first(where: { $0.kind == kind }),
           let frame = dragStartFrames[kind] {
            TileBody(config: config,
                     width: dragTileWidth,
                     on: state.isOn(kind),
                     tint: ControlCenterLayout.color(hex: config.tintHex) ?? kind.defaultTint,
                     editing: true,
                     state: state)
                .shadow(color: .black.opacity(0.35), radius: 10, y: 5)
                .scaleEffect(1.04)
                .offset(x: frame.minX + dragTranslation.width,
                        y: frame.minY + dragTranslation.height)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private func tile(_ config: ControlTileConfig, width: CGFloat, cell: CGFloat, stagger: Double) -> some View {
        let on = state.isOn(config.kind)
        let tint = ControlCenterLayout.color(hex: config.tintHex) ?? config.kind.defaultTint
        let stretched = resizeKind == config.kind ? (resizeLiveWidth ?? width) : width
        TileBody(config: config, width: stretched, on: on, tint: tint, editing: editing,
                 state: state)
            .background(tileFrameReader(config.kind))
            .overlay {
                if editing { editChrome(config) }
            }
            .overlay(alignment: .bottomTrailing) {
                if editing {
                    resizeGrip(config, cell: cell)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .wiggle(enabled: editing && dragKind != config.kind, phase: wiggle, delay: stagger)
            .opacity(dragKind == config.kind ? 0 : 1)
            .gesture(editing ? reorderGesture(config) : nil)
            .highPriorityGesture(!editing && config.kind == .focus ? focusPressGesture : nil)
    }

    /// Captures each tile's frame in the grid's coordinate space so a drag
    /// can hit-test where the pointer (with the carried tile) lands.
    private func tileFrameReader(_ kind: ControlTileKind) -> some View {
        GeometryReader { proxy in
            Color.clear.preference(key: TileFramesKey.self,
                                   value: [kind: proxy.frame(in: .named("ccGrid"))])
        }
    }

    /// Whole-tile drag, mirroring the tab bar: the order is a scratch copy
    /// committed on release, the dragged tile's slot stays in place, and only
    /// the gaps between neighbours animate while the tile is carried.
    private func reorderGesture(_ config: ControlTileConfig) -> some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .named("ccGrid"))
            .onChanged { value in
                if dragKind != config.kind { beginDrag(config.kind) }
                guard dragKind == config.kind else { return }
                dragTranslation = value.translation
                updateDragInsertion()
            }
            .onEnded { _ in endDrag() }
    }

    private func beginDrag(_ kind: ControlTileKind) {
        guard let own = tileFrames[kind] else { return }
        dragStartFrames = tileFrames
        dragStartRows = ControlCenterLayout.packRows(in: configs).map { $0.map(\.kind) }
        dragTileWidth = own.width
        previewConfigs = configs
        dragKind = kind
        dragTranslation = .zero
        ControlCenterState.shared.isInteracting = true
    }

    /// Insertion index among the visible tiles: count the neighbours whose
    /// frozen (drag-start) slot sits in an earlier row, plus those on the
    /// pointer's row whose centre is left of the pointer - the same
    /// count-the-neighbours rule the tab bar uses, extended to rows.
    private func updateDragInsertion() {
        guard let kind = dragKind, let own = dragStartFrames[kind] else { return }
        let pointer = CGPoint(x: own.midX + dragTranslation.width,
                              y: own.midY + dragTranslation.height)
        let pointerRow = rowIndex(containingY: pointer.y)
        var insertAt = 0
        for (index, row) in dragStartRows.enumerated() {
            for other in row where other != kind {
                guard let frame = dragStartFrames[other] else { continue }
                if index < pointerRow {
                    insertAt += 1
                } else if index == pointerRow && frame.midX < pointer.x {
                    insertAt += 1
                }
            }
        }
        let next = ControlCenterLayout.moved(previewConfigs, dragging: kind, toVisibleIndex: insertAt)
        guard next != previewConfigs else { return }
        withAnimation(Self.dragSettle) { previewConfigs = next }
    }

    private func rowIndex(containingY y: CGFloat) -> Int {
        for (index, row) in dragStartRows.enumerated() {
            let frames = row.compactMap { dragStartFrames[$0] }
            guard let top = frames.map(\.minY).min(),
                  let bottom = frames.map(\.maxY).max() else { continue }
            if y < top { return max(0, index - 1) }
            if y <= bottom { return index }
        }
        return max(0, dragStartRows.count - 1)
    }

    private func endDrag() {
        guard dragKind != nil else { return }
        let final = previewConfigs
        withAnimation(Self.dragSettle) {
            configs = final
            dragKind = nil
            previewConfigs = []
            dragTranslation = .zero
        }
        ControlCenterLayout.save(final)
        ControlCenterState.shared.isInteracting = false
        updatePreferredHeight()
    }

    /// iOS widget-style corner grip: the tile stretches continuously with
    /// the pointer; crossing 80% of the way to the neighbouring size commits
    /// that size with a spring, and the stretch then continues from there.
    @ViewBuilder
    private func resizeGrip(_ config: ControlTileConfig, cell: CGFloat) -> some View {
        ResizeGripShape()
            .fill(.white)
            .frame(width: 11, height: 11)
            .padding(7)
            .frame(width: 34, height: 34, alignment: .bottomTrailing)
            .contentShape(Rectangle())
            .highPriorityGesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { gripDragChanged($0, config: config, cell: cell) }
                    .onEnded { _ in endResize(save: true) }
            )
            .opacity(resizeKind == config.kind ? 1 : 0.85)
    }

    /// One corner-drag frame: continuous stretch + 80% threshold
    /// commit toward the neighbouring size. Split out of the gesture chain
    /// to keep the type-checker happy.
    private func gripDragChanged(_ value: DragGesture.Value,
                                 config: ControlTileConfig,
                                 cell: CGFloat) {
        if resizeKind != config.kind {
            resizeKind = config.kind
            ControlCenterState.shared.isInteracting = true
            resizeBaseWidth = Self.tileWidth(span: currentSpan(config.kind), cell: cell)
        }
        let raw = min(max(resizeBaseWidth + value.translation.width, cell),
                      Self.tileWidth(span: 4, cell: cell))
        resizeLiveWidth = raw
        let curSpan = currentSpan(config.kind)
        let curW = Self.tileWidth(span: curSpan, cell: cell)
        if let up = Self.nextLargerSpan(curSpan) {
            let upW = Self.tileWidth(span: up, cell: cell)
            if raw >= curW + 0.8 * (upW - curW) {
                commitResize(config.kind, span: up, cell: cell, translation: value.translation)
            }
        }
        if let down = Self.nextSmallerSpan(curSpan) {
            let downW = Self.tileWidth(span: down, cell: cell)
            if raw <= curW - 0.8 * (curW - downW) {
                commitResize(config.kind, span: down, cell: cell, translation: value.translation)
            }
        }
    }

    private func currentSpan(_ kind: ControlTileKind) -> Int {
        guard let i = ControlCenterLayout.index(of: kind, in: configs) else { return 1 }
        return configs[i].size.columnSpan
    }

    private func commitResize(_ kind: ControlTileKind, span: Int, cell: CGFloat, translation: CGSize) {
        let size: ControlTileSize = span >= 4 ? .large : span >= 2 ? .medium : .small
        guard let i = ControlCenterLayout.index(of: kind, in: configs), configs[i].size != size else { return }
        withAnimation(.smooth(duration: 0.22)) {
            configs[i].size = size
            resizeLiveWidth = nil
        }
        // Re-anchor so further movement continues from the committed size.
        resizeBaseWidth = Self.tileWidth(span: span, cell: cell) - translation.width
    }

    private func endResize(save: Bool) {
        resizeKind = nil
        resizeLiveWidth = nil
        ControlCenterState.shared.isInteracting = false
        if save { ControlCenterLayout.save(configs) }
    }

    private static func tileWidth(span: Int, cell: CGFloat) -> CGFloat {
        CGFloat(span) * cell + gap * CGFloat(span - 1)
    }

    /// Column spans snap to Control Center's three sizes: 1, 2 and 4.
    private static func nextLargerSpan(_ span: Int) -> Int? {
        switch span {
        case 1: return 2
        case 2: return 4
        default: return nil
        }
    }

    private static func nextSmallerSpan(_ span: Int) -> Int? {
        switch span {
        case 4: return 2
        case 2: return 1
        default: return nil
        }
    }

    @ViewBuilder
    private func editChrome(_ config: ControlTileConfig) -> some View {
        HStack(spacing: 6) {
            Button {
                ControlCenterLayout.mutate { configs in
                    configs = ControlCenterLayout.cycleSize(kind: config.kind, in: configs)
                }
                self.configs = ControlCenterLayout.load()
            } label: {
                Text("Aa")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 18, height: 18)
                    .background(.black.opacity(0.55), in: Circle())
            }
            ColorPicker("", selection: tintBinding(config), supportsOpacity: false)
                .labelsHidden()
                .scaleEffect(0.75)
            Button {
                ControlCenterLayout.mutate { configs in
                    configs = ControlCenterLayout.setVisible(kind: config.kind, false, in: configs)
                }
                self.configs = ControlCenterLayout.load()
            } label: {
                Image(systemName: "minus")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 18, height: 18)
                    .background(.black.opacity(0.55), in: Circle())
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .padding(6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .overlay(alignment: .bottomLeading) {
            Image(systemName: "move")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white.opacity(0.8))
                .padding(7)
        }
        .allowsHitTesting(editing)
    }

    private func tintBinding(_ config: ControlTileConfig) -> Binding<Color> {
        Binding(
            get: { ControlCenterLayout.color(hex: config.tintHex) ?? config.kind.defaultTint },
            set: { newColor in
                let hex = ControlCenterLayout.hex(from: newColor)
                ControlCenterLayout.mutate { configs in
                    configs = ControlCenterLayout.setTint(kind: config.kind, hex: hex, in: configs)
                }
                self.configs = ControlCenterLayout.load()
            })
    }

    private var hiddenStrip: some View {
        let hidden = configs.filter { !$0.visible }
        return Group {
            if !hidden.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        Text("Hidden:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ForEach(hidden) { config in
                            Button {
                                ControlCenterLayout.mutate { configs in
                                    configs = ControlCenterLayout.setVisible(kind: config.kind, true, in: configs)
                                }
                                self.configs = ControlCenterLayout.load()
                            } label: {
                                Label(config.kind.label, systemImage: "plus")
                                    .font(.caption)
                                    .padding(.horizontal, 8).padding(.vertical, 4)
                                    .background(.white.opacity(0.12), in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }
}

// MARK: - Tile body

/// Renders one tile at its configured size; taps toggle, large slider tiles
/// carry an inline slider, following the Control Center size vocabulary. The
/// Focus tile has no tap of its own: its press-and-hold picker is attached by
/// ``NotchControlCenterView`` so the release point can be tracked globally.
private struct TileBody: View {
    let config: ControlTileConfig
    let width: CGFloat
    let on: Bool
    let tint: Color
    var editing = false
    @ObservedObject var state: ControlCenterState

    var body: some View {
        if config.kind == .focus {
            visual
        } else {
            visual
                .onTapGesture {
                    guard !editing else { return }
                    state.toggle(config.kind)
                }
        }
    }

    private var visual: some View {
        content
            .padding(.horizontal, 12)
            .frame(width: width, height: NotchControlCenterView.tileHeight, alignment: .leading)
            .background(tileBackground)
            .contentShape(Rectangle())
    }

    @ViewBuilder
    private var content: some View {
        switch config.size {
        case .small:
            HStack {
                Spacer(minLength: 0)
                icon
                Spacer(minLength: 0)
            }
        case .medium:
            HStack(spacing: 8) {
                icon
                VStack(alignment: .leading, spacing: 1) {
                    Text(config.kind.label)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                    Text(statusLine)
                        .font(.system(size: 9))
                        .foregroundStyle(on ? Color.white.opacity(0.8) : Color.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(on ? .white : .primary)
        case .large:
            if config.kind.isSlider, let level = state.level(config.kind) {
                sliderRow(level)
            } else {
                HStack(spacing: 10) {
                    icon
                    VStack(alignment: .leading, spacing: 1) {
                        Text(config.kind.label)
                            .font(.system(size: 12, weight: .medium))
                        Text(statusLine)
                            .font(.system(size: 10))
                            .foregroundStyle(on ? Color.white.opacity(0.8) : Color.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: Binding(get: { on }, set: { _ in state.toggle(config.kind) }))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .tint(.white.opacity(0.9))
                }
                .foregroundStyle(on ? .white : .primary)
            }
        }
    }

    private func sliderRow(_ level: Float) -> some View {
        VStack(spacing: 5) {
            HStack(spacing: 8) {
                icon
                Text(config.kind.label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(on ? .white : .primary)
                Spacer()
                Text("\(Int((level * 100).rounded()))%")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(on ? Color.white.opacity(0.9) : Color.secondary)
            }
            HStack(spacing: 8) {
                Image(systemName: sliderLowerIcon).font(.system(size: 8))
                    .foregroundStyle(on ? .white.opacity(0.7) : .secondary)
                Slider(value: Binding(
                    get: { Double(level) },
                    set: { newValue in
                        switch config.kind {
                        case .volume: state.setVolume(Float(newValue))
                        case .brightness: state.setBrightness(Float(newValue))
                        case .keyboard: state.setKeyboard(Float(newValue))
                        default: break
                        }
                    }), in: 0...1)
                    .controlSize(.mini)
                    .tint(on ? .white : tint)
                    .frame(height: 14)
                Image(systemName: sliderUpperIcon).font(.system(size: 8))
                    .foregroundStyle(on ? .white.opacity(0.7) : .secondary)
            }
        }
    }

    /// Each slider gets its own glyph pair instead of the speaker pair on
    /// every tile.
    private var sliderLowerIcon: String {
        switch config.kind {
        case .volume: return "speaker.fill"
        case .brightness: return "sun.min.fill"
        case .keyboard: return "light.min"
        default: return "minus"
        }
    }

    private var sliderUpperIcon: String {
        switch config.kind {
        case .volume: return "speaker.wave.3.fill"
        case .brightness: return "sun.max.fill"
        case .keyboard: return "light.max"
        default: return "plus"
        }
    }

    private var icon: some View {
        Image(systemName: config.kind.icon(on: on))
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(on ? .white : tint)
    }

    private var statusLine: String {
        switch config.kind {
        case .wifi:
            guard state.wifiOn else { return "Off" }
            return state.wifiName ?? "On"
        case .focus:
            if state.focusNeedsPermission { return "Full Disk Access" }
            guard state.focusOn else { return "Off" }
            return state.focusName ?? "On"
        case .nightShift: return state.nightShiftOn ? "On" : "Off"
        case .darkMode: return state.darkModeOn ? "On" : "Light"
        case .volume: return state.volumeMuted ? "Muted" : "\(Int((state.volume * 100).rounded()))%"
        case .brightness: return "\(Int((state.brightness * 100).rounded()))%"
        case .keyboard: return "\(Int((state.keyboardLevel * 100).rounded()))%"
        }
    }

    @ViewBuilder
    private var tileBackground: some View {
        if on {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(tint)
        } else {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.10))
        }
    }
}

// MARK: - Jiggle

/// iOS edit-mode jiggle: a slow rotation around the tile centre with a
/// small horizontal sway. The `repeatForever` animation is owned by the
/// caller's `withAnimation`; tiles desynchronise with a stagger delay so
/// the grid looks alive rather than mechanical.
private struct WiggleModifier: ViewModifier {
    var enabled: Bool
    var phase: Bool
    var delay: Double

    func body(content: Content) -> some View {
        content
            .rotationEffect(.degrees(enabled ? (phase ? 0.9 : -0.9) : 0))
            .offset(x: enabled ? (phase ? 0.7 : -0.7) : 0)
            .animation(
                enabled
                    ? .easeInOut(duration: 0.32).repeatForever(autoreverses: true).delay(delay)
                    : .easeOut(duration: 0.2),
                value: phase
            )
    }
}

private extension View {
    func wiggle(enabled: Bool, phase: Bool, delay: Double) -> some View {
        modifier(WiggleModifier(enabled: enabled, phase: phase, delay: delay))
    }

    /// The notch already draws its own glass background; the SDK-default
    /// soft scroll-edge blur on either edge made ordinary scrolling look
    /// like the panel was fogging over. Suppress both (rubber-band
    /// overscroll physics is unaffected).
    func scrollEdgeBlurFix() -> some View {
        modifier(ScrollEdgeBlurFix())
    }
}

private struct ScrollEdgeBlurFix: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            // `scrollEdgeEffectStyle(nil, …)` means "back to automatic",
            // which *is* the soft blur; hiding the effect is the only way to
            // keep content (and the tile icons) crisp while scrolling.
            content.scrollEdgeEffectHidden(true, for: .all)
        } else {
            content
        }
    }
}

// MARK: - Grip

/// Three diagonal dots, matching the resize affordance iOS shows on
/// resizable home-screen widgets.
private struct ResizeGripShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let dot: CGFloat = 2.6
        // Diagonal from top-right toward bottom-left of the small pad.
        let positions: [(CGFloat, CGFloat)] = [(1, 0), (1, 1), (0, 1)]
        let cellSize = rect.width / 2
        for (col, row) in positions {
            let x = rect.maxX - (2 - col) * cellSize + (cellSize - dot) / 2
            let y = rect.minY + CGFloat(row) * cellSize + (cellSize - dot) / 2
            path.addEllipse(in: CGRect(x: x, y: y, width: dot, height: dot))
        }
        return path
    }
}

// MARK: - Frame tracking

/// Live frames of every tile in the grid's named coordinate space, frozen at
/// drag start to decide where the carried tile lands.
private struct TileFramesKey: PreferenceKey {
    static var defaultValue: [ControlTileKind: CGRect] = [:]
    static func reduce(value: inout [ControlTileKind: CGRect],
                       nextValue: () -> [ControlTileKind: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// Global-space frames of the Focus mode icons in the press-and-hold row, so
/// the release point (a global drag location) can pick the icon under it.
private struct FocusIconFramesKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect],
                       nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}
