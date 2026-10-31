# Atoll 安全审计报告（静态审计）

- 审计对象：fork `Aihuu08/Atoll`，基线提交 `e13f4aba3fc3c459a38cd0757322754c8558c476`（`dev` HEAD，`VERSION` = 2.3.3，`MARKETING_VERSION` = 2.3.3）
- 仓库中**没有任何 tag**（含 `v2.3.3`），所以基线就是上面这个 commit。本次没有推送 `audit-base` tag（工作分支限定为 `claude/clever-wright-cd1iaw`），需要的话在本地执行：`git tag audit-base e13f4aba3fc3c459a38cd0757322754c8558c476 && git push origin audit-base`
- 方法：只读静态审计（`grep`/阅读源码/`git`），**没有执行**仓库里的任何脚本、测试或构建。Linux 环境，无法编译或运行 macOS 应用。
- 状态标注：**已确认** = 读过相关代码；**推测** = 只见到线索或依赖运行时行为；**未检查** = 不在本次范围内。
- 静态审计只能降低风险，**不能证明安全**。下文所说的“未发现问题”都只限于所列范围。

---

## 1. 一页摘要

**整体判断**：在本次检查范围内**没有发现恶意代码**（没有后门、没有遥测/统计 SDK、没有远程下载并执行代码、没有混淆的可执行内容、没有把数据发往非预期主机）。仓库里也**没有发现写给 AI 助手的隐藏指令**。但发现了几处**设计层面的高危漏洞**，主要集中在“第三方扩展”接口和更新机制上；其中会直接影响自编译版本的已在本分支修复（见第 6 节）。

**最重要的 5 条发现：**

1. **[高 · 已确认 · 已修复] 扩展 WebSocket 接口可被本机任意进程（很可能还包括浏览器网页）利用，实现任意文件读取和任意文件写入。** `127.0.0.1:9020` 的 JSON-RPC 服务会**自动授权**任何自称的 `bundleIdentifier`，默认授予包括 `fileSharing` 在内的全部权限，而且功能默认开启、App 启动就监听。`addFilesToShelf` 把客户端传来的 `fileName` 直接拼进路径（`../` 穿越 → 可写 `~/Library/LaunchAgents` 等，进而持久化/代码执行）；`paths` + `getShelfItemData` 可以读取任意文件（如 `~/.ssh/id_*`、`~/.claude/.credentials.json`）。没有 Origin 校验，浏览器网页理论上也能连上（是否会被浏览器的本地网络访问限制拦截属**推测**，需在 Mac 上验证）。
2. **[高 · 已确认 · 已修复] Sparkle 仍指向上游更新源，自编译版本会被上游官方构建“更新”覆盖。** `SUFeedURL` 与 `UpdateChannel.feedURL` 都指向 `raw.githubusercontent.com/Ebullioscopic/Atoll/main/Updates/*.xml`，`SUPublicEDKey` 是上游公钥；本地 `CURRENT_PROJECT_VERSION = 1637` 小于上游 appcast 的 `sparkle:version 20260720004`，所以启动后几乎一定会提示更新。审计过的版本会被绕过。
3. **[中 · 已确认 · 已修复] Claude 额度功能会刷新 Claude Code 的 OAuth 令牌并写回钥匙串/凭据文件。** 它用 Claude Code 的 `client_id` 调 `platform.claude.com/v1/oauth/token` 轮换 refresh token，然后通过 `/usr/bin/security -i` 写回 `Claude Code-credentials*` 钥匙串项或 `~/.claude/.credentials.json`，并伪装 `User-Agent: claude-code/2.1.69`。代码里有竞争保护（只在过期后刷新、先重读），但和 Claude Code 同时刷新时仍可能让一方的 refresh token 失效 → Claude Code 被登出。请求只发往 Anthropic，功能默认关闭。已改为**只读**。
4. **[中 · 已确认 · 已修复] 剪贴板历史默认开启并明文持久化，且不跳过密码管理器标记的内容。** 历史存在 `UserDefaults`（`ClipboardHistory`，明文 plist），没有检查 `org.nspasteboard.ConcealedType` 等标记，从 1Password/Bitwarden 复制的密码会落盘。
5. **[中 · 已确认 · 已修复] AirPlay 设备名 AppleScript 注入。** 设备名只转义了 `"` 没转义 `\`，局域网中广播恶意名称的 AirPlay 设备（如 `x\" & (do shell script "…") & \"`）在用户点选它或调它的音量时可执行任意 shell 命令。需要用户交互且 Music 在运行，可利用性属**推测**。

