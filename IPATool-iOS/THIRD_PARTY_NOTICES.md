# 第三方组件说明

本文件用于保留组件归属与许可证信息，不属于应用界面或操作指引。

## 验证运行组件

`vendor/SAPRuntime` 包含 SAP WebAssembly、Unicorn 执行组件、Go WebAssembly 支持层和本地 JavaScript 适配层，构建时校验 `manifest.json` 的 SHA-256 后打包，无需下载其他项目资源。

现有组件内嵌的版权及许可证注释均保留。运行组件的来源记录保存于同目录的 `PROVENANCE.json`；组件没有因为本地维护而变为本项目原创。未确认的许可范围不由本项目扩张或另行授予。

## ZIPFoundation

使用 Swift Package Manager 固定解析 ZIPFoundation 0.9.19。作者及许可证见组件原始 [LICENSE](https://github.com/weichsel/ZIPFoundation/blob/0.9.19/LICENSE)，打包和再分发时应保留相应声明。

本仓库不包含 Apple 账号凭据、验证码、签名证书或私钥。
