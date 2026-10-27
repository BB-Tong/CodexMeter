#!/usr/bin/env python3
"""Offline regression test: repeated `updateChecker` anchors must not break integration."""
import subprocess
import sys
import tempfile
from pathlib import Path

here = Path(__file__).resolve().parent
with tempfile.TemporaryDirectory() as tmp:
    repo = Path(tmp)
    (repo / 'CodexMeter').mkdir()
    (repo / 'Config').mkdir()
    (repo / 'CodexMeter' / 'CodexMeterApp.swift').write_text('''import SwiftUI
struct CodexMeterApp: App {
    @StateObject private var updateChecker: UpdateChecker
    init() {
        _updateChecker = StateObject(wrappedValue: updateChecker)
    }
    var body: some Scene {
        MenuBarExtra {
            ContentView(
                service: usageService,
                settings: settings,
                history: history,
                updateChecker: updateChecker
            )
        }
        Window("CodexMeter", id: CodexMeterWindowID.about) {
            AboutView(
                settings: settings,
                history: history,
                updateChecker: updateChecker
            )
        }
    }
}
''')
    (repo / 'CodexMeter' / 'ContentView.swift').write_text('''import SwiftUI
struct ContentView: View {
    @ObservedObject var updateChecker: UpdateChecker
    private var scrollableContent: some View {
        VStack {
            Divider()

            if service.isLoading && service.windows.isEmpty {
                loadingView
            }
        }
    }
}
''')
    (repo / 'CodexMeter' / 'UpdateChecker.swift').write_text('''struct UpdateChecker {
    let updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: nil
    )
    var allowsAutomaticUpdates: Bool {
        updaterController.updater.allowsAutomaticUpdates
    }
    var canCheckForUpdates: Bool {
        updaterController.updater.canCheckForUpdates
    }
    func check(includePrereleases: Bool) {
        setIncludesPrereleases(includePrereleases)
        if isDeveloperPreview {
            clearDeveloperPreview()
        }
        state = .checking
        updaterController.checkForUpdates(nil)
    }
    func setAutomaticallyInstallsUpdates(_ enabled: Bool) {
        updaterController.updater.automaticallyDownloadsUpdates = enabled
        refreshPreferences()
    }
    func refreshPreferences() {
        automaticallyInstallsUpdates = updaterController.updater.automaticallyDownloadsUpdates
    }
}
''')
    (repo / 'Config' / 'CodexMeter-Info.plist').write_text('''<key>SUAllowsAutomaticUpdates</key>
	<true/>
<key>SUEnableAutomaticChecks</key>
	<true/>
''')

    def run():
        subprocess.run([sys.executable, str(here / 'apply_integration.py'), str(repo)], check=True, capture_output=True)

    run()
    first = {p.relative_to(repo): p.read_bytes() for p in repo.rglob('*') if p.is_file()}
    app = (repo / 'CodexMeter' / 'CodexMeterApp.swift').read_text()
    assert app.count('modeController: codexMode') == 1
    assert 'AboutView(\n                settings: settings,\n                history: history,\n                updateChecker: updateChecker\n            )' in app
    run()
    after = {p.relative_to(repo): p.read_bytes() for p in repo.rglob('*') if p.is_file()}
    assert after == first, 'Integration is not idempotent'
print('PASS: ambiguous anchor is handled; AboutView unchanged; second run is a no-op')
