#!/usr/bin/env python3
"""Insert Codex mode controls into a checkout of raycalrui/CodexMeter.

Fails closed on unexpected upstream source changes. No git configuration required.
"""
from pathlib import Path
import argparse
import shutil
import sys

HERE = Path(__file__).resolve().parent.parent


def replace_once(path: Path, old: str, new: str, marker: str) -> None:
    src = path.read_text(encoding="utf-8")
    if marker in src:
        return
    count = src.count(old)
    if count != 1:
        raise RuntimeError(f"Refusing to modify {path}: expected anchor once, saw {count}")
    path.write_text(src.replace(old, new, 1), encoding="utf-8")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("repo", help="Local CodexMeter checkout")
    args = parser.parse_args()
    repo = Path(args.repo).expanduser().resolve()
    app = repo / "CodexMeter" / "CodexMeterApp.swift"
    content = repo / "CodexMeter" / "ContentView.swift"
    if not app.exists() or not content.exists():
        sys.exit("Not a CodexMeter source checkout")

    # Guard against partially-applied incompatible updates.
    if not all(x in app.read_text() for x in ["struct CodexMeterApp: App", "MenuBarExtra {"]):
        sys.exit("Unsupported CodexMeterApp.swift layout")
    if not all(x in content.read_text() for x in ["struct ContentView: View", "private var scrollableContent"]):
        sys.exit("Unsupported ContentView.swift layout")

    replace_once(
        app,
        "    @StateObject private var updateChecker: UpdateChecker\n",
        "    @StateObject private var updateChecker: UpdateChecker\n"
        "    @StateObject private var codexMode: CodexModeController\n",
        "@StateObject private var codexMode: CodexModeController"
    )
    replace_once(
        app,
        "        _updateChecker = StateObject(wrappedValue: updateChecker)\n",
        "        _updateChecker = StateObject(wrappedValue: updateChecker)\n"
        "        _codexMode = StateObject(wrappedValue: CodexModeController())\n",
        "_codexMode = StateObject(wrappedValue: CodexModeController())"
    )
    # `updateChecker: updateChecker` also appears in the About window setup.
    # Scope the replacement to the ContentView call so it stays unambiguous.
    replace_once(
        app,
        "            ContentView(\n"
        "                service: usageService,\n"
        "                settings: settings,\n"
        "                history: history,\n"
        "                updateChecker: updateChecker\n"
        "            )\n",
        "            ContentView(\n"
        "                service: usageService,\n"
        "                settings: settings,\n"
        "                history: history,\n"
        "                updateChecker: updateChecker,\n"
        "                modeController: codexMode\n"
        "            )\n",
        "modeController: codexMode"
    )
    replace_once(
        content,
        "    @ObservedObject var updateChecker: UpdateChecker\n",
        "    @ObservedObject var updateChecker: UpdateChecker\n"
        "    @ObservedObject var modeController: CodexModeController\n",
        "@ObservedObject var modeController: CodexModeController"
    )
    replace_once(
        content,
        "            Divider()\n\n            if service.isLoading && service.windows.isEmpty {",
        "            CodexModeSection(controller: modeController, service: service)\n"
        "            Divider()\n\n            if service.isLoading && service.windows.isEmpty {",
        "CodexModeSection(controller: modeController, service: service)"
    )

    usage = repo / "CodexMeter" / "CodexUsageService.swift"
    replace_once(usage, "        case usage\n    }", "        case usage\n        case modelList\n    }", "case modelList")
    replace_once(
        usage,
        "    @Published private(set) var rateLimitResetCredits: CodexRateLimitResetCreditsSummary?\n",
        "    @Published private(set) var rateLimitResetCredits: CodexRateLimitResetCreditsSummary?\n"
        "    @Published private(set) var modelCatalogModels: [CodexAvailableModel] = []\n"
        "    @Published private(set) var modelCatalogLoading = false\n"
        "    @Published private(set) var modelCatalogError: String?\n",
        "@Published private(set) var modelCatalogModels:"
    )
    replace_once(
        usage,
        "    private var usageRequestID: Int?\n",
        "    private var usageRequestID: Int?\n"
        "    private var modelRequestID: Int?\n"
        "    private var modelCatalogTimeout: DispatchWorkItem?\n"
        "    private var modelPageCount = 0\n"
        "    private var collectedModels: [CodexAvailableModel] = []\n",
        "private var modelCatalogTimeout:"
    )
    replace_once(
        usage,
        "    private func clearAppServerResources(terminate: Bool = false) {\n",
        "    private func clearAppServerResources(terminate: Bool = false) {\n"
        "        modelCatalogTimeout?.cancel()\n"
        "        modelCatalogTimeout = nil\n"
        "        modelRequestID = nil\n"
        "        modelCatalogLoading = false\n",
        "        modelCatalogTimeout?.cancel()\n        modelCatalogTimeout = nil\n"
    )
    replace_once(
        usage,
        "        if let error = message[\"error\"] as? [String: Any] {\n",
        "        if let error = message[\"error\"] as? [String: Any] {\n"
        "            if kind == .modelList {\n"
        "                finishModelCatalogError(\"Codex 返回了模型目录错误，请刷新重试\")\n"
        "                return\n"
        "            }\n",
        "if kind == .modelList"
    )
    replace_once(
        usage,
        "            case .account:\n                break\n            }\n            return\n        }",
        "            case .account:\n                break\n"
        "            case .modelList:\n"
        "                finishModelCatalogError(\"Codex 模型目录响应无效\")\n"
        "            }\n            return\n        }",
        "finishModelCatalogError(\"Codex 模型目录响应无效\")"
    )
    replace_once(
        usage,
        "        case .usage:\n            parseTokenUsage(result)\n        }",
        "        case .usage:\n            parseTokenUsage(result)\n"
        "        case .modelList:\n            receiveModelPage(result)\n        }",
        "case .modelList:\n            receiveModelPage(result)"
    )
    replace_once(
        usage,
        "            _ = send([\"method\": \"initialized\", \"params\": [:]])\n            refresh()\n",
        "            _ = send([\"method\": \"initialized\", \"params\": [:]])\n"
        "            refresh()\n            reloadModelCatalog()\n",
        "            reloadModelCatalog()"
    )
    replace_once(
        usage,
        "    private func handleAccountUpdated() {\n",
        '    // This catalog comes from the same authenticated Codex App Server used for quotas.\n    // It does not spend inference tokens or prove that a model is entitled for execution.\n    func reloadModelCatalog() {\n        guard didInitialize else {\n            modelCatalogError = "等待 Codex 服务连接后读取模型"\n            return\n        }\n        guard modelRequestID == nil else { return }\n        modelCatalogLoading = true\n        modelCatalogError = nil\n        collectedModels = []\n        modelPageCount = 0\n        requestModelPage(cursor: nil)\n    }\n\n    private func requestModelPage(cursor: String?) {\n        var params: [String: Any] = ["limit": 100, "includeHidden": false]\n        if let cursor { params["cursor"] = cursor }\n        guard let requestID = sendRequest(method: "model/list", params: params, kind: .modelList) else {\n            finishModelCatalogError("Codex 模型目录请求失败")\n            return\n        }\n        modelRequestID = requestID\n        modelPageCount += 1\n        let timeout = DispatchWorkItem { [weak self] in\n            guard let self, self.modelRequestID == requestID else { return }\n            self.pendingRequests.removeValue(forKey: requestID)\n            self.finishModelCatalogError("读取模型列表超时；请重试")\n        }\n        modelCatalogTimeout?.cancel()\n        modelCatalogTimeout = timeout\n        DispatchQueue.main.asyncAfter(deadline: .now() + 12, execute: timeout)\n    }\n\n    private func receiveModelPage(_ result: [String: Any]) {\n        modelCatalogTimeout?.cancel()\n        modelCatalogTimeout = nil\n        modelRequestID = nil\n        do {\n            let entries = try CodexAvailableModel.decodePage(result)\n            for entry in entries where !collectedModels.contains(where: { $0.id == entry.id }) {\n                collectedModels.append(entry)\n            }\n            if let next = result["nextCursor"] as? String, !next.isEmpty {\n                guard modelPageCount < 8 else {\n                    finishModelCatalogError("模型目录分页过多，请检查 Codex 版本")\n                    return\n                }\n                requestModelPage(cursor: next)\n            } else {\n                modelCatalogLoading = false\n                modelCatalogModels = collectedModels\n                if collectedModels.isEmpty {\n                    modelCatalogError = "没有获取到可供选择的模型，请确认 Codex 登录状态"\n                }\n            }\n        } catch {\n            finishModelCatalogError(error.localizedDescription)\n        }\n    }\n\n    private func finishModelCatalogError(_ message: String) {\n        modelCatalogTimeout?.cancel()\n        modelCatalogTimeout = nil\n        modelRequestID = nil\n        modelCatalogLoading = false\n        modelCatalogError = message\n    }\n\n' + "    private func handleAccountUpdated() {\n",
        "private func receiveModelPage("
    )
    replace_once(
        usage,
        "        // App Server has already applied the auth change. Force its managed ChatGPT\n",
        "        // A changed account may expose a different model catalog.\n"
        "        modelCatalogTimeout?.cancel()\n"
        "        modelRequestID = nil\n"
        "        modelCatalogLoading = false\n"
        "        reloadModelCatalog()\n"
        "        // App Server has already applied the auth change. Force its managed ChatGPT\n",
        "A changed account may expose"
    )

    # A custom fork must never silently install upstream Sparkle updates that
    # would erase the integrated mode switcher.
    updater = repo / "CodexMeter" / "UpdateChecker.swift"
    info = repo / "Config" / "CodexMeter-Info.plist"
    replace_once(
        updater,
        "            startingUpdater: true,",
        "            startingUpdater: false,",
        "            startingUpdater: false,"
    )
    replace_once(
        updater,
        "    var allowsAutomaticUpdates: Bool {\n        updaterController.updater.allowsAutomaticUpdates\n    }",
        "    var allowsAutomaticUpdates: Bool { false }",
        "    var allowsAutomaticUpdates: Bool { false }"
    )
    replace_once(
        updater,
        "    var canCheckForUpdates: Bool {\n        updaterController.updater.canCheckForUpdates\n    }",
        "    var canCheckForUpdates: Bool { false }",
        "    var canCheckForUpdates: Bool { false }"
    )
    replace_once(
        updater,
        "    func check(includePrereleases: Bool) {\n"
        "        setIncludesPrereleases(includePrereleases)\n"
        "        if isDeveloperPreview {\n"
        "            clearDeveloperPreview()\n"
        "        }\n"
        "        state = .checking\n"
        "        updaterController.checkForUpdates(nil)\n"
        "    }",
        "    func check(includePrereleases: Bool) {\n"
        "        state = .failed(\"自定义构建已关闭上游应用更新，避免覆盖模式切换功能。\")\n"
        "    }",
        "自定义构建已关闭上游应用更新"
    )
    replace_once(
        updater,
        "    func setAutomaticallyInstallsUpdates(_ enabled: Bool) {\n        updaterController.updater.automaticallyDownloadsUpdates = enabled\n        refreshPreferences()\n    }",
        "    func setAutomaticallyInstallsUpdates(_ enabled: Bool) {\n        automaticallyInstallsUpdates = false\n    }",
        "    func setAutomaticallyInstallsUpdates(_ enabled: Bool) {\n        automaticallyInstallsUpdates = false"
    )
    replace_once(
        updater,
        "    func refreshPreferences() {\n"
        "        automaticallyInstallsUpdates = updaterController.updater.automaticallyDownloadsUpdates\n"
        "    }",
        "    func refreshPreferences() {\n"
        "        automaticallyInstallsUpdates = false\n"
        "    }",
        "    func refreshPreferences() {\n        automaticallyInstallsUpdates = false"
    )
    replace_once(
        info,
        "<key>SUAllowsAutomaticUpdates</key>\n\t<true/>",
        "<key>SUAllowsAutomaticUpdates</key>\n\t<false/>",
        "<key>SUAllowsAutomaticUpdates</key>\n\t<false/>"
    )
    replace_once(
        info,
        "<key>SUEnableAutomaticChecks</key>\n\t<true/>",
        "<key>SUEnableAutomaticChecks</key>\n\t<false/>",
        "<key>SUEnableAutomaticChecks</key>\n\t<false/>"
    )

    for name in ("CodexModeController.swift", "CodexModeSection.swift", "CodexRoleConfiguration.swift"):
        source = HERE / "patch" / name
        target = (repo / "CodexMeter" / "Core" / name) if name == "CodexRoleConfiguration.swift" else (repo / "CodexMeter" / name)
        target.parent.mkdir(parents=True, exist_ok=True)
        if target.exists() and target.read_bytes() != source.read_bytes():
            raise RuntimeError(f"Won't overwrite existing file: {target}")
        shutil.copyfile(source, target)
    test_source = HERE / "tests" / "CodexRoleConfigurationTests.swift"
    test_target = repo / "Tests" / "CodexMeterCoreTests" / "CodexRoleConfigurationTests.swift"
    test_target.parent.mkdir(parents=True, exist_ok=True)
    if test_target.exists() and test_target.read_bytes() != test_source.read_bytes():
        raise RuntimeError(f"Won't overwrite existing tests: {test_target}")
    shutil.copyfile(test_source, test_target)

    print("Integration applied. Existing quota monitoring code unchanged.")


if __name__ == "__main__":
    main()
