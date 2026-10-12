# IPA 工具箱

独立 iPhone / iPad 应用：搜索、下载、管理和导出应用安装包。支持自行签名安装。

源码和使用说明位于 [IPATool-iOS](IPATool-iOS/README.md)。签名运行资源保存在本仓库，构建无需访问原脚本项目。

[GitHub Actions](https://github.com/mengangs/ipadn/actions/workflows/ios-build.yml) 自动生成未签名 IPA，并执行模拟器测试。下载 `IPATool-unsigned-ipa` 产物后解压，用自己的工具签名。

1.1 增加两步认证、原生准备进度、耗时、取消与超时处理。来源和依赖说明见 [第三方说明](IPATool-iOS/THIRD_PARTY_NOTICES.md)。
