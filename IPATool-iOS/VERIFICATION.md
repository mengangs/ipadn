# 1.1 验证

本地结构检查与离线运行资源初始化检查已通过。新版云编译、14 个 XCTest 与真机登录结果尚未确认；下方记录仅属于 1.0。

# 云编译与测试结果

2026-10-12，工程在 GitHub Actions 完成验证：

- Xcode 26.0.1（17A400），macOS 15 runner。
- iPhone 设备 Release 编译成功，生成未签名 IPA。
- iOS 26 模拟器测试成功：10 个测试，0 个失败。
- IPA ZIP 完整性和 SHA-256 已校验。
- IPA 内五个 SAP 签名资源的 SHA-256 与用户附件全部一致。
- App Intents 元数据包含三个操作与两个 App Shortcuts。

[编译与测试运行](https://github.com/mengangs/ipadn/actions/runs/38195930796)

[下载未签名 IPA](https://github.com/mengangs/ipadn/actions/runs/38195930796/artifacts/11722874325)

IPA 大小：26,356,503 字节。

IPA SHA-256：`a6e4d268342250dbef3b3079ae3b3269d381d550263ed2b002187a711a46512e`。

源码编译 commit：`1f5c9faf006a31d1aa726ac49ed5244648c0f08d`。

## 原生测试范围

搜索解析、商店数据映射、Range 请求、manifest URL 编码、DMAP 数值 / 截断 / 嵌套 / 去重、设置及任务保存、IPA 元数据读取、metadata 与 sinf 授权写入。

此外，工程引用、配置文件、图标资源和原 WASM 的离线初始化检查通过。`verification.json` 是静态检查脚本报告；其中未运行项目仅指该脚本自身，不代表 Actions 没有编译或执行测试。

## 真机仍需验证

Apple 登录与验证码、有效 SAP/KBSync 上游握手、Cookie 刷新、免费许可获取、真实已购记录、后台生命周期、实际下载授权、代理模块适配和安装 / 降级。

没有提供真实 Apple 凭据，没有发送密码或 Token，没有执行真实账号购买或下载。IPA 未签名，需使用自己的证书或签名工具后安装。

运行记录中的产物保留 14 天；之后可手动触发 Actions 重新编译。
