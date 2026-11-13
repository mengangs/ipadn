## iPadn 2.0.1

本次更新改进历史版本、下载交互与自动安装，并修复侧滑裁剪和重复安装排队问题。安装包未签名，请用自己的工具签名后安装。

### 历史版本

- 显示每个版本对应的 IPA 安装包大小，而不是套用最新版的大小；读取已有元数据即可取得远端完整包大小，无需先下载整个安装包。
- 版本号、日期、大小和版本 ID 分层显示，大字体下自动纵向排列。
- 长按版本行，通过系统菜单复制版本号或版本 ID；点击菜单外即可收起。
- 兼容旧元数据缓存；无法读取大小时显示「—」。大小是远端原始 IPA 的长度，可能与下载处理后的本地文件略有差异。

### 下载与操作体验

- 下载卡片侧滑可删除或分享，分享文件名包含应用名称与版本号。
- 修复侧滑时卡片边缘被裁剪、快速滑动后分享按钮短暂变灰的问题；整张圆角卡片一起移动，收起后恢复原样。
- 点侧滑操作以外的位置即可收起，不会顺带触发下面的按钮。
- 删除后的 5 秒撤销提示显示剩余秒数和进度环。
- 下载完成时进度环转为勾号，再显示「安装」；任务长按保留原生系统菜单。
- 再点当前标签页可回到列表顶部，切换其他标签仍保留原来的滚动位置。

### 自动安装与实时活动

- 开启「下载完成后自动安装」并选择「原生安装」时，完成的下载依次直接安装，无需再次确认。需事先完成配对，并保持 LocalDevVPN 连接；其他安装方式仍需打开 iPadn 完成确认。
- 下载到安装期间保留静音音频后台保活；标准版的锁屏和灵动岛实时活动可显示下载、处理和安装状态。后台运行仍受 iOS 管理，应用被系统终止时不能保证继续；重新打开后恢复待办。
- 修复安装中切回前台可能将同一任务再次加入队列；隔离预览模式的安装待办记录，避免影响正式数据。

### 搜索与稳定性

- 最近搜索改为标签显示，可在设置中关闭搜索页的「发现」。
- 修复最近搜索标签换行后左侧圆角被列表裁剪的问题，保留原生长按菜单。
- 本机应用分组改用「App Store 未识别的应用」，表述更清晰。
- 本机应用查不到商店资料时仍可点开查看已装版本、Bundle ID 等本机信息；区分当前地区未查到资料与查询失败，可独立重试商店查询，不将缺少资料直接判为下架。
- 补充历史版本大小、旧缓存迁移、长按复制、大字体与侧滑表面的回归测试；改进模拟器启动等待及撤销测试的操作时序，不改变实际撤销期限。
- 继续支持 iOS / iPadOS 16 及更新版本，各功能保留各自系统版本要求。

### 两个安装包

- `iPadn-2.0.1-unsigned.ipa`：标准版，含实时活动和小组件，签名需要 2 个 App ID。
- `iPadn-2.0.1-lite-unsigned.ipa`：精简版，不含扩展，只需 1 个 App ID；不提供实时活动或小组件，其他功能相同。
- SideStore、AltStore、Feather 等签名工具可添加源：`https://raw.githubusercontent.com/mengangs/ipadn/main/altstore-source.json`。

### English

**Version history** now shows the remote IPA size of each individual version, using partial metadata reads rather than downloading the whole package or reusing the latest listing's size. Version, date, size and ID are separated, with a vertical layout for accessibility text sizes. Long-press a row to copy its version number or ID using the system menu. Old caches remain compatible; unavailable sizes show “—”. The remote raw IPA size can differ slightly from the processed local download.

**Downloads** gain swipe-to-delete/share with app-and-version filenames, full-card movement without clipped edges, reliable Share appearance after fast swipes, and outside-tap dismissal without activating underlying controls. Undo retains its five-second window with a countdown ring. Completion transitions to a checkmark and Install. Task long-press keeps the native menu; tapping the selected tab scrolls to the top without resetting other tabs.

**Automatic native installation** installs completed downloads sequentially without another confirmation when enabled. Pair beforehand and keep LocalDevVPN connected; other methods still need foreground confirmation. Silent audio keeps the app running from download through installation, with download/processing/install states in standard-package Live Activities. Background execution remains subject to iOS; reopening resumes pending work. Fixes duplicate queuing of an active installation on foreground return and isolates preview installation records from real data.

Recent searches use chips, Discover can be hidden in Settings, and regression coverage and simulator readiness are improved. iOS / iPadOS 16 remains supported, subject to each feature's requirements. Both unsigned packages are available: standard includes Live Activities/widgets and needs two App IDs; lite has no extension and needs one. Sign with your own tool before installing.

更早版本的更新内容见 [Releases](https://github.com/mengangs/ipadn/releases)。
