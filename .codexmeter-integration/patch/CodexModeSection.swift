import SwiftUI

/// Part of CodexMeter's existing menu-bar popover, not a second menu-bar icon.
struct CodexModeSection: View {
    @ObservedObject var controller: CodexModeController
    @State private var executorModel = ""
    @State private var reviewerModel = ""
    @State private var showRoles = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Codex 工作模式", systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if controller.isSwitching {
                    ProgressView().controlSize(.small)
                }
            }
            HStack(spacing: 8) {
                modeButton(.automatic, title: "自动分工", symbol: "arrow.triangle.branch")
                modeButton(.manual, title: "手动选择", symbol: "slider.horizontal.3")
            }
            Text(controller.explanation)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let error = controller.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            DisclosureGroup("子 Agent 模型与角色配置", isExpanded: $showRoles) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("填写当前 Codex 账号实际支持的模型 ID；留空则继承主模型。首次安装不会覆盖已有角色。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    TextField("轻量执行模型 ID（可留空）", text: $executorModel)
                        .textFieldStyle(.roundedBorder)
                    TextField("复杂审查模型 ID（可留空）", text: $reviewerModel)
                        .textFieldStyle(.roundedBorder)
                    HStack {
                        Button("安装角色模板") {
                            controller.installRoles(executionModel: executorModel,
                                                    reviewModel: reviewerModel)
                        }
                        .buttonStyle(.bordered)
                        Spacer()
                        Button("打开配置目录") { controller.openConfig() }
                            .buttonStyle(.plain)
                    }
                }
                .padding(.top, 6)
            }
            .font(.caption)
        }
        .onAppear { controller.refresh(force: true) }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func modeButton(_ mode: CodexDelegationMode,
                            title: String, symbol: String) -> some View {
        Button {
            controller.switchTo(mode)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: controller.mode == mode ? "checkmark.circle.fill" : symbol)
                Text(title).lineLimit(1)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .disabled(controller.isSwitching)
    }
}