其他值得注意：Screen Assistant 的 API key 明文存 UserDefaults、Gemini key 拼在 URL 里（已改为请求头）；ATS 全局放开 `NSAllowsArbitraryLoads`；entitlements 里 `disable-library-validation = true`；XPC 扩展连接方只用 PID 反查 bundle ID，没有代码签名校验。

---

## 2. 发现清单

行号均指基线提交 `e13f4ab`。

| # | 严重度 | 位置 | 证据 | 状态 | 建议 / 处理 |
|---|---|---|---|---|---|
| F1 | 高 | `services/Extensions/ExtensionRPCService.swift:154`、`ExtensionRPCServer.swift:390`、`managers/Extensions/ExtensionAuthorizationManager.swift:213`、`models/Constants.swift:1381,1394`、`DynamicIslandApp.swift:709-710` | RPC `atoll.requestAuthorization` 注释写着 “Auto-authorize for now”，对任意自报的 bundleIdentifier 直接授权；默认 scope = 全部（含 `fileSharing`）；`enableThirdPartyExtensions`、`enableExtensionFileSharing` 默认 `true`；XPC/RPC 在启动时无条件监听 | 已确认 | **已修复**：两个开关默认关闭；只在开关打开时监听；新授权不再默认给 `fileSharing` |
| F2 | 高 | `ExtensionRPCService.swift:576` | `tempDir.appendingPathComponent(fileName)`，`fileName` 来自客户端，可含 `../` → 任意路径写文件 | 已确认 | **已修复**：只取 `lastPathComponent`，拒绝 `.`/`..`/隐藏文件，并校验最终目录 |
| F3 | 高 | `ExtensionRPCService.swift:551`、`:450` | `addFilesToShelf` 的 `paths` 接受任意本地路径，`getShelfItemData` 返回 base64 文件内容 → 已授权客户端可读任意文件 | 已确认 | **已缓解**：扩展默认关闭；首次授权需用户在弹窗中确认（F21）；`fileSharing` 不再默认授予，需在设置里手动勾选。`paths` 逻辑本身未改 |
| F4 | 高（推测） | `ExtensionRPCServer.swift` `makeListener` | WebSocket 握手不检查 `Origin`，浏览器页面可尝试连 `ws://127.0.0.1:9020` | 推测（取决于浏览器的本地网络访问策略） | **已加固**：带 `Origin` 头的握手直接拒绝。API 签名已对照 Apple 文档核实；Apple 论坛的实测输出显示 `Host` 等标准头也会出现在 `additionalHeaders` 里，`Origin` 大概率同样会出现（仍需在 Mac 上验证）。官方 Swift SDK（AtollExtensionKit）只用 XPC，不使用 WebSocket，因此不受影响 |
| F5 | 高 | `Info.plist:20`、`models/UpdateChannel.swift:53`、`DynamicIslandApp.swift:43` | 上游 feed + 上游 EdDSA 公钥，自动检查更新 | 已确认 | **已修复**：`AtollUpdaterDelegate.isUpdaterEnabled = false`，不启动 updater，删掉 `SUFeedURL`，关闭自动检查/自动更新 |
| F6 | 中 | `managers/LLMUsage/Quota/ClaudeQuotaClient.swift:175,189,231,140`、`KeychainReader.swift` | 读取 `~/.claude/.credentials.json` → 钥匙串 `Claude Code-credentials*`；过期后用 refresh token 刷新并写回；伪装 UA | 已确认 | **已修复**：`allowsTokenRefresh = false`，只读不刷新、不写回。默认 `enableLLMUsageFeature = false`（:1283），但打开后 Claude provider 默认开（:1284） |
| F7 | 中 | `managers/ClipboardManager.swift:562`、`Constants.swift:1359,1364` | 剪贴板管理默认开、持久化默认开，存 UserDefaults 明文；不识别 Concealed/Transient 标记 | 已确认 | **已修复**：带 nspasteboard.org 标记的内容不入历史。仍建议在设置里关闭“持久化剪贴板历史” |
| F8 | 中 | `managers/AppleMusicAirPlayManager.swift:123,217` | 只转义 `"`，不转义 `\` | 已确认（代码），推测（可利用性） | **已修复**：先转义 `\` 再转义 `"`，换行替换为空格 |
| F9 | 中 | `managers/ScreenAssistantManager.swift:418`、`Constants.swift:1371-1374` | Gemini key 拼进 URL query；四个 API key 存 `Defaults`（UserDefaults 明文 plist） | 已确认 | **已修复**：Gemini key 改走 `x-goog-api-key` 头；4 个 key 迁到钥匙串（`managers/ScreenAssistantAPIKeys.swift`），启动时自动迁移旧值并清空 UserDefaults |
| F10 | 中 | `services/Extensions/ExtensionXPCServiceHost.swift:129`、`ExtensionXPCService.swift:57` | XPC 连接方身份 = `NSRunningApplication(processIdentifier:)` 的 bundleIdentifier，无 audit token / 代码签名校验，有 PID 复用竞争；首次连接自动授权 | 已确认 | **已缓解**：默认不监听；首次授权改为弹窗确认（F21）。代码签名校验**未做**：需要知道扩展的签名要求，自用场景下意义不大 |
| F11 | 中 | `DynamicIsland.entitlements:5` | `com.apple.security.cs.disable-library-validation = true`（构建设置 `RUNTIME_EXCEPTION_DISABLE_LIBRARY_VALIDATION = NO` 不会覆盖 entitlements 文件里的显式值） | 已确认 | **已移除**：App 只 `dlopen`/`Bundle.load` 系统框架（DisplayServices、IOReport、CoreBrightness、SkyLight），`MediaRemoteAdapter.framework` 只放在 Resources 里由 `/usr/bin/perl` 加载。需在 Mac 上验证启动和各项功能；若启动崩溃，回退该提交即可 |
| F12 | 中 | `Info.plist:7` | ATS `NSAllowsArbitraryLoads = true` | 已确认 | **有意未改**：所有写死的外部地址都是 https，收紧 ATS 收益有限；而 LocalSend（局域网 IP 上的 http）、YouTube Music（`localhost:26538`）、自定义 Ollama 地址、用户自填的动画 URL 都依赖 http，改了以后这些功能会悄悄失效、不容易发现 |
| F13 | 低 | `components/Shelf/Services/LocalSendService.swift:627,1058` | 打开分享面板时在所有网卡上监听 LocalSend 端口（只处理 register 请求，不接收文件）；TLS 代理接受任意证书（LocalSend 协议本身使用自签证书） | 已确认 | 仅用户触发；局域网中间人可截获你**发出**的文件。不用 LocalSend 可忽略 |
| F14 | 低 | `managers/SpotifyAuthManager.swift:36`、`Constants.swift:1244` | 从第三方仓库 `xyloflake/spot-secrets-go` 拉取 TOTP 密钥（数据，不是代码）；`sp_dc` Cookie 明文存 UserDefaults | 已确认 | 只有手动填了 sp_dc Cookie 才会触发。Cookie 只发往 `open.spotify.com`。不用 Spotify Canvas 可忽略 |
| F15 | 低 | `components/Extensions/ExtensionLockScreenWidgetView.swift:357` | 扩展 HTML 用 `loadHTMLString(baseURL: nil)` 加载；导航策略只管顶层导航，不拦截 JS 的 `fetch`/图片等子资源；**没有** JS bridge（未发现 `WKScriptMessageHandler`） | 已确认 | 扩展关闭时不涉及 |
| F16 | 低 | `DynamicIslandApp.swift` 导出日志 | 用户手动导出时打包最近 2 天的 unified log 与崩溃报告；`Logger` 以 `%{public}@` 记录所有内容 | 已确认 | 没有自动上传。分享日志前自己看一遍 |
| F17 | 信息 | `managers/LLMUsage/ModelPricingManager.swift:98` | 启动 LLM 用量功能后从上游 `dev` 分支拉 `pricing.json`（纯 JSON 价格表，解码后只用于计算费用） | 已确认 | 数据而非代码。介意可删掉远程拉取，只用内置表 |
| F18 | 信息 | `managers/WebcamManager.swift:212`、`CameraMonitor.swift` | 摄像头只有 `AVCaptureVideoPreviewLayer` + 未设置 delegate 的 `AVCaptureVideoDataOutput`；`CameraMonitor` 只用 CoreMediaIO 属性 `DeviceIsRunningSomewhere` 检测别的 App 是否在用摄像头，自己不开 session | 已确认 | 无问题 |
| F19 | 信息 | `managers/TerminalManager.swift:294`、`Constants.swift:1301` | 刘海终端（SwiftTerm 本地进程）默认关闭；shell 路径来自用户设置 | 已确认 | 不用就保持关闭 |
| F21 | 高 | `ExtensionRPCService.swift:139-158` | RPC 授权只要条目不是“已授权”就自动授权，**连用户拒绝或撤销过的条目也会被重新授权**，设置里的撤销实际无效 | 已确认 | **已修复**：只有 `pending` 状态才弹窗询问（XPC 同样）；拒绝或撤销后需在设置中手动恢复。WebSocket 来源的弹窗会注明“无法验证身份” |
| F20 | 信息 | 仓库全局 | 未发现写给 AI 助手的指令、未发现长 base64/混淆脚本、未发现遥测/统计/崩溃上报 SDK | 已确认（grep 范围内） | — |

