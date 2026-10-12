# IPA 工具箱 1.2

独立 SwiftUI iOS 应用，用于自己签名安装。最低 iOS 17，支持 iPhone / iPad。

## 1.2 交互与显示

完整优化说明见 [UIUX-1.2.md](UIUX-1.2.md)。包含收藏、常驻搜索、准确的下载状态筛选、固定下载操作、轻提示、动态字体和 iPad 侧栏。

## 1.1 改进

- 原生两步登录：首次提交账号密码，遇到双重认证再显示验证码输入；验证码提交使用第二次认证请求。
- 中文错误与重试引导、短信验证码自动填充、收起键盘、修改账号入口。
- 原生下载准备页：真实阶段、耗时、取消、超时退出；取消后可重新执行。
- 界面不再展示原脚本文案、作者或链接；运行页面由本项目实现。
- 签名资源已提交到本仓库。构建只校验并复制本地文件，不再下载原脚本或访问原项目。
- 移除原项目的默认安装清单服务。已有旧预设升级后会清空；自定义地址保留。

## 功能

支持应用搜索、iOS/tvOS 版本查询、多个 Apple 账号、已购记录、后台下载、暂停恢复、队列管理、IPA 导入导出、metadata/sinf 写入、可配置版本来源及快捷指令。

1.1 已通过云编译和全部 15 个模拟器测试：[验证记录](https://github.com/mengangs/ipadn/actions/runs/38202296306)。真实账号链路仍需真机验证。

## 获取 IPA

打开本仓库 [Actions](https://github.com/mengangs/ipadn/actions/workflows/ios-build.yml)，下载成功运行的 `IPATool-unsigned-ipa` 产物。先解压再用自己的签名工具签名安装。无需向 GitHub 上传账号、证书或私钥。

本地 Mac 编译：

```bash
python3 scripts/assemble_runtime.py
bash scripts/build_unsigned_ipa.sh
```

输出 `build/IPATool-unsigned.ipa`。Xcode 首次解析 ZIPFoundation 0.9.19 需要网络；SAP 资源直接来自当前仓库。

## 代理安装

优先导出 IPA 到自己的签名工具。若需要代理安装，在设置中填写自己的 HTTPS manifest 服务地址，并配置 Surge/Loon 转发文件请求至 `http://127.0.0.1:8000/<filename>.ipa`。

清单接口继续支持元数据 name、bundleId、displayVersion、fileName（整体 query 再编码一次）。应用只提供用户选定文件的本机 HTTP 服务；不会替你部署 HTTPS 服务或重新签名。使用代理功能前必须配置自己的服务，默认不连接旧项目服务。

## 构建与测试

```bash
python3 scripts/assemble_runtime.py
python3 scripts/verify_project.py
node scripts/runtime_smoke_test.cjs
```

Actions 使用 macOS/Xcode 构建设备 IPA 并运行模拟器 XCTest。覆盖搜索、DMAP、Range、清单编码、IPA 元数据、登录挑战分支、验证取消/超时/重试。实际 Apple 账号登录、下载授权、后台生命周期及安装需要真机验收。各版本结果见 `VERIFICATION.md`。

## 依赖边界

界面、原生编排和运行桥接由本项目维护，构建及运行不需要 Scripting App、原项目仓库或原项目清单服务。底层 SAP/WASM/Unicorn 仍属于复用的第三方实现，不宣称全部自研。来源与第三方说明见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。Apple 服务和用户启用的版本接口仍需联网。
