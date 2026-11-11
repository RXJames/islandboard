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

private final class LiquidGlassContainerView: NSView {
    weak var glassView: NSView?
    /// Layer-backed wrapper around the material view. `NSGlassEffectView`
    /// (and `NSVisualEffectView`) composite their backdrop through the
    /// WindowServer and ignore the view's own `alphaValue`; fading the
    /// wrapper's `layer.opacity` is what actually makes the material
    /// translucent while the hosted content stays fully opaque.
    weak var glassOpacityHost: NSView?
    /// Current material opacity (0 = fully transparent, 1 = fully opaque).
    /// Applied directly to every `CABackdropLayer` under the glass because
    /// those layers are composited by the WindowServer and do not inherit
    /// ancestor `layer.opacity`.
    var backdropOpacity: CGFloat = 1.0
    var hostingView: NSHostingView<AnyView>?

    private var observedBackdropLayers: [CALayer] = []
    private var hasScheduledBackdropSetup = false
    private let windowServerAwareKeyPath = "windowServerAware"
    private let scaleKeyPath = "scale"

    deinit {
        removeBackdropObservers()
    }

    override func removeFromSuperview() {
        removeBackdropObservers()
        super.removeFromSuperview()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        scheduleBackdropSetup()
    }

    override func layout() {
        super.layout()
        scheduleBackdropSetup()
    }

    func scheduleBackdropSetup() {
        guard !hasScheduledBackdropSetup else { return }
        hasScheduledBackdropSetup = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }
            self.hasScheduledBackdropSetup = false
            self.configureBackdropLayers()
        }
    }

    private func configureBackdropLayers() {
        guard let glassView else { return }
        guard let rootLayer = glassView.layer else {
            // AppKit creates the glass backing layer lazily, after the
            // window has been displayed at least once. Keep rescheduling
            // until it exists.
            scheduleBackdropSetup()
            return
        }

        setBackdropProperties(in: rootLayer)
        let newBackdropLayers = collectBackdropLayers(in: rootLayer)
        // The glass backing layer sets `allowsGroupBlending = NO` and the
        // backdrop is composited by the WindowServer, so neither the view's
        // `alphaValue` nor an ancestor `layer.opacity` dims it. Opacity has
        // to be written onto the material's own layer subtree.
        applyOpacity(in: rootLayer)

        removeBackdropObservers()
        observedBackdropLayers = newBackdropLayers
        for backdrop in observedBackdropLayers {
            backdrop.addObserver(self, forKeyPath: windowServerAwareKeyPath, options: [.old, .new], context: nil)
            backdrop.addObserver(self, forKeyPath: scaleKeyPath, options: [.old, .new], context: nil)
            backdrop.addObserver(self, forKeyPath: "opacity", options: [.old, .new], context: nil)
        }
    }

    private func setBackdropProperties(in layer: CALayer) {
        if NSStringFromClass(type(of: layer)).contains("CABackdropLayer") {
            layer.setValue(true, forKey: windowServerAwareKeyPath)
            layer.setValue(1.0, forKey: scaleKeyPath)
        }
        layer.sublayers?.forEach { setBackdropProperties(in: $0) }
    }

    /// Fades the material's own layer subtree. `GlassBackingLayer` disables
    /// group blending and the WindowServer composites the backdrop directly,
    /// so ancestor opacity never reaches it — every layer under the glass
    /// backing has to carry the value.
    private func applyOpacity(in layer: CALayer) {
        layer.opacity = Float(backdropOpacity)
        layer.sublayers?.forEach { applyOpacity(in: $0) }
    }

    /// Synchronous fade for `updateNSView`, so slider drags take effect on
    /// the spot instead of waiting for the next coalesced backdrop pass.
    func applyOpacityNow() {
        guard let rootLayer = glassView?.layer else { return }
        applyOpacity(in: rootLayer)
    }

    private func collectBackdropLayers(in layer: CALayer) -> [CALayer] {
        var results: [CALayer] = []
        if NSStringFromClass(type(of: layer)).contains("CABackdropLayer") {
            results.append(layer)
        }
        layer.sublayers?.forEach { results.append(contentsOf: collectBackdropLayers(in: $0)) }
        return results
    }

    override func observeValue(
        forKeyPath keyPath: String?,
        of object: Any?,
        change: [NSKeyValueChangeKey: Any]?,
        context: UnsafeMutableRawPointer?
    ) {
        if keyPath == windowServerAwareKeyPath {
            if change?[.newKey] as? Bool == false {
                configureBackdropLayers()
            }
        } else if keyPath == scaleKeyPath {
            guard let layer = object as? CALayer else { return }
            if let newScale = (change?[.newKey] as? NSNumber)?.doubleValue, newScale != 1.0 {
                layer.setValue(1.0, forKey: scaleKeyPath)
            }
        } else if keyPath == "opacity" {
            guard let layer = object as? CALayer else { return }
            let expected = Float(backdropOpacity)
            if abs(layer.opacity - expected) > 0.001 {
                layer.opacity = expected
            }
        } else {
            super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
        }
    }

    private func removeBackdropObservers() {
        for layer in observedBackdropLayers {
            layer.removeObserver(self, forKeyPath: windowServerAwareKeyPath)
            layer.removeObserver(self, forKeyPath: scaleKeyPath)
            layer.removeObserver(self, forKeyPath: "opacity")
        }
        observedBackdropLayers.removeAll()
    }
}

