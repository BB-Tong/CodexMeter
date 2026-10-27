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
        "            CodexModeSection(controller: modeController)\n"
        "            Divider()\n\n            if service.isLoading && service.windows.isEmpty {",
        "CodexModeSection(controller: modeController)"
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

    for name in ("CodexModeController.swift", "CodexModeSection.swift"):
        source = HERE / "patch" / name
        target = repo / "CodexMeter" / name
        if target.exists() and target.read_bytes() != source.read_bytes():
            raise RuntimeError(f"Won't overwrite existing file: {target}")
        shutil.copyfile(source, target)
    print("Integration applied. Existing quota monitoring code unchanged.")


if __name__ == "__main__":
    main()