---

## 3. 权限矩阵

| 权限 | 用途说明（原文要点） | 谁触发 / 何时 | 数据去向 | 能否关闭 | 默认 |
|---|---|---|---|---|---|
| 摄像头 Camera | Mirror（镜子）模式 | 用户点开刘海里的镜子 / 设置里切换摄像头且 `showMirror` 开启时 | 仅本地预览层，不落盘、不联网（已确认） | `showMirror` | 关 |
| 麦克风 Microphone | AI 助手语音提问 | 用户在 Screen Assistant 里点录音 | 录音保存在 `~/Documents/ScreenAssistantAudio/`，作为附件发给所选 AI 服务商 | `enableScreenAssistant` | 功能开，但需填 API key 才能发送 |
| 屏幕录制 ScreenCapture | AI 助手截图 | 用户在 Screen Assistant 里点截图（`/usr/sbin/screencapture`） | 截图经剪贴板读入，保存为 `~/Documents/ScreenAssistantScreenshots/screenshot_<时间戳>.png`（不是桌面），作为附件发给 AI 服务商 | 同上 | 同上 |
| 音频捕获 AudioCapture | 音乐波形、按 App 调音量 | 开启波形/按 App 音量功能时 | 本地实时处理 | 对应设置项 | 未逐项核实（**推测**跟随设置） |
| 定位 Location | 锁屏天气 | 锁屏天气小组件启用时 | 坐标发往 open-meteo（默认）或 wttr.in | `enableLockScreenWeatherWidget` | **开** |
| 日历 / 提醒事项 | 刘海日历、提醒实时活动 | 日历功能启用时 | 本地 | 日历相关设置 | 未逐项核实 |
| 蓝牙 | 耳机连接与电量 HUD | 启动后常驻 | 本地 | 蓝牙 HUD 设置 | 未逐项核实 |
| Apple Events | 控制 Spotify / Music / Notes；系统事件（注销、停止录屏快捷键） | 媒体控制、备忘录同步、录屏停止 | 本地 | 不用相应功能即不触发 | — |
| 桌面 / 文稿 / 下载 | 截图保存、暂存架文件 | 用户操作 | 本地 | — | — |
| 钥匙串（无用途说明，系统弹窗） | LLM 用量读取 Claude Code / Codex / Cursor / Antigravity 令牌 | 打开 LLM 用量功能后 | 只发往对应厂商 API | `enableLLMUsageFeature` + 各 provider 开关 | 关（provider 子开关默认开） |
| 完全磁盘访问（引导中会请求） | 自定义专注模式指示、暂存架 | 引导页 | 本地 | 可以不授予 | — |

