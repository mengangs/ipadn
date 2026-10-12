# 本次检查结果

交付类型：独立 iOS 源码工程，未编译、未签名、未完成真机验收。

## 已执行并通过

| 检查 | 实际结果 |
|---|---|
| Xcode OpenStep 工程文件解析 | 82 个工程对象；所有对象引用可解析 |
| Swift / 资源文件引用 | 21 个应用 Swift 文件、1 个原生测试文件；资源路径存在 |
| Shared Scheme | 应用与测试 Target 引用一致 |
| Info.plist / PrivacyInfo | plist 语法有效；HTTP 例外限定回环地址与本地联网 |
| 图标资源 | 图标槽位的文件存在；PNG 已生成 |
| Swift 括号与字符串词法检查 | 通过；这不是 Swift 编译或类型检查 |
| 原 WASM 二进制 | `WebAssembly.validate` 返回 true |
| JS / Go / Unicorn / SAP WASM 离线初始化 | Node 沙箱中初始化成功，所需入口函数存在 |
| 签名前置条件和 KBSync 输入边界 | 未初始化签名、无效 GUID、零 DSID、uint64 溢出等检查通过 |
| 原签名资源一致性 | 五个 SAPRuntime 文件 SHA-256 与附件一致 |
| Python 工程脚本 | 执行成功并通过 Python 编译检查 |
| IPA 编译脚本 | Bash 语法检查通过；未在 macOS 上执行 |

离线 WASM 检查只证明资源可以在 Node 的浏览器环境模拟中加载，并验证基础输入校验。它不证明 WebKit 兼容性、Apple 上游握手或账号请求一定成功。

## 已写入工程、尚未执行的原生测试

`CoreTests.swift` 中包含 10 个测试方法，覆盖：

- 搜索内容解析与商店数据映射。
- HTTP Range 边界与无效范围。
- 安装 manifest 的多层 URL 参数、中文名称和 URL Scheme。
- DMAP uint64、截断数据、服务错误、嵌套上限、记录去重与字段解析。
- 设置 / 下载任务的 JSON 往返保存。
- IPA 二进制 plist 读取及主应用 Bundle 选择。
- sinf 与 iTunesMetadata 的写入、路径规范化和生成 IPA。

## 尚未完成的验证

当前环境没有 Xcode / Swift 编译器 / iOS SDK，因此没有运行 Swift 编译、XCTest、模拟器或真机测试。下列事项需在 Mac 与自己的 iPhone 上完成：

1. 使用所选 Xcode SDK 编译，检查 SwiftUI、WebKit、Network、App Intents 和 ZIPFoundation API。
2. 运行工程内的 XCTest，观察界面布局、动态字体和操作流程。
3. 使用自己的账号验证双重认证、SAP 上游握手、有效 KBSync、Cookie 刷新、免费应用许可与购买记录。
4. 验证实际下载、过期 URL、授权文件处理、暂停恢复、系统后台事件和中断恢复。
5. 适配未附带的 Surge/Loon 模块，然后验证 manifest 下载、IPA 文件转发和最终安装 / 降级。
6. 检查 App Intents 在快捷指令和共享表单中的行为。

没有对外发送账号、密码、Cookie 或 Token，没有调用真实账号下载或购买接口。没有生成可直接安装的签名 IPA。

细粒度结构检查和签名资源 SHA-256 见 `verification.json`。Mac 使用方式及验收顺序见 `README.md`。
