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
import Lottie
import LottieUI
import Defaults

struct IdleAnimationView: View {
    @Default(.selectedIdleAnimation) var selectedAnimation
    @Default(.animationTransformOverrides) var overrides
    /// The box the pet is laid out in (from the notch's face). Non-zero
    /// sizes scale the animation up or down to fit while keeping its
    /// aspect ratio and the user's offset/rotation/opacity intact.
    var fittingSize: CGSize = .zero
    /// Codex/petdex atlas row to play: `idle`, `running-left`, `running-right`,
    /// `waving`, `jumping`, … Ignored by Lottie pets.
    var spriteState: String = "idle"

    /// A freshly picked pet greets with its `waving` row for a moment.
    @State private var waving = false

    /// The face pet view is destroyed/recreated when the notch closes. If the
    /// greeting task starts again on every recreation, Codex atlases that have
    /// transparent frames at the end of their waving row blink out entirely.
    /// Greet once per selected animation for the lifetime of the process.
    @MainActor
    private enum Greeting {
        static var greeted: Set<UUID> = []
    }

    private var effectiveSpriteState: String {
        (waving && spriteState == "idle") ? "waving" : spriteState
    }

    var body: some View {
        Group {
            if let animation = selectedAnimation {
                AnimationContentView(animation: animation,
                                     fittingSize: fittingSize,
                                     spriteState: effectiveSpriteState)
                    .id("\(animation.id)-\(overrides[animation.id.uuidString]?.hashValue ?? 0)")  // Force recreation when override changes
            } else {
                // No animation selected
                EmptyView()
            }
        }
        .task(id: selectedAnimation?.id) {
            guard let animation = selectedAnimation else {
                waving = false
                return
            }
            guard !Greeting.greeted.contains(animation.id) else {
                waving = false
                return
            }
            Greeting.greeted.insert(animation.id)
            waving = true
            try? await Task.sleep(for: .seconds(1.6))
            waving = false
        }
    }
}

/// Internal view that renders the actual animation content
private struct AnimationContentView: View {
    let animation: CustomIdleAnimation
    var fittingSize: CGSize = .zero
    var spriteState: String = "idle"

    /// Fits the animation's *crop box* to the notch-derived frame and then
    /// applies the user's own `scale` as a zoom on top. Folding `scale` into
    /// the fit (as this used to) cancels it out: the fitted result always
    /// came out exactly the size of the notch box, so the editor's scale
    /// slider moved nothing. `1` when no box is given (previews, editors) so
    /// the other call sites keep the hand-tuned size.
    private func fittedSize(config: AnimationTransformConfig) -> CGSize {
        let crop = CGSize(width: max(1, config.cropWidth), height: max(1, config.cropHeight))
        guard fittingSize.width > 1, fittingSize.height > 1 else {
            return CGSize(width: crop.width * config.scale,
                          height: crop.height * config.scale)
        }
        let fit = min(fittingSize.width / crop.width, fittingSize.height / crop.height)
        return CGSize(width: crop.width * fit * config.scale,
                      height: crop.height * fit * config.scale)
    }

    var body: some View {
        let config = animation.getTransformConfig()
        let size = fittedSize(config: config)
        // Debug logging
        let _ = print("🎨 [IdleAnimationView] Rendering animation: \(animation.name)")
        let _ = print("🎨 [IdleAnimationView] Config: scale=\(config.scale), offset=(\(config.offsetX), \(config.offsetY)), opacity=\(config.opacity)")

        switch animation.source {
        case .lottieFile(let url):
            LottieView(state: LUStateData(
                type: .loadedFrom(url),
                speed: animation.speed,
                loopMode: config.loopMode.lottieLoopMode
            ))
            .id(animation.id)  // Force reload when animation changes
            .frame(width: size.width, height: size.height)
            .offset(x: config.offsetX * size.width / max(1, config.cropWidth * config.scale),
                    y: config.offsetY * size.height / max(1, config.cropHeight * config.scale))
            .rotationEffect(.degrees(config.rotation))
            .opacity(config.opacity)
            .padding(.bottom, config.paddingBottom * size.height / max(1, config.cropHeight * config.scale))
            .clipped()
            
        case .lottieURL(let url):
            LottieView(state: LUStateData(
                type: .loadedFrom(url),
                speed: animation.speed,
                loopMode: config.loopMode.lottieLoopMode
            ))
            .id(animation.id)  // Force reload when animation changes
            .frame(width: size.width, height: size.height)
            .offset(x: config.offsetX * size.width / max(1, config.cropWidth * config.scale),
                    y: config.offsetY * size.height / max(1, config.cropHeight * config.scale))
            .rotationEffect(.degrees(config.rotation))
            .opacity(config.opacity)
            .padding(.bottom, config.paddingBottom * size.height / max(1, config.cropHeight * config.scale))
            .clipped()

        case .codexPet(let directory):
            if let pet = CodexPetStore.shared.pet(at: directory) {
                // Sprites keep their native 192×208 aspect; fit that into the
                // notch box, then apply the user's scale as a zoom on top.
                let base = CGSize(width: CGFloat(CodexPet.frameWidth),
                                  height: CGFloat(CodexPet.frameHeight))
                let hasBox = fittingSize.width > 1 && fittingSize.height > 1
                let fit = hasBox
                    ? min(fittingSize.width / base.width, fittingSize.height / base.height)
                    : 1
                let spriteSize = CGSize(width: base.width * fit * config.scale,
                                        height: base.height * fit * config.scale)
                CodexPetView(pet: pet, state: spriteState, speed: animation.speed)
                    .frame(width: hasBox ? spriteSize.width : nil,
                           height: hasBox ? spriteSize.height : nil)
                    .offset(x: config.offsetX * fit, y: config.offsetY * fit)
                    .rotationEffect(.degrees(config.rotation))
                    .opacity(config.opacity)
                    .padding(.bottom, config.paddingBottom * fit)
                    .clipped()
            }
        }
    }
}

// MARK: - Preview
#Preview {
    ZStack {
        Color.black
        IdleAnimationView()
    }
    .frame(width: 100, height: 50)
}