**未发现**不经用户操作就自动启动摄像头、麦克风或屏幕录制的路径（已确认摄像头；麦克风与截图只在 Screen Assistant 的显式操作里调用，属已确认的调用点范围内）。

---

## 4. 出站网络表

| 主机 | 用途 | 触发条件 | 发送的数据 | 可关闭 |
|---|---|---|---|---|
| `raw.githubusercontent.com/Ebullioscopic/Atoll/main/Updates/*.xml` | Sparkle 更新 | **已在本分支禁用** | 版本号、系统版本（Sparkle 默认） | 已关 |
| `github.com/Ebullioscopic/Atoll/releases/...` | 更新包下载 | 同上 | — | 已关 |
| `raw.githubusercontent.com/Ebullioscopic/Atoll/dev/.../pricing.json` | LLM 价格表 | LLM 用量功能 | 无 | 是 |
| `raw.githubusercontent.com/xyloflake/spot-secrets-go/...` | Spotify Web Player TOTP 密钥 | 配置了 sp_dc Cookie | 无 | 是 |
| `api.anthropic.com/api/oauth/usage`、`platform.claude.com/v1/oauth/token` | Claude 额度（刷新已禁用） | LLM 用量 + Claude provider | Claude Code OAuth 令牌 | 是 |
| `chatgpt.com/backend-api/wham/usage` | Codex 额度 | LLM 用量 + Codex | Codex 令牌 | 是 |
| `api2.cursor.sh`、`cursor.com/api/usage-summary` | Cursor 额度 | LLM 用量 + Cursor | Cursor 令牌 | 是 |
| `cloudcode-pa.googleapis.com`、`daily-cloudcode-pa.googleapis.com`、本机 Antigravity 语言服务器端口 | Antigravity 额度 | LLM 用量 + Antigravity | Google 令牌 | 是 |
| 用户自填的 New API 地址 | New API 额度 | 用户添加账号 | 该账号 key（存钥匙串） | 是 |
| `generativelanguage.googleapis.com`、`api.openai.com`、`api.anthropic.com/v1/messages`、`api.groq.com`、自定义本地地址（默认 `localhost:11434`） | Screen Assistant | 用户发消息 | 消息文本、附件（截图/录音/文件）、API key | 是 |
| `api.open-meteo.com`、`air-quality-api.open-meteo.com`（默认）/ `wttr.in` | 锁屏天气、AQI | 天气小组件（默认开） | 经纬度 | 是 |
| `lrclib.net`、`music.163.com` | 歌词 | 歌词功能（默认关） | 歌名、艺人 | 是 |
| `itunes.apple.com`、`api.music.apple.com`、`mvod.itunes.apple.com` | 封面、动态封面 | 播放音乐时 | 歌名/艺人、歌曲 ID | 部分 |
| `api.spotify.com`、`accounts.spotify.com`、`open.spotify.com`、`spclient.wg.spotify.com` | Spotify 喜欢按钮（OAuth）/ Canvas | 用户配置 Spotify | OAuth 令牌 / sp_dc Cookie | 是 |
| `assets9.lottiefiles.com`、用户自填的动画 URL | Lottie 动画 JSON | 显示对应动画时 | 无 | 部分 |
| `localhost:26538` | YouTube Music Desktop 本地 API | 使用 YouTube Music | — | 是 |
| 局域网 IP（LocalSend 53317，HTTP/HTTPS + 组播 `224.0.0.167`） | LocalSend 发现与发送 | 用户打开分享面板 | 设备信息、你选择发送的文件 | 是 |
| `ebullioscopic.github.io`、`getatoll.app`、`lunar.fyi`、`betterdisplay.pro`、`developer.spotify.com` 等 | 只是可点击的链接 | 用户点击 | — | — |

