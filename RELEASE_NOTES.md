## iPadn 1.9.1

本版本新增多语言界面，并修复若干显示问题。适用于 iOS / iPadOS 17 及更新版本；安装包未签名，请用自己的工具签名后安装。

**多语言**

- 界面支持 11 种语言：简体中文、繁體中文、English、日本語、한국어、Русский、Español、Français、Deutsch、Português (Brasil)、العربية。iPadn 跟随系统语言，也可以在「设置 › iPadn › 语言」中单独设置。
- 阿拉伯语使用从右到左的排版，列表左滑、右滑等操作随之镜像。
- 内购项目名称按界面语言显示，例如日语界面读取日本区的名称。
- 英文翻译由 [kylefmohr](https://github.com/kylefmohr) 贡献（#35）；其他语言为机器辅助翻译，欢迎在 Issues 或 Pull Request 中纠错。

**修复与改进**

- 修复简体中文界面下，多地区价格中的「免费」可能显示为繁体，应用详情中的价格可能显示为英文「Free」。
- 关注应用的价格变化通知跟随界面语言，不再跟随地区设置。
- 搜索结果中的分类单独一行，较长的分类名不再挤掉版本号。
- 已购项目的下载按钮改为云朵图标，购买日期可以完整显示。
- 安装设置中的安装方式改为列表，各语言下名称都能完整显示。

**English**

iPadn now speaks 11 languages: English, Simplified Chinese, Traditional Chinese, Japanese, Korean, Russian, Spanish, French, German, Portuguese (Brazil) and Arabic, with a right-to-left layout for Arabic. In-app purchase names follow the interface language. The English translation was contributed by [kylefmohr](https://github.com/kylefmohr) (#35); the other languages are machine-assisted, and corrections are welcome. This release also fixes prices shown in the wrong script or language, keeps versions visible next to long category names in search results, and makes install methods and purchase dates readable in longer languages.

更早版本的更新内容见 [Releases](https://github.com/mengangs/ipadn/releases)。
