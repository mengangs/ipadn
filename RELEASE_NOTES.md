## iPadn 1.9.2

本版本新增「支持 iPadn」页面，并修复两个问题。适用于 iOS / iPadOS 17 及更新版本；安装包未签名，请用自己的工具签名后安装。

**支持 iPadn**

- 新增「账号 › 设置 › 支持 iPadn」：iPadn 会一直免费开源、没有广告；如果它帮到了你，可以通过爱发电（支付宝、微信）或 USDT（BEP20）请作者喝杯咖啡，也可以在 GitHub 点个 Star 或帮忙改进翻译。

**下载**

- 修复部分签名方式下下载完成后提示「未能打开文件 CFNetworkDownload_….tmp，因为你没有查看它的权限」（#36）：遇到这种情况会自动改用应用内下载重新下载一次，之后的下载直接在应用内进行，下载时请保持 iPadn 在前台。首次启动时的后台下载检测也会检查文件能否读取。

**应用图标**

- 修复更新 iPadn 后，主屏幕上仍是之前选择的浅色或跟随系统图标，「设置」里却显示为深色。从本版本起 iPadn 会记住你选择的图标；更新前就遇到这种情况时，在「设置 › 应用图标 › 图标主题」中重新选择一次即可。

**English**

Adds a Support iPadn page under Account › Settings: iPadn stays free, open source and ad-free, and you can buy the author a coffee through Afdian or USDT (BEP20) if you like. Fixes downloads that failed with "you don't have permission to view CFNetworkDownload_….tmp" under some signing tools (#36): iPadn now downloads such packages again inside the app, and later downloads stay there. Also fixes Settings showing the dark icon after an update while the Home Screen kept the light or automatic icon; if this happened before updating, choose the icon theme once more in Settings.

更早版本的更新内容见 [Releases](https://github.com/mengangs/ipadn/releases)。