- **远程配置 / 可执行内容**：`ebullioscopic.github.io` 只用于打开隐私政策网页链接；`raw.githubusercontent.com` 拉取的是 appcast（已禁用）、`pricing.json`（JSON 数据）和 Spotify TOTP 密钥（JSON 数据）。**未发现**下载并执行代码或脚本的路径。
- **遥测 / 统计 / 崩溃上报**：未发现任何 SDK 或上报端点。
- **监听端口**：`127.0.0.1` / `::1` 的 9020（扩展 RPC，本分支改为默认不监听）；LocalSend 端口（用户打开分享面板时，所有网卡）；XPC mach service `com.ebullioscopic.Atoll.xpc`（本分支改为默认不监听）。

---

## 5. 子进程表

所有调用点的可执行文件都是**写死的绝对路径**，没有经过 shell（`Process` 直接传参数数组）。

| 调用点 | 可执行文件 | 参数 | 是否受外部输入影响 |
|---|---|---|---|
| `MediaControllers/NowPlayingController.swift:259`、`AmazonMusicController.swift:188`、`helpers/MediaChecker.swift:52` | `/usr/bin/perl` | App 包内 `mediaremote-adapter.pl` + 框架路径 + 固定子命令 | 否（路径来自 Bundle） |
| `managers/LLMUsage/Quota/KeychainReader.swift:132` | `/usr/bin/security` | `find-generic-password` / `-i`（stdin 写 `add-generic-password`，有转义） | 服务名来自钥匙串枚举；写回已在本分支禁用 |
| `managers/LLMUsage/AntigravityUsageProvider.swift:77,228,332` | `/usr/bin/security`、`/bin/ps`、`/usr/sbin/lsof` | 固定 | 否 |
| `components/ScreenAssistant/ScreenshotSnippingTool.swift:101` | `/usr/sbin/screencapture` | 固定枚举 | 否 |
| `components/Shelf/Services/TemporaryFileStorageService.swift:158` | `/usr/bin/zip` | 暂存架文件名 | 文件名作为独立参数（**推测**：若文件名以 `-` 开头会被 zip 当作选项，影响有限） |
| `components/Shelf/Services/LocalSendService.swift:389` | `/usr/sbin/arp` | `-an` | 否 |
| `DynamicIslandApp.swift:1333,1357` | `/usr/bin/log`、`/usr/bin/zip` | 固定 / 保存路径来自 NSSavePanel | 用户选择 |
| `managers/SystemOSDManager.swift`、`helpers/SystemHUDDebugger.swift`、`FullScreenArtworkWindowManager.swift`、`ScreenRecordingManager.swift` | `/bin/launchctl`、`/usr/bin/killall`、`/usr/bin/pgrep` | 固定（重启 OSDUIHelper 等系统 HUD） | 否 |
| `managers/DoNotDisturbManager.swift`、`SystemTimerBridge.swift`、`BluetoothAudioManager.swift` | `/usr/bin/log`、`/usr/bin/pmset`、`/usr/sbin/system_profiler`、`/usr/sbin/ioreg` | 固定 | 否 |
| `managers/KeyboardBrightnessSensor.swift`、`SystemDisplayManager.swift` | `/usr/libexec/corebrightnessdiag` | 固定 | 否 |
| `managers/StatsManager.swift`、`NetworkConnectivityManager.swift` | `/bin/ps`、`/usr/sbin/networksetup` | 固定 | 否 |
| `managers/TerminalManager.swift:294` | 用户设置的 shell（默认 `/bin/zsh`） | — | 用户设置；功能默认关闭 |
| `helpers/AppleScriptRunner.swift`、`AppleScriptHelper.swift`、`components/DynamicIslandSystemTiles.swift:72` | NSAppleScript | Spotify/Music 固定命令、Notes（有完整转义）、AirPlay（**F8，已修复**）、注销、录屏停止快捷键 | 见 F8 |
| `helpers/DisplayServicesDynamic.swift:34`、`utils/IOReportBridging.swift:31` | `dlopen` | 系统私有框架绝对路径 | 否 |