/// All 20 available liquid‑glass variants.
/// Apple does not publicly describe how each value looks so experiment and pick the one you like!
public enum LiquidGlassVariant: Int, CaseIterable, Identifiable, Defaults.Serializable, Sendable {
    case v0  = 0,  v1  = 1,  v2  = 2,  v3  = 3,  v4  = 4
    case v5  = 5,  v6  = 6,  v7  = 7,  v8  = 8,  v9  = 9
    case v10 = 10, v11 = 11, v12 = 12, v13 = 13, v14 = 14
    case v15 = 15, v16 = 16, v17 = 17, v18 = 18, v19 = 19

    public var id: Int { rawValue }

    public static let supportedRange = 0...19

    public static var defaultVariant: LiquidGlassVariant { .v11 }

    public static func clamped(_ rawValue: Int) -> LiquidGlassVariant {
        let clamped = min(max(rawValue, supportedRange.lowerBound), supportedRange.upperBound)
        return LiquidGlassVariant(rawValue: clamped) ?? .defaultVariant
    }

    /// Raw translucency of the material itself (0…1). The lock-screen
    /// panels no longer drive this with the slider — fading the frost away
    /// just deletes the material and looks wrong. They keep the glass at
    /// full strength and stack a solid backdrop over it instead, which is
    /// how Apple renders partially transparent materials: the refraction
    /// stays, the panel milks over.
    public var backgroundOpacity: Double {
        Double(rawValue) / Double(LiquidGlassVariant.supportedRange.upperBound)
    }

    /// Slider semantics: left (0) is a fully opaque panel, right (19) is
    /// pure liquid glass. This is the alpha of the solid colour layered on
    /// top of the glass — the inverse of the slider position.
    public var panelSolidity: Double {
        1.0 - backgroundOpacity
    }
}

/// A SwiftUI view that embeds its content inside Apple’s private liquid‑glass material.
///
/// ```swift
/// GlassBackground(variant: .v11, cornerRadius: 12) {
///     VStack(spacing: 12) {
///         Image(systemName: "sparkles")
///             .font(.largeTitle)
///         Text("Hello, glass!")
///             .font(.title2)
///     }
///     .padding()
/// }
/// ```
public struct LiquidGlassBackground<Content: View>: NSViewRepresentable {
    private let content: Content
    private let cornerRadius: CGFloat
    private let variant: LiquidGlassVariant
    private let opacity: Double
    /// Creates a new liquid‑glass container.
    /// - Parameters:
    ///   - variant: Any ``LiquidGlassVariant`` (0–19). Defaults to `.v11`, which is visually super pleasing
    ///   - cornerRadius: Corner radius in points. Defaults to `10`.
    ///   - opacity: Material opacity, 0 (glass invisible, wallpaper as-is)
    ///     through 1 (full glass). The hosted content always stays fully
    ///     opaque; only the material fades.
    ///   - content: Your SwiftUI hierarchy.
    public init(
        variant: LiquidGlassVariant = .defaultVariant,
        cornerRadius: CGFloat = 10,
        opacity: Double = 1,
        @ViewBuilder content: () -> Content
    ) {
        self.variant      = variant
        self.cornerRadius = cornerRadius
        self.opacity      = min(max(opacity, 0), 1)
        self.content      = content()
    }


    @inline(__always)
    private func setterSelector(for key: String, privateVariant: Bool = true) -> Selector? {
        guard !key.isEmpty else { return nil }
        let name: String
        if privateVariant {
            let cleaned = key.hasPrefix("_") ? key : "_" + key
            name = "set" + cleaned
        } else {
            let first = String(key.prefix(1)).uppercased()
            let rest  = String(key.dropFirst())
            name = "set" + first + rest
        }
        return NSSelectorFromString(name + ":")
    }

    private typealias VariantSetterIMP = @convention(c) (AnyObject, Selector, Int) -> Void

