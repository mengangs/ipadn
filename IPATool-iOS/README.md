# IPA 工具箱 1.2

面向 iPhone / iPad 的独立 SwiftUI 应用，最低 iOS 17。安装包由 GitHub Actions 构建，供用户自行签名安装。

## 使用

1. 在「发现」输入应用名称、App ID 或 App Store 链接。收藏常用应用，查询历史版本。
2. 在「账号」连接自己的 Apple 账号。需要双重认证时，再输入验证码。可添加多个账号并切换。
3. 在「已购」同步购买记录，按名称、App ID 或购买时间查找。应用图标从 Apple 商店公开数据补全，保存在本地缓存。
4. 选择版本加入下载。下载页显示已传输大小、百分比、速率和预计剩余时间，支持暂停、恢复、重试及批量管理。
5. 完成后导出 IPA 到签名工具，也可从「文件」导入已有安装包。

## 头像和验证提示

账号默认显示姓名头像，可通过系统照片选择器设置本机头像。照片缩小后保存在设备中，不会上传，也不会修改或同步 Apple 账号头像。当前登录响应不提供 Apple 云端头像。

已购应用图标由公开商店接口分批查询；网络不可用、应用下架或区域不匹配时显示占位图，不影响购买记录与下载操作。

请求验证时保留当前页面，只显示简洁的状态条。点按可查看阶段和耗时；取消入口始终可用，超时会自动停止。首次验证请保持应用在前台。

下载速率根据当前传输采样并平滑显示，暂停或重启后重新测速。长时间没有数据时不继续展示过期速率；总大小未知时不显示虚假的百分比或剩余时间。传输完成后单独显示安装包处理状态。

## 获取 IPA

打开 [Actions](https://github.com/mengangs/ipadn/actions/workflows/ios-build.yml)，下载成功运行的 `IPATool-unsigned-ipa` 产物并解压，再自行签名。无需向 GitHub 上传 Apple 密码、证书或私钥。

Mac 本地构建：

```bash
python3 scripts/assemble_runtime.py
bash scripts/build_unsigned_ipa.sh
```

输出 `build/IPATool-unsigned.ipa`。项目内置验证运行资源，首次解析 ZIPFoundation 0.9.19 需要联网。

## 扩展设置

可调整商店区域、iOS/tvOS 平台、并发数、队列上限、通知、外观和历史版本接口。版本来源可自行新增、修改或关闭。

支持 `ipatool://` 快捷入口及从其他应用打开 App Store 链接。若使用代理安装，需自行配置 HTTPS manifest 服务和 Surge/Loon 规则，将文件请求转至 `http://127.0.0.1:8000/<filename>.ipa`。清单参数包含 name、bundleId、displayVersion、fileName，整体 query 再编码一次。应用不会代为部署清单服务或重新签名。

## 数据和组件

登录凭据保存在本机钥匙串；验证码不保存。下载、收藏、已购缓存和自选头像保存在设备中。移除账号会清除该账号的头像及已购缓存，不删除已下载的 IPA。

原生界面、业务编排、网络层及运行桥接在本仓库维护。验证组件随应用打包；运行仍需访问 Apple 服务及用户启用的版本接口。组件归属见 [第三方说明](THIRD_PARTY_NOTICES.md)。

## 检查与测试

```bash
python3 scripts/assemble_runtime.py
python3 scripts/verify_project.py
node scripts/runtime_smoke_test.cjs
```

Actions 使用 macOS/Xcode 构建设备 IPA，执行模拟器 XCTest，并导出原生页面截图。覆盖协议解析、文件处理、认证挑战、取消和超时、下载筛选、速率边界及缓存兼容性。真实账号登录、后台下载恢复、自行签名后的安装和照片选择需要真机验收。结果见 [验证记录](VERIFICATION.md)。