未发现 `posix_spawn`、`system()`、`NSUserAppleScriptTask` 调用。

---

## 6. 依赖与供应链

### SwiftPM（`Package.resolved` 已固定 revision）

| 包 | 版本 / 分支 | revision | 说明 |
|---|---|---|---|
| AtollExtensionKit | **branch main** | `e2d30afe` | 上游作者自己的扩展 SDK |
| LaunchAtLogin-Modern (sindresorhus) | **branch main** | `a04ec1c3` | 开机启动 |
| SkyLightWindow (Lakr233) | **branch main** | `4a7e8628` | 锁屏层窗口（私有 API） |
| LottieUI (jasudev) | **branch main** | `0cd5b54a` | Lottie SwiftUI 封装 |
| lottie-spm (airbnb) | **branch main**（间接） | `04f2fd18` | Lottie |
| Defaults | 9.0.3 | `00c82eff` | 设置存储 |
| KeyboardShortcuts | 2.3.0 | `045cf174` | 全局快捷键 |
| MacroVisionKit | 0.1.0 | `5e8b06c4` | 全屏检测 |
| open-meteo | 1.4.16 | `f18ccb78` | 天气 API 客户端（天气功能需要） |
| Pow | 1.0.5 | `a504eb6d` | 动画效果 |
| Sparkle | 2.7.0 | `0ca3004e` | 更新（本分支已禁用） |
| swift-argument-parser / swift-collections / swift-syntax | 1.7.1 / 1.1.4 / 601.0.1 | — | Apple 官方 |
| SwiftTerm | 1.13.0 | `8e7a1e15` | 刘海终端 |
| swiftui-introspect | 1.3.0 | `807f73ce` | SwiftUI 内省 |

**本次额外审计了 5 个跟踪 `main` 分支的依赖在固定 revision 上的源码**（clone 后只读）：
- AtollExtensionKit `e2d30af`：约 2300 行 Swift，只用 `NSXPCConnection(machServiceName:)` 与 Atoll 通信；没有网络请求、子进程、钥匙串或 UserDefaults 访问。
- SkyLightWindow `4a7e862`：276 行，`dlopen` 系统私有框架 `SkyLight` 并 `dlsym` 几个 `SLS*` 函数，用来把窗口放到锁屏层；没有网络请求、没有其他可疑内容。
- LaunchAtLogin-Modern `a04ec1c`：156 行，基于 `SMAppService`，无可疑内容。
- LottieUI `0cd5b54`：946 行，只有示例工程里引用了 lottiefiles 的 URL。
- lottie-spm `04f2fd1`：airbnb 官方预编译的 `Lottie.xcframework` 4.5.2（从 GitHub Release 下载，SwiftPM 会校验 checksum `92206ff6…6694`）。

标为 **branch main** 的 5 个依赖：Xcode 正常构建会使用 `Package.resolved` 里固定的 revision，但如果执行了 “Update to Latest Package Versions” 或删掉了 `Package.resolved`，就会拉取最新提交。建议命令行构建时加 `-onlyUsePackageVersionsFromResolvedFile`，并且不要在 Xcode 里点“更新包”。

