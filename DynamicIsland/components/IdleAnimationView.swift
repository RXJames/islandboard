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

    var body: some View {
        Group {
            if let animation = selectedAnimation {
                AnimationContentView(animation: animation, fittingSize: fittingSize)
                    .id("\(animation.id)-\(overrides[animation.id.uuidString]?.hashValue ?? 0)")  // Force recreation when override changes
            } else {
                // No animation selected
                EmptyView()
            }
        }
    }
}

/// Internal view that renders the actual animation content
private struct AnimationContentView: View {
    let animation: CustomIdleAnimation
    var fittingSize: CGSize = .zero

    /// Scale that makes the animation's own crop box fit the notch-derived
    /// frame. `1` when no box is given (previews, editors) so every other
    /// call site keeps the hand-tuned size.
    private func fittedSize(config: AnimationTransformConfig) -> CGSize {
        let intrinsic = CGSize(width: max(1, config.cropWidth * config.scale),
                               height: max(1, config.cropHeight * config.scale))
        guard fittingSize.width > 1, fittingSize.height > 1 else { return intrinsic }
        let fit = min(fittingSize.width / intrinsic.width, fittingSize.height / intrinsic.height)
        return CGSize(width: intrinsic.width * fit, height: intrinsic.height * fit)
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
