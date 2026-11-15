## iPadn 2.1.3

本次为修复与体验优化更新，解决关键词搜索时的并发闪退问题，隔离顶部提示动画重绘，并改进 iOS 27 本机配对引导与灵动岛交接体验。安装包未签名，请用自己的工具签名后安装。

### 修复与优化

- **修复关键词搜索闪退与并发竞争**：移除搜索前并发嵌套任务组与超时竞争探测，改为在搜索结果返回后按商店地区顺序核验候选已下架应用（最多 15 项），并在新搜索、取消搜索或关闭开关时显式取消旧核验任务。
- **隔离全局提示动画并优化切换账号响应**：将顶部提示与撤销横幅拆分为独立视图，避免横幅弹簧动画触发整个标签页层级重绘；切换账号时先让提示横幅开始渲染，再触发地区同步、重新搜索与已购刷新。
- **优化 iOS 27 本机配对引导与灵动岛提醒**：点按「打开设置」跳转到系统设置时主动释放后台音频并推送第 1 步灵动岛横幅指引，补充锁屏密码验证提示与 11 种语言文案，后台等待状态更新支持按代数及时取消，避免旧状态阻塞新提醒。
- 继续支持 iOS / iPadOS 16 及更新版本，各功能保留各自系统版本要求。

### 两个安装包

- `iPadn-2.1.3-unsigned.ipa`：标准版，含实时活动和小组件，签名需要 2 个 App ID。
- `iPadn-2.1.3-lite-unsigned.ipa`：精简版，不含扩展，只需 1 个 App ID；不提供实时活动或小组件，其他功能相同。
- SideStore、AltStore、Feather 等签名工具可添加源：`https://raw.githubusercontent.com/mengangs/ipadn/main/altstore-source.json`。

### English

This maintenance release fixes a concurrency crash during keyword search, isolates top notice banner animations, and polishes iOS 27 on-device pairing guidance and Live Activity handoff.

- **Fix keyword-search crash & concurrency race**: Remove nested concurrent task-group pre-probes during keyword search; verify up to 15 candidate delisted apps sequentially after search results arrive and cancel stale verification tasks on new searches, cancellation or setting toggles.
- **Isolate notice overlay & smooth account switching**: Extract the top notice/undo banner into its own view so notice spring animations do not re-evaluate the entire tab hierarchy, and let the switched-account banner begin rendering before triggering region sync, search and purchase refresh.
- **Polish iOS 27 on-device pairing & Live Activity handoff**: Pause background keep-alive and push a Step 1 Dynamic Island guidance banner when opening Settings, clarify `< Settings` navigation and passcode-prompt instructions across all 11 languages, and cancel superseded Live Activity background waits promptly.
- iOS / iPadOS 16 and later remain supported, subject to each feature's requirements.

Both packages are unsigned: the standard package includes Live Activities/widgets and needs two App IDs; lite has no extension and needs one. Sign with your own tool before installing.

更早版本的更新内容见 [Releases](https://github.com/mengangs/ipadn/releases)。
