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

    /// True when a dropped pet belongs to the menu bar again: its centre sits
    /// in the strip under the top edge of the notch's screen. The strip is
    /// padded by half a pet so a drop that only roughly lines up with the
    /// bar still counts - nobody releases a 30 pt sprite pixel-perfectly.
    static func isInMenuBarZone(petFrame: CGRect,
                                screenFrame: CGRect,
                                notchHeight: CGFloat) -> Bool {
        guard petFrame.midX >= screenFrame.minX, petFrame.midX <= screenFrame.maxX else { return false }
        let stripHeight = max(notchHeight, 24) + petFrame.height / 2
        return petFrame.midY >= screenFrame.maxY - stripHeight && petFrame.midY <= screenFrame.maxY + petFrame.height
    }

    /// The band a free-roaming pet (dropped away from the menu bar) walks
    /// along: the full width of the screen it was dropped on. Nil when the
    /// screen is too narrow to walk on.
    static func freeSegment(screenMinX: CGFloat,
                            screenMaxX: CGFloat,
                            petSize: CGFloat,
                            margin: CGFloat = 8) -> ClosedRange<CGFloat>? {
        let lower = screenMinX + margin
        let upper = screenMaxX - petSize - margin
        return upper - lower >= petSize ? lower...upper : nil
    }

    /// Keeps a free-roaming pet fully on its screen vertically.
    static func clampedFreeY(_ y: CGFloat,
                             screenMinY: CGFloat,
                             screenMaxY: CGFloat,
                             petSize: CGFloat) -> CGFloat {
        let upper = max(screenMinY, screenMaxY - petSize)
        return min(max(y, screenMinY), upper)
    }

    /// Where a pet returning to the menu bar lands: on the notch's screen
    /// and beside the notch, never on top of the camera cutout.
    static func menuBarLandingX(from x: CGFloat,
                                screenMinX: CGFloat,
                                screenMaxX: CGFloat,
                                notchMinX: CGFloat,
                                notchMaxX: CGFloat,
                                petSize: CGFloat,
                                margin: CGFloat = 8) -> CGFloat {
        var landing = min(max(x, screenMinX + margin), screenMaxX - petSize - margin)
        if landing > notchMinX - petSize, landing < notchMaxX {
            landing = landing + petSize / 2 < (notchMinX + notchMaxX) / 2
                ? notchMinX - petSize
                : notchMaxX
        }
        return landing
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

/// Observable walking state, so direction/state changes re-render the hosted
/// pet in place instead of rebuilding the whole hosting view (destroying a
/// live Lottie view was the SIGSEGV source this manager is built around).
@MainActor
final class IdlePetVisualState: ObservableObject {
    /// 1 walks right, -1 walks left. Only used to mirror pets that do not
    /// ship direction-specific run rows (Lottie pets, legacy 8-row sheets).
    @Published var facing: CGFloat = 1
    /// Atlas row: idle / running-left / running-right / jumping.
    @Published var spriteState: String = "idle"
}

private struct IdlePetWindowContent: View {
    var size: CGFloat = 32
    @ObservedObject var visual: IdlePetVisualState
    @Default(.selectedIdleAnimation) private var selectedAnimation

    /// Codex atlases with both `running-left` and `running-right` already
    /// face the right way; everything else is mirrored by scaling.
    private var mirror: CGFloat {
        guard let animation = selectedAnimation,
              case .codexPet(let directory) = animation.source,
              let pet = CodexPetStore.shared.pet(at: directory)
        else { return visual.facing }
        let directional = pet.rowNames.contains("running-left")
            && pet.rowNames.contains("running-right")
        return directional ? 1 : visual.facing
    }

    var body: some View {
        IdleAnimationView(fittingSize: CGSize(width: size, height: size),
                          spriteState: visual.spriteState)
            .frame(width: size, height: size)
            .scaleEffect(x: mirror, y: 1)
            // A fully transparent borderless window swallows mouse-downs,
            // so give the pet a nearly invisible but hittable plate that
            // keeps window-background drags alive.
            .background(Color.white.opacity(0.001))
    }
}

/// Borderless pet windows are not key by default; `performDrag(with:)` and
/// first-click delivery are unreliable unless the window can become key.
private final class IdlePetWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// The transparent AppKit view that sits above the hosted SwiftUI pet and owns
/// mouse-down. Putting this directly into the window's content container is
/// more reliable than a SwiftUI `.overlay`, especially while the sprite/lottie
/// timeline is re-rendering and SwiftUI hit-testing changes.
private final class IdlePetDragView: NSView {
    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Mouse and window positions at mouse-down, in screen coordinates.
    private var dragStart: (mouse: NSPoint, origin: NSPoint)?

    // The drag is tracked here by hand rather than with
    // `NSWindow.performDrag(with:)`. performDrag hands the drag to the window
    // server and returns immediately, so there is no way to know when the
    // user lets go: "drag ended" used to fire on mouse-DOWN. That is why a
    // dropped pet first froze wherever it was (the manager believed the drag
    // was long over), and why a pet that keeps walking would be yanked back
    // to its lane mid-drag. mouseDown / mouseDragged / mouseUp bracket the
    // drag exactly.
    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        dragStart = (NSEvent.mouseLocation, window.frame.origin)
        IdlePetWindowManager.shared.userDragBegan()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window, let dragStart else { return }
        let mouse = NSEvent.mouseLocation
        window.setFrameOrigin(NSPoint(x: dragStart.origin.x + mouse.x - dragStart.mouse.x,
                                      y: dragStart.origin.y + mouse.y - dragStart.mouse.y))
    }

    override func mouseUp(with event: NSEvent) {
        guard dragStart != nil else { return }
        dragStart = nil
        IdlePetWindowManager.shared.userDragEnded()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        isHidden ? nil : self
    }
}

