# 1.1 云编译与测试结果

2026-10-12：Xcode 26.0.1 / iOS 26 模拟器。

- Release 设备编译成功，未签名 IPA 版本 1.1 (2)，最低 iOS 17。
- 15 个 XCTest 全部通过，0 个失败。包含两步登录请求编码与挑战分支、真实 WebKit 待定操作取消后重试、超时退出及原有文件/协议测试。
- 本地资源完整性、工程检查、离线 WASM 初始化通过。
- 额外离线检查使用虚构 GUID/DSID 成功生成 196 字节初始化数据，约 9.6 秒；此检查没有请求 Apple 或使用真实账号。
- IPA ZIP 完整性、SHA-256、版本号及全部 5 个运行资源校验通过。

[完整运行记录](https://github.com/mengangs/ipadn/actions/runs/38202296306) · [IPA 产物](https://github.com/mengangs/ipadn/actions/runs/38202296306/artifacts/11725203166)

编译提交：`c4f6c4cc6396a3fbff182f3bc97db6111566f878`。

IPA 大小：26,391,028 字节。

IPA SHA-256：`bc0e637e6a285aa54217e005c745d245b5f8c9626bb7292bed57001912af38ee`。

真实 Apple 登录、授权下载、已购记录、后台生命周期及签名安装仍需在用户设备上验证。两步认证修复已经通过响应/请求测试，不等于已经使用用户账号成功登录。

构建和运行不访问原脚本仓库或原项目清单服务；底层签名计算仍复用第三方组件，详见 THIRD_PARTY_NOTICES.md。代理安装需要自行配置 HTTPS 清单服务，IPA 导出不受影响。

---

## 1.0 历史记录（以下不是当前 IPA）

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
