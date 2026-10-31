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

import Defaults
import Sparkle

/// Custom Sparkle updater delegate that dynamically returns the feed URL
/// based on the user's selected update channel preference.
class AtollUpdaterDelegate: NSObject, SPUUpdaterDelegate {
    /// 自编译 fork 的安全开关：关闭 Sparkle 自动更新。
    ///
    /// 上游的 appcast 与 EdDSA 公钥仍然有效，如果保留更新器，自编译（已审计）的
    /// 版本会被上游官方构建“更新”覆盖，审计就失去意义。本地构建的
    /// CFBundleVersion（1637）也小于上游 appcast 中的 sparkle:version，
    /// 启动后几乎一定会提示更新。需要恢复上游更新时，把它改回 `true`。
    static let isUpdaterEnabled = false

    func feedURLString(for updater: SPUUpdater) -> String? {
        guard Self.isUpdaterEnabled else { return nil }
        return Defaults[.updateChannel].feedURL.absoluteString
    }
}
