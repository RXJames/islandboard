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

    /// Seconds for one loop of a Lottie JSON (`ip`/`op`/`fr` divided by the
    /// user's speed multiplier). Only local files are parsed; remote URLs
    /// fall back to 3 s rather than blocking the main thread on a fetch.
    static func loopDuration(lottieData data: Data?, speed: Double) -> TimeInterval {
        guard let data,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let fr = obj["fr"] as? Double, fr > 0,
              let ip = obj["ip"] as? Double,
              let op = obj["op"] as? Double, op > ip else { return 3 }
        return min(30, max(0.3, (op - ip) / fr / max(0.1, speed)))
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
///
/// The window and its hosting view are created once and live forever:
/// toggling walking or absorbing the pet only orders the window out,
/// never closes it. Destroying a running `LottieAnimationView` while
/// SwiftUI builds another one for the same file over-released an object
/// and crashed on the next autorelease-pool pop (SIGSEGV seen when
/// switching walking off mid-stroll), so all view-tree churn is off the
/// table - visibility toggles alone.
@MainActor
final class IdlePetWindowManager: NSObject, ObservableObject, NSWindowDelegate {
    static let shared = IdlePetWindowManager()

    struct Inputs: Equatable {
        var enabled: Bool
        var hasAnimation: Bool
        /// User slider, 0.4...1.0; 1.0 means flush with the notch edge.
        var scale: CGFloat
        /// Notch face in screen coordinates; nil disables the pet.
        var notchRect: CGRect?
    }

    private enum Mode {
        /// Pet is on (or about to be on) the menu bar.
        case patrolling
        /// Pet was dragged into the notch; the face draws it.
        case absorbed
    }

    private var inputs = Inputs(enabled: false, hasAnimation: false, scale: 1.0, notchRect: nil)
    /// The pet window is built lazily on the first enable and parked
    /// (hidden, alive) afterwards.
    private var window: NSWindow?
    private var host: NSHostingView<IdlePetWindowContent>?
    private var timer: Timer?
    private var introWork: DispatchWorkItem?
    private var reappearWork: DispatchWorkItem?
    private var settleWork: DispatchWorkItem?
    private var running = false
    private var dir: CGFloat = 1
    private var x: CGFloat = 0
    private var standing = false
    private var actionEnd = Date.distantPast
    private var dragging = false
    private var programmaticMove = false
    private var mode: Mode = .patrolling
    /// True while the pet belongs on the notch face (intro loops, resting
    /// after an absorb, or walking disabled); walking hides the face pet.
    @Published private(set) var petShownInNotchFace = false

    private static let walkSpeed: CGFloat = 14 // points per second, a stroll
    private static let tickInterval: TimeInterval = 1.0 / 30.0
    /// Loops the pet performs inside the notch before every outing.
    static let introLoops = 3
    /// Length of one stroll and one idle stop; the pet alternates between
    /// them so it reads as "playing around the menu bar" rather than a
    /// metronome back and forth.
    private static let strollRange: ClosedRange<Double> = 8...22
    private static let stopRange: ClosedRange<Double> = 3...9

    func sync(_ newInputs: Inputs) {
        guard newInputs.enabled, newInputs.hasAnimation, newInputs.notchRect != nil else {
            park()
            return
        }
        let geometryChanged = newInputs.notchRect != inputs.notchRect || newInputs.scale != inputs.scale
        inputs = newInputs
        buildIfNeeded()
        if geometryChanged {
            relayoutSize()
            clampIntoSegment()
        }
        if !running {
            start()
        }
    }

    /// Hides the pet (walking disabled): the window is parked, not closed.
    private func park() {
        guard running || window != nil else { return }
        running = false
        introWork?.cancel()
        introWork = nil
        reappearWork?.cancel()
        reappearWork = nil
        settleWork?.cancel()
        settleWork = nil
        dragging = false
        mode = .patrolling
        if petShownInNotchFace { petShownInNotchFace = false }
        guard let window else { return }
        DispatchQueue.main.async {
            window.orderOut(nil)
        }
    }

    private func start() {
        guard !running, inputs.enabled, inputs.hasAnimation, inputs.notchRect != nil else { return }
        running = true
        // The pet performs its idle animation inside the notch first, then
        // walks out - toggling walking never teleports it to the menu bar.
        beginIntro()
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
        }
    }

    // MARK: Window

    private func buildIfNeeded() {
        guard window == nil else { return }
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
        // Parked off-screen until an intro finishes.
        panel.setFrame(NSRect(x: -2000, y: -2000, width: size, height: size), display: false)
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
        window.setFrame(frame, display: window.isVisible)
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
        window.setFrame(NSRect(x: x, y: y, width: size, height: size), display: window.isVisible)
        programmaticMove = false
    }

    private func clampIntoSegment() {
        guard let segment = currentSegment() else { return }
        x = min(max(x, segment.lowerBound), segment.upperBound)
        placeWindow()
    }

    // MARK: Intro: 3 idle loops inside the notch, then walk out

    private func beginIntro() {
        introWork?.cancel()
        reappearWork?.cancel()
        if !petShownInNotchFace { petShownInNotchFace = true }
        window?.orderOut(nil)
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, self.running, self.mode == .patrolling else { return }
                self.beginWalk()
            }
        }
        introWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(Self.introLoops) * loopDuration(), execute: work)
    }

    private func beginWalk() {
        introWork = nil
        guard let segment = currentSegment() else { return }
        petShownInNotchFace = false
        x = segment.lowerBound
        dir = 1
        standing = false
        actionEnd = Date().addingTimeInterval(Double.random(in: Self.strollRange))
        setFacing()
        placeWindow()
        window?.orderFrontRegardless()
    }

    /// One loop of the selected Lottie in seconds; remote sources fall back
    /// to 3 s (parsing must never block the main thread on the network).
    private func loopDuration() -> TimeInterval {
        guard let anim = Defaults[.selectedIdleAnimation] else { return 3 }
        switch anim.source {
        case .lottieFile(let url):
            return IdlePetGeometry.loopDuration(lottieData: try? Data(contentsOf: url),
                                                speed: anim.speed)
        case .lottieURL:
            return 3
        }
    }

    // MARK: Walk loop

    /// Alternates strolling and standing still: while stopped the same
    /// Lottie keeps playing in place, which is exactly the idle animation
    /// the pet shows inside the notch, so walking and resting blend.
    private func tick() {
        guard running, mode == .patrolling, !dragging, introWork == nil,
              window?.isVisible == true, let segment = currentSegment() else { return }
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
        introWork?.cancel()
        introWork = nil

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
        mode = .absorbed
        dragging = false
        settleWork?.cancel()
        settleWork = nil
        if let window {
            DispatchQueue.main.async { window.orderOut(nil) }
        }
        petShownInNotchFace = true
        scheduleReappearance()
    }

    private func scheduleReappearance() {
        reappearWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.mode == .absorbed, self.running else { return }
            self.mode = .patrolling
            // Same ritual as the first outing: idle in the notch, then leave.
            self.beginIntro()
        }
        reappearWork = work
        let delay = Double.random(in: 6...14)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
}
