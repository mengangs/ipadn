# IPA 工具箱

为 iPhone 和 iPad 开发的独立应用，用于发现应用、管理下载、查询历史版本和导出 IPA。支持 iOS 17 及以上，自行签名安装。

## 当前版本：1.2

- 搜索、收藏、最近记录与历史版本筛选。
- 多账号与两步认证；本地姓名头像和自选照片。
- 已购记录、应用图标、名称和时间筛选。
- 下载队列、暂停恢复、传输进度、速率及预计剩余时间。
- 页面内验证状态，可查看详情或取消，无需反复关闭弹窗。
- IPA 导入导出、浅深色、动态字号及 iPad 侧栏。

## 下载与构建

进入 [GitHub Actions](https://github.com/mengangs/ipadn/actions/workflows/ios-build.yml)，选择成功的构建并下载 `IPATool-unsigned-ipa`。解压后使用自己的签名工具安装。

源码、构建步骤和配置说明见 [使用文档](IPATool-iOS/README.md)。另见 [界面改进](IPATool-iOS/UIUX-1.2.md)、[验证记录](IPATool-iOS/VERIFICATION.md)和[组件说明](IPATool-iOS/THIRD_PARTY_NOTICES.md)。