### 预编译产物

- `Frameworks/MediaRemoteAdapter.framework` 与 `mediaremote-adapter/MediaRemoteAdapter.framework`：同一个 universal Mach-O（sha256 `829e9cdb…bdac`），Bundle ID `com.vandenbe.MediaRemoteAdapter` 0.1。**推测**来自开源项目 `ungive/mediaremote-adapter`。字符串中只有系统框架和 MediaRemote 私有框架，没有网络地址。
- `Contents/Helpers/NowPlayingTestClient`：arm64 Mach-O（sha256 `4ef9a27d…795d`），`com.vandenbe.MediaRemoteAdapter.NowPlayingTestClient`。
- `mediaremote-adapter/mediaremote-adapter.pl`：257 行 Perl，只是加载框架并调用函数（sha256 `248bc02f…bff`）。
- **Mac 阶段任务**：从源码重建上面三个文件并比对，或至少 `codesign -dvvv` 看签名者。
- Git LFS：9 个文件，全部是 `.mov`/`.gif` 媒体（已确认，未拉取内容）。

### GitHub Actions（`.github/workflows/`）

- `release.yml`：签名（Developer ID 证书）、公证、Sparkle EdDSA 签名、发布；使用 `DEVELOPER_ID_*`、`APPLE_API_KEY_*`、`SPARKLE_ED_PRIVATE_KEY`、`APP_ID/APP_PRIVATE_KEY`。
- `mirror-release.yml`：用 `ORG_REPO_TOKEN` 把发布镜像到 `Atoll-Labs/Atoll`。
- `update-pricing.yml`（每日定时）：从 `openrouter.ai` 拉模型价格，提交回仓库。
- `nightly-merge.yml`（每日定时）：合并 `dev` → `nightly`。
- `triage-slash-commands.yml`：受信用户在 issue 评论 `/close` 关闭 issue。
- 在你的 fork 上这些 secret 都不存在；**建议在 fork 的 Settings → Actions 里直接禁用 Actions**，避免定时任务在 fork 上跑。

`scripts/`、`tests/`、`Updates/`、`COPYRIGHT_ASSETS` 中没有发现混淆或看不懂的内容（只读，未执行）。`scripts/test_claude_keychain.sh` 只编译 `KeychainReader.swift` 和一个测试文件，用随机 UUID 名称的临时钥匙串项做测试，不读取真实 Claude 凭据（已确认）。

---

## 7. 未能审计 / 必须在 Mac 上验证

1. 编译本分支。本环境**无法编译**，没有任何“构建通过”的结论。已用 Swift 6.0.3（Linux）对全部 41 个改动的 Swift 文件执行 `swiftc -parse`，**语法**全部通过；但 Linux 上没有 AppKit/Network/Security，**类型检查做不了**。
2. 扩展开关打开后，用 `websocat ws://127.0.0.1:9020`（不带 Origin）能连上；在浏览器控制台 `new WebSocket("ws://127.0.0.1:9020")` 应被拒绝。若浏览器也能连上，说明 `Origin` 不在 `additionalHeaders` 里，需要换方案。
3. 关闭再打开“启用第三方扩展”后，XPC listener 能否重新创建成功（`NSXPCListener(machServiceName:)` 二次创建）。
4. 删除 `disable-library-validation` 后 App 能否启动、各功能是否正常（F11）。
5. 首次连接扩展时会弹出授权确认框（F21）；AI 助手原来填过的 key 迁到钥匙串后仍然可用（F9）。
6. 重建并比对 `MediaRemoteAdapter.framework`、`NowPlayingTestClient`。
7. 运行时抓包（Little Snitch / LuLu）确认实际出站主机与第 4 节一致。
8. 音频捕获、日历、蓝牙、定位等权限的实际触发时机（第 3 节标“未逐项核实”的项）。
9. **未检查**：版本号固定的那些 SwiftPM 依赖（Sparkle、Defaults、SwiftTerm 等知名项目）的源码；Metal shader；`DynamicIslandTests`/`DynamicIslandUITests` 内容。

---

## 8. 建议的最小权限配置

本分支已经做了的：
- 关闭 Sparkle（F5）
- 第三方扩展、扩展文件共享默认关闭，不再无条件监听 XPC 和 9020 端口（F1）
- Claude 额度只读（F6）
- 剪贴板不记录密码类内容（F7）
- 扩展首次授权需弹窗确认，拒绝/撤销后不会被自动重新授权（F21）
- AI 助手 API key 存钥匙串（F9）
- 移除 `disable-library-validation`（F11）
- AirPlay AppleScript 注入、扩展路径穿越、Gemini key 进 URL 等具体漏洞（F2、F8、F9）

