<div align="center">

<img src="iPadn-iOS/iPadn/Resources/Assets.xcassets/BrandMark.imageset/brand.png" width="120" alt="iPadn">

# iPadn

**在 iPhone 和 iPad 上搜索、下载、安装你拥有的 App。**
支持 iPhone、iPad、Apple TV 与 Mac 应用，包括历史版本与已下架应用。

[![最新版本](https://img.shields.io/github/v/release/mengangs/ipadn?label=%E6%9C%80%E6%96%B0%E7%89%88%E6%9C%AC&color=111111)](https://github.com/mengangs/ipadn/releases/latest)
![系统要求](https://img.shields.io/badge/iOS%20%2F%20iPadOS-17%2B-111111)
![设计](https://img.shields.io/badge/%E7%95%8C%E9%9D%A2-App%20Store%20%E9%A3%8E%E6%A0%BC-111111)

[下载](https://github.com/mengangs/ipadn/releases/latest) · [安装下载的应用](#安装下载的应用) · [常见问题](#常见问题) · [反馈问题](https://github.com/mengangs/ipadn/issues)

</div>

---

## 能做什么

| | |
| --- | --- |
| 🔍 **搜索** | 输入应用名称、App ID 或 App Store 链接，切换商店地区和平台（iPhone / iPad / Apple TV / Mac）。 |
| 🕘 **历史版本** | 在应用详情页查看并下载旧版本，也可以直接输入版本 ID。 |
| ⬇️ **下载管理** | 后台下载，随时暂停、继续、重试，实时显示速度与剩余时间。 |
| 📲 **一键安装** | 下载完成后点「安装」即可，无需描述文件或证书。 |
| 💻 **Mac 应用** | 下载 Mac App Store 应用的 PKG 安装包，传到 Mac 上安装。 |
| 🛍️ **已购项目** | 同步你获取过的所有应用，按名称或时间查找。 |
| 📦 **已下架应用** | 只要你曾经获取过，下架应用也能通过 App ID 找到并下载。 |
| 👥 **多个账号** | 保存多个 Apple 账号，一键切换。 |

界面参考 App Store 设计，支持深色模式、动态字体和 iPad 侧栏，还可以在设置中更换应用图标。

## 开始使用

> 需要 **iOS / iPadOS 17** 或更新版本。

1. 在 [Releases](https://github.com/mengangs/ipadn/releases/latest) 下载最新的 `iPadn-版本号-unsigned.ipa`。
2. 用你常用的签名工具签名后安装到设备上。
3. 打开 iPadn，在「账号」中登录 Apple 账号。需要双重认证时，输入受信任设备上显示的 6 位验证码。

> iPadn 不在 App Store 上架，发布的安装包未签名，需要自行签名。

## 下载一个应用

1. 在 **搜索** 中输入应用名称、App ID 或 App Store 链接。
2. 点「获取」直接下载最新版本；或打开应用详情，在 **版本历史** 中选择旧版本。
3. 在 **下载** 中查看进度，完成后点「安装」或分享按钮。

**小技巧**

- 想下载 Apple TV 或 iPad 版本：在搜索框下方把平台切换为对应设备。
- 找不到已下架的应用：直接搜索它的 App ID。
- 想要完整的历史版本列表：在详情页打开「从 Apple 获取完整版本列表」。
- 长按下载卡片可以查看详情、导出文件或删除任务。

## 安装下载的应用

点下载卡片上的「安装」，在系统弹窗中确认即可。安装完成前请不要退出 iPadn。

在「账号 › 设置 › 安装设置」中可以选择安装方式：

| 方式 | 适合谁 | 需要准备 |
| --- | --- | --- |
| **一键安装**（推荐） | 所有人 | 无需任何设置，安装时联网即可 |
| **本机证书** | 不想依赖任何外部服务 | 首次创建证书、安装描述文件，并在「设置 › 通用 › 关于本机 › 证书信任设置」中开启信任 |
| **代理服务** | 已在使用 Surge、Loon 等工具 | 自己的清单服务地址与代理规则 |

也可以点分享按钮，把安装包交给其他安装工具。

## Mac 应用

1. 在搜索框下方把平台切换为 **Mac**。
2. 打开应用详情，点「获取 PKG」。
3. 下载完成后点分享按钮，通过隔空投送或「文件」传到 Mac 上安装。

第一次下载 Mac 应用时，iPadn 会额外下载约 47 MB 的组件，之后会重复使用。开发者在官网提供的 DMG / PKG / ZIP 也可以在详情页直接下载。

## 你的数据

- 账号信息只保存在你的设备上，验证码不会被保存。
- 下载的安装包只保存在本机，不会上传到任何地方。
- 移除账号不会删除已下载的安装包；删除下载任务时会一并删除对应文件，操作前会再次确认。

## 常见问题

<details>
<summary><b>为什么某个应用或版本无法下载？</b></summary>

Apple 只允许下载你的账号拥有许可的应用。版本也可能已经下架或不在当前地区提供。可以换一个版本、切换商店地区，或切换到拥有该应用的账号。
</details>

<details>
<summary><b>点「安装」后没有反应？</b></summary>

请确认设备已联网，并在系统弹窗中点「安装」。使用「本机证书」方式时，需要先在系统设置中信任 iPadn 创建的证书。仍不行的话，可以分享安装包给其他安装工具。
</details>

<details>
<summary><b>已下架的应用怎么找？</b></summary>

在搜索中输入它的 App ID。只要你的账号曾经获取过这个应用，就可以继续下载。下载过一次后，它的图标也会被记住。
</details>

<details>
<summary><b>下载卡住了怎么办？</b></summary>

检查网络后暂停再继续。下载失败的任务可以直接点「重试」，不会重复添加。
</details>

<details>
<summary><b>可以下载 TestFlight 测试版吗？</b></summary>

暂不支持。已有的 IPA 文件可以通过下载页右上角的「+」导入管理。
</details>

<details>
<summary><b>移除账号会删除已下载的应用吗？</b></summary>

不会。移除账号只清除该账号的登录信息和已购记录。
</details>

## 更多

- [更新内容](RELEASE_NOTES.md)
- [自行编译](iPadn-iOS/BUILDING.md)
- [第三方组件与许可](iPadn-iOS/THIRD_PARTY_NOTICES.md)

## 许可证

iPadn 以 [GPL-2.0-or-later](LICENSE) 发布：你可以自由使用、修改和再分发，分发修改版时需要同样开放源代码。

<sub>iPadn 与 Apple Inc. 无关。请只下载你拥有合法许可的应用。</sub>
