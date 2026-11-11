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

import Foundation

/// NetEase Cloud Music (网易云音乐).
///
/// The app publishes full now-playing metadata — title, artist, album, artwork
/// and elapsed time — through macOS MediaRemote, and accepts the standard
/// MediaRemote play/pause/next/previous/seek commands. There is no scripting
/// dictionary or local API, so favouriting, shuffle and repeat reporting are
/// not available; the capability table says so instead of pretending.
final class NetEaseMusicController: FilteredNowPlayingController {
    static let bundleIdentifier = "com.netease.163music"

    init?() {
        super.init(
            bundleIdentifier: Self.bundleIdentifier,
            controllerName: "NetEaseMusicController"
        )
    }
}