建议你在设置里手动确认 / 关闭：

| 功能 | 建议 | 理由 |
|---|---|---|
| 第三方扩展（Extensions） | **保持关闭** | F1–F4、F10。如果之前装过官方 Atoll（同一个 Bundle ID `com.Ebullioscopic.Atoll`），旧设置会沿用，请到“扩展”设置确认开关是关的，并删除已授权的扩展条目 |
| LLM 用量（Claude/Codex/Cursor/Antigravity） | 不需要就保持关闭；需要的话只开 Claude | 读取多家的登录令牌 |
| 刘海终端 | 保持关闭（默认关） | 刘海里的真终端 |
| Screen Assistant | 不用就关闭；用的话 key 只给有额度上限的 | key 明文存 UserDefaults |
| 剪贴板历史持久化 | 建议关闭“持久化剪贴板历史” | 历史明文落盘 |
| LocalSend | 不用就别打开分享面板 | 监听局域网端口、接受任意证书 |
| 锁屏天气 | 按需 | 会把坐标发给天气服务 |
| Spotify sp_dc Cookie | 不填 | 完整会话 Cookie 明文存储 |

后续可选（本分支**未做**）：
- XPC 加代码签名校验（`setCodeSigningRequirement`）；RPC 的 `paths` 限制为用户选过的文件。
- 改用自己的 Bundle ID（例如 `com.<你>.Atoll`），与上游的设置和 TCC 授权彻底隔离。注意 XPC mach service 名是写死的 `com.ebullioscopic.Atoll.xpc`，与 Bundle ID 无关。

---

## 9. 不会被自动本地化的字符串

**已处理（第二轮）**：用 `String(localized:)` 包裹了 145 处写死的界面字符串，包括窗口/面板标题、Screen Assistant 错误提示、Spotify/New API/更新状态文案、专注模式名称、隐私指示、计时器状态、各 `LocalizedError` 描述，以及“刚刚 / N 分钟前”等相对时间；另外补上了 50 条代码中已使用、但 xcstrings 里缺失的键。新增 zh-Hans 共 168 条。品牌名和标识符保持原样，并确认这些字符串没有参与逻辑比较。

剩余未处理（下表为第一轮扫描的原始清单，大部分已在上述处理中覆盖）：

| 类别 | 位置示例 | 数量（约） |
|---|---|---|
| 窗口/面板标题直接赋字面量 | `SettingsWindowController.swift:57`（"Atoll Settings"）、`ClipboardWindowManager.swift:47`、`LockScreenWidgetPreviewManager.swift:216`、`AtollUserDriver.swift:148`、`SettingsView.swift:7769`、`ShelfItemViewModel.swift:754,912`、`QuickShareService.swift:193`、`ExtensionRPCService.swift:479`、`DynamicIslandApp.swift:1339,1689` | 12 |
| Screen Assistant 错误提示 `addAssistantMessage("Error: …")` | `ScreenAssistantManager.swift` | 26 |
| 状态 / 错误文案直接赋字面量 | `SpotifyAuthManager.swift`（7）、`SpotifyLoginSheet.swift`（2）、`NewAPIUsage.swift`、`UpdateErrorView.swift`、`AnimationEditorView.swift`、`SettingsView.swift` | 13 |
| 枚举 `return "Xxx"` 后传给 `Text(变量)` | `Constants.swift`（14）、`DoNotDisturbManager.swift`（10）、`DynamicIslandCalendar.swift`（7）、`ImageProcessingService.swift`、`StatsManager.swift`、`UsageProvider.swift`、`LocalSendService.swift`、`YouTubeMusicNetworking.swift`、`TimerManager.swift`、`PrivacyIndicatorManager.swift`、`ScreenshotSnippingTool.swift:49-51` | ~90 |
| `throw XxxError("…")` 的错误描述 | 多处 | ~35 |
| 菜单栏 `MenuBarExtra("dynamic.island")`、`Button("Restart Atoll")` 等 | `DynamicIslandApp.swift` | 少量（SwiftUI `Button("字面量")` 会自动本地化，取决于 xcstrings 是否有对应键） |

注：`String` 变量传给 `Text(...)` 时不会查表，需要改成 `String(localized:)` 或 `LocalizedStringKey`。部分键（如 "Area"、"Window"、"Full Screen"）虽然 xcstrings 里已有中文，但由于代码返回的是普通 `String`，界面上仍会显示英文。
