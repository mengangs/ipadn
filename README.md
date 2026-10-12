# IPA 工具箱 · Native iOS

基于 IPA-Tool-3.0.scripting 迁移的独立 SwiftUI 应用，用于自己签名安装。

源码工程和使用说明位于 `IPATool-iOS/`。GitHub Actions 在 macOS 上编译未签名 IPA，并运行模拟器单元测试。

编译完成后打开 Actions 对应运行，下载 `IPATool-unsigned-ipa` 产物，再用自己的工具签名安装。

无需上传 Apple 账号、签名证书或私钥。
