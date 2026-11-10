# 原生安装对照原型

本工具用于验证 App Store 识别、电脑软件分类和覆盖安装三项问题，不改变 iPadn 1.8.5 的现有安装器，也不发布新版本。

## 当前范围

- 离线读取同一份 IPA 的显示版本、构建版本、根目录购买元数据和主程序/扩展 SINF，计算 SHA-256。
- 通过已信任的 USB 设备连接调用 `installation_proxy` 的 `Install` / `Upgrade`。没有签名、改包、卸载、自动重试或失败后卸载重装代码。
- `store` 模式将包内原始 `iTunesMetadata.plist` 和主程序 SINF 作为 **plist Data（二进制）** 安装参数发送；`embedded` 模式仅传 Bundle ID，保留同一 IPA，作为对照。两种模式均不指定 `PackageType=Developer`。
- 安装前后查询目标应用的系统允许返回属性。查询不确定时停止，不把它当作“未安装”。新装遇到已有应用会拒绝；覆盖升级必须显式选择 `upgrade`，并核对同一 Bundle ID 和构建版本。
- 当前只研究同版本覆盖、正常升级；拒绝降级、占位/已卸载保留数据状态、无法比较的构建号，禁止安装支付宝。
- 报告不保存原始账号元数据、账号/设备 ID、授权文件、配对记录。系统错误名称、域、代码和脱敏说明单独记录。报告默认写入仓库忽略目录 `.build/native-install-reports`，不覆盖已有文件。

授权材料存在不代表有效，工具不破解或绕过授权、不验证完整代码签名。成功返回也只证明原生协议完成并查到了目标构建，**不能据此宣布 App Store 更新已恢复或应用数据已保留**。

## 设置和离线检查

使用 Python 3.12，在独立虚拟环境安装固定版本依赖：

```powershell
python -m venv .build/native-install-env
.build/native-install-env/Scripts/python.exe -m pip install -r iPadn-iOS/tools/native_install/requirements.txt
.build/native-install-env/Scripts/python.exe iPadn-iOS/tools/native_install/native_install_probe.py check-backend
.build/native-install-env/Scripts/python.exe -m unittest discover -s iPadn-iOS/tools/native_install -p 'test_*.py' -v
```

`inspect` 仅需 Python 标准库，不导入设备库、不接触设备：

```powershell
.build/native-install-env/Scripts/python.exe iPadn-iOS/tools/native_install/native_install_probe.py inspect 'test-app.ipa' --report '.build/ipa-audit.json'
```

测试使用的合成 IPA 没有可运行的签名程序，仅可用于离线测试，绝不安装到手机。

## 真机实验顺序

需先确认手机空闲、允许测试，并选定无既有用户数据的免费测试应用，排除支付宝。保持同一 IPA、授权账号、商店地区与系统版本；记录是否处于 LiveContainer 等额外运行环境中。

先记录只读安装状态，再调用原生安装。`--udid` 必须明确指定已信任的 USB 设备；本工具不自动弹出配对提示、不修改开发者模式和无线配对。

```powershell
.build/native-install-env/Scripts/python.exe iPadn-iOS/tools/native_install/native_install_probe.py lookup --udid '<device-id>' --bundle-id 'example.test.app'
.build/native-install-env/Scripts/python.exe iPadn-iOS/tools/native_install/native_install_probe.py install 'test-app.ipa' --udid '<device-id>' --expected-bundle-id 'example.test.app' --options-mode store
```

测试已有 App Store 版本时，先在专用测试应用中创建可核对的测试数据，然后显式调用升级，不能卸载：

```powershell
.build/native-install-env/Scripts/python.exe iPadn-iOS/tools/native_install/native_install_probe.py upgrade 'test-app.ipa' --udid '<device-id>' --expected-bundle-id 'example.test.app' --options-mode store
```

超时或中断时，安装可能仍在系统中继续。先观察手机和系统安装状态，再决定后续步骤，不能自动重试。若系统要求先卸载，本实验立即停止，保留现有应用与数据，并取系统安装日志诊断。

验收记录应分开填写：

1. App Store 搜索显示“打开”；有真实更新时能够执行更新。
2. 爱思等电脑软件的分类及账号关联，作为辅助指标。
3. App Store 原安装 → 原生 Upgrade 后，测试数据仍在，应用能启动。
4. 重启后状态仍然正常。

OTA 与原生协议的“全新安装”对照需要不同的干净测试状态。不能为了凑齐对照结果自动卸载测试应用；如需清理，先由用户确认专用测试应用及数据可丢弃。

## 后续手机端

当前原型是电脑端协议对照，尚未实现手机自主安装。只有上述验收通过后，才将同样的安装参数接入 `idevice` 的 C/Swift FFI，评估配对文件、本地 VPN、RSD 与当前 iOS 的兼容性。不会直接套用 SideStore 的个人开发证书重签名流程。

参考来源：

- [ideviceinstaller：元数据/SINF 参数和 Install/Upgrade](https://github.com/libimobiledevice/ideviceinstaller/blob/master/src/ideviceinstaller.c)
- [pymobiledevice3：原生安装服务](https://github.com/doronz88/pymobiledevice3/blob/master/pymobiledevice3/services/installation_proxy.py)（独立工具依赖，固定 11.50.3）
- [idevice：安装/升级助手](https://github.com/jkcoxson/idevice/blob/master/idevice/src/utils/installation/mod.rs)
- [idevice：C FFI](https://github.com/jkcoxson/idevice/blob/master/ffi/src/installation_proxy.rs)
- [SideStore：配对及本地 VPN 前提](https://docs.sidestore.io/docs/installation/prerequisites)
