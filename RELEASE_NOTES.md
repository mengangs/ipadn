## iPadn 2.1.2

本次更新优化了下载与按钮交互动画、侧滑反馈、历史版本校准及原生配对灵动岛提醒，新增直接替换翻译与已下架应用关键词优先搜索，并提升原生安装稳定性。安装包未签名，请用自己的工具签名后安装。

### 新增与优化

- **搜索优先显示已下架应用**：关键词搜索结合内置应用别名目录及本机已购、收藏、下载记录做相关度分级匹配，并核验候选应用的下架状态，将已确认下架且匹配关键词的应用优先排在结果前排；可在「账号 › 设置 › 下载 › 搜索时优先显示已下架应用」随时关闭恢复原排序（默认开启）。
- **下载操作与按钮形变动效**：下载、已购、搜索与详情页的操作按钮、云朵按钮与黑白进度环统一居中对齐，点按后以按钮中心平滑形变为加载/下载环；进度环底轨与前景进度弧统一为相同线宽，状态过渡更连贯。
- **侧滑动画与 5 秒撤销**：下载卡片侧滑垃圾桶与分享图标显露后由原生 Core Animation 播放完整动画（开启「减少动态效果」时显示静态完整图标）；下载卡片侧滑删除不再弹确认窗，改为 5 秒倒计时与撤销（连续删除可合并撤销），长按「删除任务及文件」与批量删除仍保留确认，搜索记录删除不再显示倒计时或撤销。
- **底部标签栏与同步骨架屏微光**：底部标签栏改为自适应动态矢量图标并统一描边粗细，优化搜索图标视觉重量与账号页切换动画；加载骨架屏改为全屏同相位的单色扫光（shimmer），并统一列表轻按触感与轻量化确认弹窗。
- **直接替换翻译（iOS 18+）**：简介和更新说明默认保留系统翻译面板；iOS 18 及以上可在「账号 › 设置 › 外观与图标 › 翻译」开启「直接替换翻译」，选择原文语言并准备语言包后直接替换为界面语言译文，支持「显示原文」。
- **下载列表、内联更新说明与图标开关**：精简下载任务展示与状态文案，任务信息区分商店版本、包内版本、构建号与商店版本 ID，支持在应用详情内联展开更新说明；可在「设置 › 下载 › 显示历史版本图标」按需关闭历史图标读取以节省流量和加载时间（已缓存图标仍保留）。

### 修复与稳定性

- **修复本机配对灵动岛提醒**：本机配对期间按序更新灵动岛状态，后台优先通过灵动岛实时展示配对进度与验证码，仅在灵动岛未激活时回退系统通知，并优化深色模式下配对步骤徽章对比度。
- **历史版本校准与缓存清理**：明确区分数字版本 ID（`external_identifier`）与真实营销版本号，结合商店更新记录与时间戳校准旧缓存或无点版本号，对齐各版本实际 IPA 检测，并同步清理相关版本缓存。
- **原生安装与取消稳定性**：为原生安装/查询隧道 FFI 分配 4 MiB 独立栈线程以避免栈溢出，支持取消进行中的原生安装与探测，并减少下载与自动安装期间的灵动岛状态延迟与重复入队。
- **界面布局调整**：统一对齐发现页与搜索页的最近搜索标题和芯片外边距，避免圆角被容器裁切。
- 继续支持 iOS / iPadOS 16 及更新版本，各功能保留各自系统版本要求（直接替换翻译需 iOS 18+）。

### 两个安装包

- `iPadn-2.1.2-unsigned.ipa`：标准版，含实时活动和小组件，签名需要 2 个 App ID。
- `iPadn-2.1.2-lite-unsigned.ipa`：精简版，不含扩展，只需 1 个 App ID；不提供实时活动或小组件，其他功能相同。
- SideStore、AltStore、Feather 等签名工具可添加源：`https://raw.githubusercontent.com/mengangs/ipadn/main/altstore-source.json`。

### English

This release improves delisted-app keyword search priority, action-button morph animations, swipe feedback, historical version matching and pairing Live Activity alerts, adds opt-in in-place translation on iOS 18+, and strengthens native install stability.

- **Prioritize delisted apps in search**: Keyword search combines the app alias directory with local purchased, favorite and download records for tiered relevance matching, verifies candidate delisted status, and places confirmed matching delisted apps first. Enabled by default and toggleable under Account › Settings › Downloads › Prioritize Delisted Apps in Search.
- **Centered action morph & equalized progress rings**: Align action pills, cloud buttons and progress rings on one centered column, morph pill buttons around their center into the loading/download spinner, and match the progress track and progress arc stroke width.
- **Swipe animations & five-second Undo**: Revealed swipe icons play native Core Animation sequences (with static icons when Reduce Motion is on). Swipe-deleting downloads replaces confirmation with a five-second Undo countdown (including consecutive deletions); permanent and batch deletions retain confirmation, while search-history deletion removes the countdown.
- **Vector tab bar & synchronized shimmer**: Switch tabs to adaptive vector animations with balanced strokes on Search and refined Account icon transitions, synchronize monochrome skeleton shimmer waves across rows, and unify tactile row presses and lightweight confirmations.
- **Translate in place (iOS 18+)**: Keep the system translation sheet by default, with opt-in in-place translation under Account › Settings › Appearance & icon › Translation and a Show original toggle.
- **Concise downloads, inline notes & icon toggle**: Separate store version, package version, build number and version ID in task details, expand release notes inline on app pages, and opt out of loading historical version icons under Settings › Downloads › Show Version History Icons while keeping cached icons.
- **Live Activity & native install fixes**: Serialize pairing Live Activity state updates and deliver background pairing progress/codes via Live Activity (falling back to notifications only when inactive), improve dark-mode pairing badge contrast, isolate native install/lookup FFI onto a 4 MiB stack thread with cancellation support, and keep auto-install Live Activity updates responsive.
- **Version history reconciliation & cache cleanup**: Reject raw `external_identifier` strings mistaken for marketing versions, reconcile stale or dotless versions against release notes and timestamps, and clear related version caches together.
- iOS / iPadOS 16 and later remain supported, subject to each feature's requirements.

Both packages are unsigned: the standard package includes Live Activities/widgets and needs two App IDs; lite has no extension and needs one. Sign with your own tool before installing.

更早版本的更新内容见 [Releases](https://github.com/mengangs/ipadn/releases)。
