# 交接给 Mac：编译与验证清单

云端（Linux）只做了静态审计、文本修改和格式校验，**没有编译、没有运行**。以下所有“已改动”都需要你在 Mac 上编译确认。

- 审计基线：`e13f4aba3fc3c459a38cd0757322754c8558c476`（上游 `dev`，2.3.3）
- 工作分支：`claude/clever-wright-cd1iaw`
- 完整审计报告：`docs/audit/AUDIT.md`

查看本分支相对基线的全部改动：

```bash
git diff --stat e13f4aba3fc3c459a38cd0757322754c8558c476..HEAD
```

## 1. 改动清单

| 提交 | 改动 | 目的 | 风险 |
|---|---|---|---|
| 关闭 Sparkle | `AtollUpdaterDelegate.isUpdaterEnabled = false`；`DynamicIslandApp` 不启动 updater；`Info.plist` 删掉 `SUFeedURL`，加 `SUEnableAutomaticChecks=false`、`SUAutomaticallyUpdate=false` | 防止自编译版本被上游官方构建覆盖 | “检查更新”按钮会变灰。以后合并上游时，上游改动这几处会产生冲突 |
| 扩展接口加固 | 扩展与扩展文件共享默认关闭；只在开关打开时监听 XPC 和 `127.0.0.1:9020`；新授权不再默认给 `fileSharing`；`fileName` 防路径穿越；拒绝带 `Origin` 的 WebSocket 握手 | 修复任意文件读写（AUDIT F1–F4） | `setClientRequestHandler` 的写法需要编译验证；如果你用 Electron/网页类扩展，它们会被拒绝 |
| AppleScript / 剪贴板 | AirPlay 设备名先转义 `\` 再转义 `"`；剪贴板跳过 `org.nspasteboard.ConcealedType` 等标记 | 修复注入（F8）；密码不落盘（F7） | 极小 |
| Gemini / Claude | Gemini key 改走 `x-goog-api-key` 请求头；Claude 额度 `allowsTokenRefresh = false` | key 不进 URL/日志（F9）；不再轮换 Claude Code 的令牌（F6） | Claude 令牌过期后额度显示为空，等 Claude Code 自己刷新（用一次 `claude` 命令）即可恢复 |
| 汉化 | `Localizable.xcstrings` 补全 209 条 zh-Hans（覆盖率 99.9%）并统一术语；新增 `zh-Hans.lproj/InfoPlist.strings`（权限弹窗中文）；`knownRegions` 加 `zh-Hans` | 中文界面 | 只改了文本；JSON 格式与 Xcode 输出逐字节一致（已用脚本确认） |
| 工具 | `tools/check_xcstrings.py` | 校验 xcstrings | 不在 App target 内 |
| 文档 | `docs/audit/AUDIT.md`、本文件 | — | — |

## 2. 编译前要改的地方（本分支没有动）

1. **签名团队**：工程里写死的是上游的 `DEVELOPMENT_TEAM = 9Y64TRM77N`，Release 配置还是 `CODE_SIGN_STYLE = Manual` + `Developer ID Application`。在 Xcode → Target `DynamicIsland` → Signing & Capabilities 里改成你自己的 Team（个人自用推荐 Debug 配置或把 Release 改为 Automatic + Apple Development）。
2. **Bundle ID（建议）**：Debug 是 `com.Ebullioscopic.Atoll.dev`，Release 是 `com.Ebullioscopic.Atoll`，和官方版相同，会共用旧设置和隐私授权。想彻底隔离就改成自己的，例如 `com.<你的名字>.Atoll`。
3. **依赖**：不要在 Xcode 里点 “Update to Latest Package Versions”。有 5 个依赖跟踪 `main` 分支，`Package.resolved` 固定了审计时的 revision。

## 3. 编译

用 Xcode 打开 `DynamicIsland.xcodeproj`，选 scheme `DynamicIsland`，直接 Run（Debug）。

或命令行（只使用 `Package.resolved` 里固定的依赖版本）：

```bash
xcodebuild -project DynamicIsland.xcodeproj -scheme DynamicIsland -configuration Debug -onlyUsePackageVersionsFromResolvedFile build
```

如果在 Mac 上用 Claude Code 编译遇到错误，最可能出问题的是 `DynamicIsland/services/Extensions/ExtensionRPCServer.swift` 里 `wsOptions.setClientRequestHandler(queue) { ... }` 这一段（API 签名凭记忆写的）。实在编不过可以先删掉这一段，扩展默认关闭时它不影响安全。

## 4. 编译后要验证的点

- [ ] App 能启动，菜单栏“检查更新”是灰的；用 Little Snitch / LuLu 观察，不应访问 `raw.githubusercontent.com/Ebullioscopic/Atoll/main/Updates/...`
- [ ] 设置 → 扩展：“启用第三方扩展”默认是关的。执行 `lsof -iTCP:9020 -sTCP:LISTEN`，应当没有输出
- [ ] 打开扩展开关后再执行上面的命令，应该看到 Atoll 在 `127.0.0.1`/`::1` 上监听；在浏览器控制台执行 `new WebSocket("ws://127.0.0.1:9020")` 应该连接失败；关掉开关后端口消失
- [ ] 系统语言设为简体中文后，摄像头/麦克风/屏幕录制/定位等权限弹窗显示中文；设置页基本都是中文
- [ ] 从 1Password / Bitwarden 复制密码，Atoll 剪贴板历史里不应出现
- [ ] Mirror（镜子）只在你点开时亮摄像头指示灯
- [ ] 如果打开了 LLM 用量 → Claude：能显示额度，且 Claude Code 不会被登出
- [ ] 校验翻译文件（只校验格式）：`python3 tools/check_xcstrings.py`

## 5. 建议在 Mac 上继续做（本分支未做）

- 删除 entitlements 里的 `com.apple.security.cs.disable-library-validation`，验证媒体控制、歌词、锁屏等功能是否正常（AUDIT F11）
- 把 ATS 的 `NSAllowsArbitraryLoads` 改成 `NSAllowsLocalNetworking`，验证 LocalSend / YouTube Music / Ollama（F12）
- 从 `ungive/mediaremote-adapter` 源码重建 `MediaRemoteAdapter.framework` 和 `NowPlayingTestClient`，与仓库里的文件比对，或至少执行 `codesign -dvvv` 查看签名者
- Screen Assistant 的 API key 迁移到钥匙串（可复用 `NewAPIKeychain`）
- 在 fork 的 GitHub Settings → Actions 里禁用 Actions（定时任务 `update-pricing`、`nightly-merge` 在 fork 上没用）

## 6. 明确**没有**验证的事

- 没有编译，也没有运行，**不能说“构建通过”**
- 没有验证 `NSXPCListener` 关闭后再次创建是否成功（只在你切换扩展开关时才会发生）
- 没有验证 Network.framework 是否把 `Origin` 头放进 `additionalHeaders`
- 没有审计 SwiftPM 依赖本身的源码
- 中文翻译没有在真实界面里看过排版（长句可能被截断）
- 剩下 1 个没翻译的键是 `q`（快捷键字母，不需要翻译）；仓库根目录的 `Localizable.xcstrings` 不属于任何 target（Xcode 同步目录只包含 `DynamicIsland/` 和 `Contents/`），是遗留文件，没有改动
