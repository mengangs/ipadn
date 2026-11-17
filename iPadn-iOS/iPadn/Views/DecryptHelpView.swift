import SwiftUI

struct DecryptHelpView: View {
    var body: some View {
        List {
            Section("开始使用") {
                topic("如何导入和解密 IPA", text: "在应用包右上角选择「导入」。文件添加完成后，打开原始 IPA 查看加密状态，再发起解密。也可以从已完成下载的更多菜单进入。原始文件保留，产物单独生成。")
                topic("原始包与解密产物有什么区别", text: "原始 IPA 是处理来源，可能已加密，也可能本来就未加密。解密完成不会改变原始文件的加密状态。只有通过产物校验的结果才标记为解密完成；未加密不等于曾由 iPadn 解密。")
                topic("如何保存和分享", text: "在结果页选择「保存到文件」指定位置，或使用「分享 IPA」交给其他 App。导出的是副本。重新解密可能替换 iPadn 内的同源产物，请先保存需要保留的版本。")
            }

            Section("遇到问题") {
                topic("系统拒绝了解密请求", text: "EPERM 只表示系统拒绝了请求，不能单凭它确认具体原因。可以核对下载该应用所用的账号，以及系统 App Store 中的授权。账号不匹配或家庭共享等是可能原因，不代表一定如此，也不保证重新登录就能解决。")
                topic("授权文件不完整", text: "解密需要完整的 IPA 和匹配的授权文件。请尝试重新下载完整安装包。不要移除或手动替换包内的授权信息。")
                topic("部分成功或校验未通过", text: "部分成功意味着仍有内容未完成解密。即使已经生成 IPA，也不能视为完整可用的产物。校验未通过可能是加密残留或读取等问题，应结合已有技术详情判断。校验通过也不保证可以直接安装运行。")
                topic("任务取消或被中断", text: "取消需要等待当前操作的安全检查点；打包和校验阶段需要等待完成。退出页面不会取消任务。应用被关闭后任务无法续传，重新打开时会标记为被中断，可从原始 IPA 重新开始。")
                topic("自动解密没有开始", text: "自动解密仅在专业模式开启时生效，一次只处理一份 IPA。已有同源产物或另一任务正在运行时不会自动开始，不会排队、自动重试或覆盖文件。可以稍后从原始 IPA 手动发起。")
                topic("技术日志与隐私", text: "技术日志只保留当前任务最近 400 行，历史记录保留摘要及已有错误详情。显示、复制和导出前会脱敏账号、凭据、令牌及 Cookie。导出的日志可能仍包含应用名称和二进制路径，分享前可以自行查看内容。")
            }

            Section("兼容性与边界") {
                topic("当前运行条件", text: "需要完整的 IPA、匹配的 SINF 授权文件、具备可用 App Group 权限的 iPadn 签名，以及系统认可的应用授权。请仅处理你合法拥有并有权使用的应用。")
                topic("尚未验证的场景", text: "其他机型与 iPad、其他系统版本、全部 App Store 应用、家庭共享、多账号与跨账号、退出系统账号后的长期授权、恢复设备、换机及升级系统后的行为，均不能依据已有样本作出保证。")
            }
        }
        .toolPage()
        .navigationTitle("使用说明")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func topic(_ title: LocalizedStringKey, text: LocalizedStringKey) -> some View {
        DisclosureGroup {
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .padding(.vertical, 4)
        } label: {
            Text(title).font(.body)
        }
    }
}
