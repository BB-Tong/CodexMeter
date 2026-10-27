import SwiftUI

/// Integrated with CodexMeter's existing menu bar window (no second status icon).
struct CodexModeSection: View {
    @ObservedObject var controller: CodexModeController
    @ObservedObject var service: CodexUsageService
    @State private var executorModel = ""
    @State private var reviewerModel = ""
    @State private var showRoles = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Codex 工作模式", systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if controller.isSwitching { ProgressView().controlSize(.small) }
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
                    Text("从本机 Codex 模型目录选择；『继承主模型』不指定独立模型。目录中的模型不一定拥有实际调用权限。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if let readError = controller.roleReadError {
                        Label("读取已有角色失败：\(readError)", systemImage: "exclamationmark.triangle")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                    modelSelector("轻量执行 Agent", selection: $executorModel)
                    modelSelector("复杂审查 Agent", selection: $reviewerModel)
                    HStack {
                        if service.modelCatalogLoading {
                            ProgressView().controlSize(.small)
                            Text("正在读取模型…").font(.caption2).foregroundStyle(.secondary)
                        } else {
                            Text("可选模型：\(service.modelCatalogModels.count)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("重新读取模型") { service.reloadModelCatalog() }
                            .font(.caption2)
                            .buttonStyle(.plain)
                            .disabled(service.modelCatalogLoading)
                    }
                    if let error = service.modelCatalogError {
                        Text(error).font(.caption2).foregroundStyle(.orange)
                    }
                    HStack {
                        Button("保存 Agent 配置") {
                            controller.saveRoleModels(
                                .init(executor: executorModel, reviewer: reviewerModel),
                                availableModels: service.modelCatalogModels
                            )
                            // On failure, retain the unsaved picks so they can be corrected.
                            if controller.error == nil { reloadSelection() }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(controller.isSavingRoles || controller.roleReadError != nil || service.modelCatalogLoading)
                        Spacer()
                        Button("打开配置目录") { controller.openConfig() }
                            .buttonStyle(.plain)
                    }
                }
                .padding(.top, 6)
            }
            .font(.caption)
        }
        .onAppear {
            controller.refresh(force: true)
            reloadSelection()
            if service.modelCatalogModels.isEmpty && !service.modelCatalogLoading {
                service.reloadModelCatalog()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func reloadSelection() {
        controller.refreshRoleSelection()
        executorModel = controller.roleSelection.executor
        reviewerModel = controller.roleSelection.reviewer
    }

    private func modelSelector(_ label: String, selection: Binding<String>) -> some View {
        Picker(label, selection: selection) {
            Text("继承主模型（留空）").tag("")
            if !selection.wrappedValue.isEmpty &&
               !service.modelCatalogModels.contains(where: { $0.id == selection.wrappedValue }) {
                Text("当前已配置：\(selection.wrappedValue)（不在目录）")
                    .tag(selection.wrappedValue)
            }
            ForEach(service.modelCatalogModels) { model in
                Text("\(model.displayName) · \(model.id)").tag(model.id)
            }
        }
        .pickerStyle(.menu)
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