/// Hosting view plus an AppKit drag layer on top.
private final class IdlePetContentContainer: NSView {
    let dragView = IdlePetDragView()

    init(hosting: NSView) {
        super.init(frame: .zero)
        hosting.autoresizingMask = [.width, .height]
        hosting.frame = bounds
        addSubview(hosting)
        dragView.autoresizingMask = [.width, .height]
        dragView.frame = bounds
        addSubview(dragView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // The drag view's acceptsFirstMouse is not enough: AppKit asks the
    // window's content view before delivering the first click to an inactive
    // app. Without this, the first attempt only activated IslandBoard, and the pet
    // did not move until a second click.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
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
        /// Notch panel currently expanded; the pet steps out of the way.
        var notchOpen = false
        /// When true a pet dropped away from the menu bar hops back onto it;
        /// when false it keeps roaming wherever it was dropped.
        var menuBarOnly = false
    }

    /// Where the pet is walking.
    private enum Lane: Equatable {
        /// Along the menu bar of the notch's screen, beside the notch.
        case menuBar
        /// Along a horizontal line on the screen the user dropped it on.
        case free(screenFrame: CGRect, y: CGFloat)
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
    private var screenLocked = false
    private var lockObservers: [NSObjectProtocol] = []
    private var dir: CGFloat = 1
    /// Shared with the hosted view; updated instead of rebuilding rootView.
    private let visual = IdlePetVisualState()
    private var x: CGFloat = 0
    private var standing = false
    private var actionEnd = Date.distantPast
    private var dragging = false
    private var programmaticMove = false
    /// The pet keeps walking wherever it is: on the menu bar, or - after
    /// being dropped elsewhere with "menu bar only" off - along the line it
    /// was dropped on. (It used to freeze where it was released and never
    /// move again, even when dragged back onto the menu bar.)
    private var lane: Lane = .menuBar
    /// True during the short hop back to the menu bar.
    private var returning = false
    private var mode: Mode = .patrolling
    /// True while the pet belongs on the notch face (intro loops, resting
    /// after an absorb, or walking disabled); walking hides the face pet.
    @Published private(set) var petShownInNotchFace = false

    private static let walkSpeed: CGFloat = 14 // points per second, a stroll
    private static let tickInterval: TimeInterval = 1.0 / 30.0
    /// While the pet is standing, hidden or parked nothing moves, so the
    /// loop only needs to notice state changes - not redraw at 30 Hz.
    private static let restingTickInterval: TimeInterval = 0.25
    private var tickIsWalking: Bool?
    private var lastWalkTick: Date?
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
        let confinedToMenuBar = newInputs.menuBarOnly && !inputs.menuBarOnly
        inputs = newInputs
        buildIfNeeded()
        if geometryChanged {
            relayoutSize()
            clampIntoSegment()
        }
        if confinedToMenuBar, running, mode == .patrolling, !dragging, lane != .menuBar {
            // The setting was just switched on with the pet out roaming.
            resumeMenuBarPatrol(fromX: window?.frame.minX ?? x, animated: true)
        }
        if !running {
            start()
        }
    }

    /// Hides the pet (walking disabled): the window is parked, not closed.
    private func park() {
        guard running || window != nil else { return }
        running = false
        timer?.invalidate()
        timer = nil
        tickIsWalking = nil
        introWork?.cancel()
        introWork = nil
        reappearWork?.cancel()
        reappearWork = nil
        settleWork?.cancel()
        settleWork = nil
        dragging = false
        returning = false
        lane = .menuBar
        mode = .patrolling
        if visual.spriteState != "idle" { visual.spriteState = "idle" }
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
        scheduleTick(walking: false)
        // The pet rides in the notch's max-level SkyLight space, so it must
        // not linger over the login window while the screen is locked.
        if lockObservers.isEmpty {
            let center = DistributedNotificationCenter.default()
            lockObservers.append(center.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.screenLocked = true }
            })
            lockObservers.append(center.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.screenLocked = false }
            })
        }
    }

    // MARK: Window

    private func buildIfNeeded() {
        guard window == nil else { return }
        let size = petSize
        let hosting = NSHostingView(rootView: IdlePetWindowContent(size: size, visual: visual))
        let container = IdlePetContentContainer(hosting: hosting)
        let panel = IdlePetWindow(contentRect: NSRect(x: 0, y: 0, width: size, height: size),
                                  styleMask: [.borderless],
                                  backing: .buffered,
                                  defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // One level above the notch window: the pet walks in FRONT of the
        // notch - out of the face and back - exactly like it lives there.
        if let notch = NSApp.windows.first(where: { $0 is DynamicIslandWindow }) {
            panel.level = NSWindow.Level(rawValue: notch.level.rawValue + 1)
        } else {
            panel.level = .statusBar
        }
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        // Dragging is handled by IdlePetDragView; a window-server drag on
        // top of it would fight the manual one.
        panel.isMovableByWindowBackground = false
        panel.ignoresMouseEvents = false
        panel.acceptsMouseMovedEvents = true
        panel.delegate = self
        panel.contentView = container
        window = panel
        host = hosting
        // The notch window is lifted into SkyLight's max-level space, which
        // no ordinary window level can beat; ride in the same space so the
        // pet can genuinely walk over the notch face.
        joinNotchSpace()
        // Parked off-screen until an intro finishes.
        panel.setFrame(NSRect(x: -2000, y: -2000, width: size, height: size), display: false)
    }

    /// Re-attach the pet window after the app reassigns the notch space
    /// membership (`notchSpace.windows = currentDynamicIslandWindows()` on
    /// layout refreshes drops anything not in that set). Set insert on an
    /// already-member window mutates nothing, so only actual drops fire the
    /// SkyLight call; guard with `contains` to keep ticks write-free.
    private func joinNotchSpace() {
        guard let window, !NotchSpaceManager.shared.notchSpace.windows.contains(window) else { return }
        NotchSpaceManager.shared.notchSpace.windows.insert(window)
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
        host.rootView = IdlePetWindowContent(size: size, visual: visual)
        var frame = window.frame
        frame.size = CGSize(width: size, height: size)
        programmaticMove = true
        window.setFrame(frame, display: window.isVisible)
        programmaticMove = false
    }

    private func placeWindow() {
        guard let window, let y = laneY() else { return }
        let size = petSize
        programmaticMove = true
        if window.frame.size == CGSize(width: size, height: size) {
            // Only the origin changes while walking; moving the window is far
            // cheaper than a full setFrame, which re-lays-out and redraws the
            // hosting view on every tick.
            window.setFrameOrigin(NSPoint(x: x, y: y))
        } else {
            window.setFrame(NSRect(x: x, y: y, width: size, height: size), display: window.isVisible)
        }
        programmaticMove = false
    }

    /// Vertical position of the lane the pet is walking in.
    private func laneY() -> CGFloat? {
        switch lane {
        case .menuBar:
            guard let screen, let notch = inputs.notchRect else { return nil }
            // Bottom-aligned with the notch face, exactly where the in-face
            // pet sits: when the window slides out its vertical position
            // never changes, so the pet looks like it walks along the
            // notch's floor.
            return screen.frame.maxY - notch.height
        case .free(let screenFrame, let y):
            return IdlePetGeometry.clampedFreeY(y,
                                                screenMinY: screenFrame.minY,
                                                screenMaxY: screenFrame.maxY,
                                                petSize: petSize)
        }
    }

    /// Horizontal band of the lane the pet is walking in.
    private func laneSegment() -> ClosedRange<CGFloat>? {
        switch lane {
        case .menuBar:
            return currentSegment()
        case .free(let screenFrame, _):
            return IdlePetGeometry.freeSegment(screenMinX: screenFrame.minX,
                                               screenMaxX: screenFrame.maxX,
                                               petSize: petSize)
        }
    }

    /// A free lane dies with its display (unplugged, rearranged); the pet
    /// then goes home to the menu bar instead of walking off-screen.
    private func validateLane() {
        guard case .free(let screenFrame, _) = lane else { return }
        if !NSScreen.screens.contains(where: { $0.frame == screenFrame }) {
            resumeMenuBarPatrol(fromX: x, animated: false)
        }
    }

    private func clampIntoSegment() {
        validateLane()
        guard let segment = laneSegment() else { return }
        x = min(max(x, segment.lowerBound), segment.upperBound)
        placeWindow()
    }

    // MARK: Intro: 3 idle loops inside the notch, then walk out

    private func beginIntro() {
        lane = .menuBar
        returning = false
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
        lane = .menuBar
        returning = false
        guard running, mode == .patrolling, let segment = currentSegment(), let notch = inputs.notchRect else { return }
        if screenLocked || inputs.notchOpen {
            // Intro finished while the screen is locked or the notch is
            // expanded; revisit shortly instead of walking onto them.
            let work = DispatchWorkItem { [weak self] in
                Task { @MainActor in self?.beginWalk() }
            }
            reappearWork?.cancel()
            reappearWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
            return
        }
        petShownInNotchFace = false
        // Start at the face pet's exact slot (right edge of the notch,
        // 10 pt inset) in the same front layer, so the hand-off from the
        // in-notch view to the walking window is invisible: same spot,
        // same size, same animation, and it keeps walking outward.
        x = notch.maxX - 10 - petSize
        // Head towards the patrol band even when it is on the far side.
        dir = x < segment.lowerBound ? 1 : -1
        standing = false
        actionEnd = Date().addingTimeInterval(Double.random(in: Self.strollRange))
        setFacing()
        placeWindow()
        joinNotchSpace()
        window?.orderFrontRegardless()
        scheduleTick(walking: true)
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
        case .codexPet(let directory):
            guard let pet = CodexPetStore.shared.pet(at: directory) else { return 1.1 }
            return pet.frameInterval * Double(pet.framesPerState)
        }
    }

    // MARK: Walk loop

    /// Alternates strolling and standing still: while stopped the same
    /// Lottie keeps playing in place, which is exactly the idle animation
    /// the pet shows inside the notch, so walking and resting blend.
    private func tick() {
        scheduleTick(walking: advance())
    }

    /// (Re)arms the loop at the rate the pet currently needs: 30 Hz while it
    /// is actually walking, a slow poll otherwise.
    private func scheduleTick(walking: Bool) {
        if timer != nil, tickIsWalking == walking { return }
        timer?.invalidate()
        tickIsWalking = walking
        if !walking { lastWalkTick = nil }
        let interval = walking ? Self.tickInterval : Self.restingTickInterval
        let newTimer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        newTimer.tolerance = walking ? 0 : interval * 0.4
        RunLoop.main.add(newTimer, forMode: .common)
        timer = newTimer
    }

    /// Runs one step of the patrol. Returns true while the pet is moving and
    /// therefore needs the fast tick.
    private func advance() -> Bool {
        guard running, mode == .patrolling, !dragging, !returning, introWork == nil else { return false }
        // An expanded notch owns the menu-bar area; the pet waits it out
        // without teleporting (a pet roaming elsewhere is not in its way).
        // Nothing is shown while the screen is locked.
        if screenLocked || (inputs.notchOpen && lane == .menuBar) {
            if window?.isVisible == true { window?.orderOut(nil) }
            return false
        }
        if window?.isVisible == false { window?.orderFrontRegardless() }
        joinNotchSpace()  // cheap: only acts if a layout refresh dropped us
        validateLane()
        guard !returning, let segment = laneSegment() else { return false }
        let now = Date()
        if now >= actionEnd {
            standing.toggle()
            actionEnd = now.addingTimeInterval(standing
                ? Double.random(in: Self.stopRange)
                : Double.random(in: Self.strollRange))
            updateSpriteState()
        }
        guard !standing else { return false }
        // Real elapsed time rather than the nominal interval, so the stroll
        // keeps its speed when a tick is late or the rate has just changed.
        let elapsed = lastWalkTick.map { now.timeIntervalSince($0) } ?? Self.tickInterval
        lastWalkTick = now
        let step = Self.walkSpeed * CGFloat(min(max(elapsed, 0), 0.1)) * dir
        var next = x + step
        // Turn only when inside the band; the entry leg (walking out from
        // under the notch, or across it toward a far-side band) walks on
        // without snapping, and once inside, the ends take over.
        if x >= segment.lowerBound, x <= segment.upperBound {
            if next >= segment.upperBound {
                next = segment.upperBound
                dir = -1
                setFacing()
            } else if next <= segment.lowerBound {
                next = segment.lowerBound
                dir = 1
                setFacing()
            }
        }
        x = next
        placeWindow()
        return true
    }

    private func setFacing() {
        visual.facing = dir >= 0 ? 1 : -1
        updateSpriteState()
    }

    /// Picks the Codex atlas row for what the pet is doing right now; Lottie
    /// pets ignore it. Only publishes on change, since the walk loop runs at
    /// 30 Hz.
    private func updateSpriteState() {
        let next: String
        if dragging || returning {
            next = "jumping"
        } else if running, mode == .patrolling, introWork == nil, !standing {
            next = dir >= 0 ? "running-right" : "running-left"
        } else {
            next = "idle"
        }
        if visual.spriteState != next { visual.spriteState = next }
    }

    // MARK: Drag handling

    /// Programmatic moves (walking steps) are ignored; a user drag is
    /// bracketed by the drag surface's begin/end notifications, so there is
    /// nothing to decide per move.
    func windowDidMove(_ notification: Notification) {
        guard !programmaticMove else { return }
    }

    // MARK: User drag (from the pet window's drag surface)

    fileprivate func userDragBegan() {
        settleWork?.cancel()
        settleWork = nil
        reappearWork?.cancel()
        reappearWork = nil
        introWork?.cancel()
        introWork = nil
        returning = false
        dragging = true
        updateSpriteState()
    }

    fileprivate func userDragEnded() {
        guard dragging else { return }
        dragging = false
        guard let window, let notch = inputs.notchRect else {
            updateSpriteState()
            return
        }
        let frame = window.frame
        // Absorb only when the pet's centre is actually over the notch.
        // The old frame-intersection test fired for a pet still beside
        // the notch (the notch is much wider than the pet), so a short
        // horizontal drag read as "it jumped back".
        let center = CGPoint(x: frame.midX, y: frame.midY)
        if notch.insetBy(dx: -4, dy: -4).contains(center) {
            absorbIntoNotch()
            return
        }
        if let notchScreen = screen,
           IdlePetGeometry.isInMenuBarZone(petFrame: frame,
                                           screenFrame: notchScreen.frame,
                                           notchHeight: notch.height) {
            // Dropped back onto the menu bar: carry on patrolling from here.
            resumeMenuBarPatrol(fromX: frame.minX, animated: false)
            return
        }
        guard !inputs.menuBarOnly,
              let dropScreen = NSScreen.screens.first(where: { $0.frame.contains(center) })
        else {
            // Confined to the menu bar (or dropped off every display).
            resumeMenuBarPatrol(fromX: frame.minX, animated: true)
            return
        }
        // Free roaming: keep strolling along the line it was dropped on.
        let y = IdlePetGeometry.clampedFreeY(frame.minY,
                                             screenMinY: dropScreen.frame.minY,
                                             screenMaxY: dropScreen.frame.maxY,
                                             petSize: petSize)
        lane = .free(screenFrame: dropScreen.frame, y: y)
        x = frame.minX
        beginStroll()
        placeWindow()
        scheduleTick(walking: true)
    }

    /// Starts a fresh stroll in the current lane, heading into its band when
    /// the pet stands outside it.
    private func beginStroll() {
        if let segment = laneSegment() {
            if x < segment.lowerBound { dir = 1 } else if x > segment.upperBound { dir = -1 }
        }
        standing = false
        actionEnd = Date().addingTimeInterval(Double.random(in: Self.strollRange))
        setFacing()
    }

    /// Puts the pet back on the menu bar at (roughly) the given x and lets it
    /// patrol again. `animated` hops it there instead of teleporting.
    private func resumeMenuBarPatrol(fromX: CGFloat, animated: Bool) {
        lane = .menuBar
        settleWork?.cancel()
        settleWork = nil
        guard let window, let notchScreen = screen, let notch = inputs.notchRect, let y = laneY() else {
            returning = false
            return
        }
        let size = petSize
        x = IdlePetGeometry.menuBarLandingX(from: fromX,
                                            screenMinX: notchScreen.frame.minX,
                                            screenMaxX: notchScreen.frame.maxX,
                                            notchMinX: notch.minX,
                                            notchMaxX: notch.maxX,
                                            petSize: size)
        guard animated, window.isVisible else {
            returning = false
            beginStroll()
            placeWindow()
            if running { scheduleTick(walking: true) }
            return
        }
        returning = true
        updateSpriteState()
        let duration = 0.35
        programmaticMove = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().setFrame(NSRect(x: x, y: y, width: size, height: size), display: true)
        }
        programmaticMove = false
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, self.returning else { return }
                self.returning = false
                self.settleWork = nil
                guard self.running, self.mode == .patrolling, !self.dragging else {
                    self.updateSpriteState()
                    return
                }
                self.beginStroll()
                self.placeWindow()
                self.scheduleTick(walking: true)
            }
        }
        settleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.05, execute: work)
    }

    private func absorbIntoNotch() {
        mode = .absorbed
        dragging = false
        returning = false
        lane = .menuBar
        if visual.spriteState != "idle" { visual.spriteState = "idle" }
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