    private func callPrivateVariantSetter(on object: AnyObject, value: Int) {
        guard
            let sel   = setterSelector(for: "variant", privateVariant: true),
            let m     = class_getInstanceMethod(object_getClass(object), sel)
        else {
            #if DEBUG
            print("✗ LiquidGlassBackground: selector set_variant: not found. falling back to default")
            #endif
            return
        }
        let imp = method_getImplementation(m)
        let f   = unsafeBitCast(imp, to: VariantSetterIMP.self)
        f(object, sel, value)
    }



    public func makeNSView(context: Context) -> NSView {
        // `NSGlassEffectView` is private. Look it up dynamically to avoid compile‑time coupling.
        if let glassType = NSClassFromString("NSGlassEffectView") as? NSView.Type {
            let container = LiquidGlassContainerView(frame: .zero)
            container.translatesAutoresizingMaskIntoConstraints = false
            container.backdropOpacity = opacity

            let glass = glassType.init(frame: .zero)
            glass.translatesAutoresizingMaskIntoConstraints = false
            glass.setValue(cornerRadius, forKey: "cornerRadius")
            callPrivateVariantSetter(on: glass, value: variant.rawValue)

            // The content rides as a sibling above the material, NOT inside
            // it: the opacity host fades only the glass, so a transparent
            // panel still shows its album art and text at full strength.
            // `alphaValue` on the material itself is ignored by the
            // WindowServer backdrop compositing, hence the layer wrapper.
            let opacityHost = NSView(frame: .zero)
            opacityHost.translatesAutoresizingMaskIntoConstraints = false
            opacityHost.wantsLayer = true
            opacityHost.layer?.opacity = Float(opacity)
            opacityHost.addSubview(glass)

            let hosting = NSHostingView(rootView: AnyView(content))
            hosting.translatesAutoresizingMaskIntoConstraints = false

            container.addSubview(opacityHost)
            container.addSubview(hosting)
            NSLayoutConstraint.activate([
                opacityHost.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                opacityHost.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                opacityHost.topAnchor.constraint(equalTo: container.topAnchor),
                opacityHost.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                glass.leadingAnchor.constraint(equalTo: opacityHost.leadingAnchor),
                glass.trailingAnchor.constraint(equalTo: opacityHost.trailingAnchor),
                glass.topAnchor.constraint(equalTo: opacityHost.topAnchor),
                glass.bottomAnchor.constraint(equalTo: opacityHost.bottomAnchor),
                hosting.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                hosting.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                hosting.topAnchor.constraint(equalTo: container.topAnchor),
                hosting.bottomAnchor.constraint(equalTo: container.bottomAnchor)
            ])

            container.glassView = glass
            container.glassOpacityHost = opacityHost
            container.hostingView = hosting
            container.scheduleBackdropSetup()
            return container
        }

        // Fallback for earlier macOS – use an ordinary blur, faded the same
        // layer-backed way so the opacity slider actually does something.
        let container = LiquidGlassContainerView(frame: .zero)
        container.translatesAutoresizingMaskIntoConstraints = false

        let opacityHost = NSView(frame: .zero)
        opacityHost.translatesAutoresizingMaskIntoConstraints = false
        opacityHost.wantsLayer = true
        opacityHost.layer?.opacity = Float(opacity)

        let effect = NSVisualEffectView()
        effect.material = .underWindowBackground
        effect.translatesAutoresizingMaskIntoConstraints = false
        opacityHost.addSubview(effect)

        let hosting = NSHostingView(rootView: AnyView(content))
        hosting.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(opacityHost)
        container.addSubview(hosting)
        NSLayoutConstraint.activate([
            opacityHost.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            opacityHost.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            opacityHost.topAnchor.constraint(equalTo: container.topAnchor),
            opacityHost.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            effect.leadingAnchor.constraint(equalTo: opacityHost.leadingAnchor),
            effect.trailingAnchor.constraint(equalTo: opacityHost.trailingAnchor),
            effect.topAnchor.constraint(equalTo: opacityHost.topAnchor),
            effect.bottomAnchor.constraint(equalTo: opacityHost.bottomAnchor),
            hosting.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: container.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        container.hostingView = hosting
        return container
    }

    public func updateNSView(_ nsView: NSView, context: Context) {
        guard let container = nsView as? LiquidGlassContainerView else { return }
        container.hostingView?.rootView = AnyView(content)
        if let glass = container.glassView {
            glass.setValue(cornerRadius, forKey: "cornerRadius")
            callPrivateVariantSetter(on: glass, value: variant.rawValue)
            container.backdropOpacity = opacity
            container.applyOpacityNow()
        }
        container.glassOpacityHost?.layer?.opacity = Float(opacity)
        if container.glassView != nil {
            container.scheduleBackdropSetup()
        }
    }
}
