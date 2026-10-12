# 构建 iPadn

项目使用 SwiftUI，最低 iOS 17，面向 iPhone 和 iPad。Xcode 工程为 `iPadn.xcodeproj`，共享 scheme 为 `iPadn`。当前版本 1.2，build 9。

## 本地构建

在 Mac 安装 Xcode 后，从本目录运行：

```bash
python3 scripts/assemble_runtime.py
bash scripts/build_unsigned_ipa.sh
```

输出为 `build/iPadn-unsigned.ipa`。验证运行组件由本仓库提供，ZIPFoundation 0.9.19 由 Swift Package Manager 解析。

新增 Swift 文件后，运行 `python3 scripts/generate_project.py` 更新工程。

## 检查

```bash
python3 scripts/verify_project.py
node scripts/runtime_smoke_test.cjs
```

校验报告输出到 `build/verification.json`，不会修改受跟踪文件。

GitHub Actions 对 PR、main 推送及手动构建执行设备编译、模拟器测试和界面截图，产物分别为 `iPadn-unsigned-ipa`、`iPadn-interface-screenshots`、`iPadn-build-diagnostics`。测试范围与验收记录见 [VERIFICATION.md](VERIFICATION.md)。

## 扩展

历史版本接口使用 `external_identifier` 和 `bundle_version` 字段，可在设置中配置地址模板及容器键。

代理安装清单接受 name、bundleId、displayVersion、fileName；整个 query 再编码一次。文件请求通过用户配置的代理规则转发到 `http://127.0.0.1:8000/<filename>.ipa`。应用仅提供选定文件的本机服务。

Release 不包含截图用的虚构数据入口。原生网络、验证桥接、队列与文件处理均在当前工程内维护；组件归属见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

## 名称目录

`iPadn/Resources/app-name-directory.json` 由本项目维护，字段为 `id`、`name`、`aliases`、`platform`（`itunes` / `atv9`）和可核对的 `source`。新增记录应确认名称与 Apple App ID 的对应关系，不加入下载直链或账号资料。目录只解析名称，不授予下载许可。当前目录规模有限，不宣称覆盖全部下架应用。

## 数据和测试隔离

Debug `--visual-preview` 使用独立的设置域、钥匙串服务和临时文件目录，不写入正式账号或下载记录。演示下载管理器不启动真实传输。发行构建不包含演示入口。

清理构建产物时仅处理本仓库已忽略的 `build/`、`DerivedData/` 等生成目录；不要删除设备中的 Documents/Packages 或 Application Support/iPadn。
