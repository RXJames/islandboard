/*
 * Atoll (DynamicIsland)
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
import AppKit
import Defaults

// MARK: - Pure geometry

/// Geometry maths for the walking idle pet, kept side-effect free so the
/// "never covers the camera cutout" guarantees are unit-testable.
enum IdlePetGeometry {
    /// Edge length of the box the pet is drawn in on the notch's face.
    /// Driven by the notch's area (square-rooted back into a length) with a
    /// flat bump, capped at the notch height so the pet touches the face
    /// edge without ever exceeding it, then multiplied by the user's size
    /// slider (1.0 = flush with the edge).
    static func faceSide(notchWidth: CGFloat, notchHeight: CGFloat, scale: CGFloat) -> CGFloat {
        guard notchWidth > 0, notchHeight > 0 else { return 0 }
        let areaSide = (notchWidth * notchHeight).squareRoot() * 1.15
        let cap = min(notchHeight, max(24, areaSide))
        return cap * max(0.1, scale)
    }

    /// The horizontal band the pet patrols along the menu bar. The notch
    /// itself is a wall: the pet turns around before reaching the camera
    /// cutout. Prefers the segment right of the notch, falls back to the
    /// left, and returns nil (pet stays put) when neither side has room -
    /// crossing the notch would cover the camera.
    static func patrolSegment(screenMinX: CGFloat,
                              screenMaxX: CGFloat,
                              notchMinX: CGFloat,
                              notchMaxX: CGFloat,
                              petSize: CGFloat,
                              margin: CGFloat = 8) -> ClosedRange<CGFloat>? {
        let rightMin = notchMaxX
        let rightMax = screenMaxX - petSize - margin
        if rightMax - rightMin >= petSize { return rightMin...rightMax }
        let leftMin = screenMinX + margin
        let leftMax = notchMinX - petSize
        return leftMax - leftMin >= petSize ? leftMin...leftMax : nil
    }
}

// MARK: - Pet window content

private struct IdlePetWindowContent: View {
    var size: CGFloat = 32
    /// 1 walks right, -1 walks left (the Lottie is mirrored; the animation
    /// loops identically both ways).
    var facing: CGFloat = 1

    var body: some View {
        IdleAnimationView(fittingSize: CGSize(width: size, height: size))
            .frame(width: size, height: size)
            .scaleEffect(x: facing, y: 1)
            // A fully transparent borderless window swallows mouse-downs,
            // so give the pet a nearly invisible but hittable plate that
            // keeps `isMovableByWindowBackground` drags alive.
            .background(Color.white.opacity(0.001))
    }
}

// MARK: - Manager

/// Drives the walking pet: a tiny borderless window that patrols the menu
/// bar, can be grabbed and dragged with the mouse, is absorbed back into
/// the notch when dropped on it, and wanders out again after a rest.
@MainActor
final class IdlePetWindowManager: NSObject, ObservableObject, NSWindowDelegate {
    static let shared = IdlePetWindowManager()

    struct Inputs: Equatable {
        var enabled: Bool
        var hasAnimation: Bool
        /// User slider, 0.4...1.0; 1.0 fills the notch face to the cap.
        var scale: CGFloat
        /// Notch face in screen coordinates; nil disables the pet.
        var notchRect: CGRect?
    }

    private enum Mode {
        case patrolling
        /// Absorbed into the notch; the face view draws the pet meanwhile.
        case resting
    }

    private var inputs = Inputs(enabled: false, hasAnimation: false, scale: 1.0, notchRect: nil)
    private var window: NSWindow?
    private var host: NSHostingView<IdlePetWindowContent>?
    private var timer: Timer?
    private var reappearWork: DispatchWorkItem?
    private var settleWork: DispatchWorkItem?
    private var dir: CGFloat = 1
    private var x: CGFloat = 0
    private var standing = false
    private var actionEnd = Date.distantPast
    private var dragging = false
    private var programmaticMove = false
    private var mode: Mode = .patrolling
    /// True while the pet rests inside the notch face and ContentView should
    /// draw it there (walking mode normally hides the in-face pet).
    @Published private(set) var petShownInNotchFace = false

    private static let walkSpeed: CGFloat = 14 // points per second, a stroll
    private static let tickInterval: TimeInterval = 1.0 / 30.0
    /// Length of one stroll and one idle stop; the pet alternates between
    /// them so it reads as "playing around the menu bar" rather than a
    /// metronome back and forth.
    private static let strollRange: ClosedRange<Double> = 8...22
    private static let stopRange: ClosedRange<Double> = 3...9

    func sync(_ newInputs: Inputs) {
        guard newInputs.enabled, newInputs.hasAnimation, newInputs.notchRect != nil else {
            stop()
            return
        }
        let geometryChanged = newInputs.notchRect != inputs.notchRect || newInputs.scale != inputs.scale
        inputs = newInputs
        if window == nil {
            // Same transaction-safety as `stop`: never spin AppKit windows up
            // or down while SwiftUI is mid-update.
            DispatchQueue.main.async { [weak self] in self?.build() }
        }
        if geometryChanged {
            relayoutSize()
            clampIntoSegment()
        }
    }

    func stop() {
        reappearWork?.cancel()
        reappearWork = nil
        settleWork?.cancel()
        settleWork = nil
        timer?.invalidate()
        timer = nil
        // Tearing a window down (and publishing state changes) from inside a
        // SwiftUI view-update transaction - `sync` runs straight out of an
        // `onChange` - crashes the hosting view mid-flush. Detach both:
        // publish only when the value actually changes, close the panel on
        // the next loop turn.
        let closing = window
        window = nil
        host = nil
        dragging = false
        mode = .patrolling
        if petShownInNotchFace { petShownInNotchFace = false }
        if let closing {
            DispatchQueue.main.async {
                closing.orderOut(nil)
                closing.close()
            }
        }
    }

    // MARK: Window

    private func build() {
        guard window == nil, inputs.enabled, inputs.hasAnimation, inputs.notchRect != nil else { return }
        let size = petSize
        let hosting = NSHostingView(rootView: IdlePetWindowContent(size: size))
        let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: size, height: size),
                             styleMask: [.borderless],
                             backing: .buffered,
                             defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.delegate = self
        panel.contentView = hosting
        window = panel
        host = hosting

        // Start hugging the notch edge, ready to walk away; with no room to
        // patrol (tiny screen straddled by the notch) the pet stays hidden.
        standing = false
        actionEnd = Date().addingTimeInterval(Double.random(in: Self.strollRange))
        if let segment = currentSegment() {
            x = segment.lowerBound
            placeWindow()
            panel.orderFrontRegardless()
        }

        timer = Timer.scheduledTimer(withTimeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private var petSize: CGFloat {
        guard let notch = inputs.notchRect else { return 32 }
        return max(20, IdlePetGeometry.faceSide(notchWidth: notch.width, notchHeight: notch.height, scale: inputs.scale))
    }

    private var screen: NSScreen? {
        guard let notch = inputs.notchRect else { return nil }
        return NSScreen.screens.first { $0.frame.intersects(notch) }
    }

    private func currentSegment() -> ClosedRange<CGFloat>? {
        guard let screen, let notch = inputs.notchRect else { return nil }
        return IdlePetGeometry.patrolSegment(screenMinX: screen.frame.minX,
                                             screenMaxX: screen.frame.maxX,
                                             notchMinX: notch.minX,
                                             notchMaxX: notch.maxX,
                                             petSize: petSize)
    }

    private func relayoutSize() {
        guard let window, let host else { return }
        let size = petSize
        host.rootView = IdlePetWindowContent(size: size, facing: dir >= 0 ? 1 : -1)
        var frame = window.frame
        frame.size = CGSize(width: size, height: size)
        programmaticMove = true
        window.setFrame(frame, display: true)
        programmaticMove = false
    }

    private func placeWindow() {
        guard let window, let screen else { return }
        let size = petSize
        // Flush with the top of the screen: the pet rides the menu bar's
        // upper edge, sharing the notch's baseline. The patrol band keeps
        // it clear of the camera cutout horizontally.
        let y = screen.frame.maxY - size
        programmaticMove = true
        window.setFrame(NSRect(x: x, y: y, width: size, height: size), display: true)
        programmaticMove = false
    }

    private func clampIntoSegment() {
        guard let segment = currentSegment() else { return }
        x = min(max(x, segment.lowerBound), segment.upperBound)
        placeWindow()
    }

    // MARK: Walk loop

    /// Alternates strolling and standing still: while stopped the same
    /// Lottie keeps playing in place, which is exactly the idle animation
    /// the pet shows inside the notch, so walking and resting blend.
    private func tick() {
        guard mode == .patrolling, !dragging, let segment = currentSegment() else { return }
        let now = Date()
        if now >= actionEnd {
            standing.toggle()
            actionEnd = now.addingTimeInterval(standing
                ? Double.random(in: Self.stopRange)
                : Double.random(in: Self.strollRange))
        }
        guard !standing else { return }
        let step = Self.walkSpeed * CGFloat(Self.tickInterval) * dir
        var next = x + step
        if next <= segment.lowerBound {
            next = segment.lowerBound
            dir = 1
            setFacing()
        } else if next >= segment.upperBound {
            next = segment.upperBound
            dir = -1
            setFacing()
        }
        x = next
        placeWindow()
    }

    private func setFacing() {
        host?.rootView = IdlePetWindowContent(size: petSize, facing: dir >= 0 ? 1 : -1)
    }

    // MARK: Drag handling

    /// Fires for both programmatic and user moves; `programmaticMove`
    /// distinguishes them. A user drag that lands on the notch absorbs the
    /// pet back into the face; anywhere else it keeps patrolling from there.
    func windowDidMove(_ notification: Notification) {
        guard !programmaticMove else { return }
        dragging = true
        reappearWork?.cancel()
        reappearWork = nil

        if let window, let notch = inputs.notchRect,
           window.frame.intersects(notch.insetBy(dx: -4, dy: -4)) {
            absorbIntoNotch()
            return
        }
        settleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.dragging else { return }
            self.dragging = false
            self.x = self.window?.frame.minX ?? self.x
            self.clampIntoSegment()
        }
        settleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    private func absorbIntoNotch() {
        mode = .resting
        dragging = false
        settleWork?.cancel()
        settleWork = nil
        window?.orderOut(nil)
        petShownInNotchFace = true
        scheduleReappearance()
    }

    private func scheduleReappearance() {
        reappearWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.mode == .resting else { return }
            guard let segment = self.currentSegment() else { return }
            self.mode = .patrolling
            self.petShownInNotchFace = false
            self.standing = false
            self.actionEnd = Date().addingTimeInterval(Double.random(in: Self.strollRange))
            self.x = segment.lowerBound
            self.dir = 1
            self.setFacing()
            self.placeWindow()
            self.window?.orderFrontRegardless()
        }
        reappearWork = work
        let delay = Double.random(in: 6...14)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
}
