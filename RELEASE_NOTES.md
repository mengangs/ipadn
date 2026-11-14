## iPadn 2.1.1

本次为修复与布局优化更新，包含 iOS 16 安装设置崩溃修复和历史版本日期范围筛选排版改进。安装包未签名，请用自己的工具签名后安装。

### 修复与优化

- **修复 iOS 16 打开安装设置时崩溃**：对安装帮助链接的中文片段进行显式编码，并避免无效 URL 的强制解包。感谢 #86 的贡献。
- **完善商店链接容错**：应用详情无法构造有效 App Store 链接时，不再强制解包或显示不可用的查看/分享入口。
- **优化历史版本日期筛选面板**：将起止日期、查询/取消/清除按钮与状态提示集中展示，统一日期控件对齐和布局间距，并适配无障碍大字体。保留原有日期查询、取消与清除行为。详见 #87。
- 继续支持 iOS / iPadOS 16 及更新版本，各功能保留各自系统版本要求。

### 两个安装包

- `iPadn-2.1.1-unsigned.ipa`：标准版，含实时活动和小组件，签名需要 2 个 App ID。
- `iPadn-2.1.1-lite-unsigned.ipa`：精简版，不含扩展，只需 1 个 App ID；不提供实时活动或小组件，其他功能相同。
- SideStore、AltStore、Feather 等签名工具可添加源：`https://raw.githubusercontent.com/mengangs/ipadn/main/altstore-source.json`。

### English

This maintenance update fixes a crash when opening Installation settings on iOS 16 and improves the version-history date-range filter layout.

- Encode the installation-help URL fragment explicitly for iOS 16 and remove unsafe URL force-unwrapping (#86).
- Safely omit App Store viewing/sharing controls when a valid store link cannot be constructed.
- Group date-range fields, query/cancel/clear actions and status in one panel, with aligned controls, consistent spacing and an adaptive accessibility layout (#87). Existing query behavior is unchanged.
- iOS / iPadOS 16 and later remain supported, subject to each feature's requirements.

Both packages are unsigned: the standard package includes Live Activities/widgets and needs two App IDs; lite has no extension and needs one. Sign with your own tool before installing.

更早版本的更新内容见 [Releases](https://github.com/mengangs/ipadn/releases)。
