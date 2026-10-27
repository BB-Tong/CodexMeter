import AppKit
import Combine
import Darwin
import Foundation

/// Global Codex delegation switch. This is not a live per-thread model switch.
enum CodexDelegationMode: String, Equatable {
    case automatic
    case manual
    case unknown
}

struct CodexConfigSnapshot: Equatable {
    let mode: CodexDelegationMode
    let explanation: String

    static func read(_ text: String) -> CodexConfigSnapshot {
        var table = ""
        var feature: Bool?
        var agents: Bool?
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("[") && line.hasSuffix("]") {
                table = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                continue
            }
            let fields = line.split(separator: "=", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard fields.count == 2 else { continue }
            let value = fields[1].split(separator: "#", maxSplits: 1)
                .first?.trimmingCharacters(in: .whitespaces) ?? ""
            let parsed: Bool?
            switch value {
            case "true": parsed = true
            case "false": parsed = false
            default: parsed = nil
            }
            if (table == "features" && fields[0] == "multi_agent") ||
                (table.isEmpty && fields[0] == "features.multi_agent") { feature = parsed }
            if (table == "agents" && fields[0] == "enabled") ||
                (table.isEmpty && fields[0] == "agents.enabled") { agents = parsed }
        }
        // As documented in the Codex configuration reference, both settings default on.
        // A project-level config or a command-line override can still change effective behavior.
        if feature == false || agents == false {
            return .init(mode: .manual, explanation: "全局配置已关闭子 Agent 委派")
        }
        if feature == true || agents == true {
            return .init(mode: .automatic, explanation: "全局配置允许子 Agent；仅对新会话可靠生效")
        }
        return .init(mode: .automatic, explanation: "Codex 默认允许多 Agent（尚未明确配置）")
    }
}

@MainActor
final class CodexModeController: ObservableObject {
    @Published private(set) var mode: CodexDelegationMode = .unknown
    @Published private(set) var explanation = "尚未读取 Codex 配置"
    @Published private(set) var error: String?
    @Published private(set) var isSwitching = false
    @Published private(set) var roleSelection = CodexRoleSelection()
    @Published private(set) var roleReadError: String?
    @Published private(set) var isSavingRoles = false

    private let homeURL: URL
    private let configURL: URL
    private var configObserver: DispatchSourceFileSystemObject?
    private var debounceWork: DispatchWorkItem?
    private var pollTimer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var lastSnapshot: Data?

    init(homeURL: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.homeURL = homeURL
        self.configURL = homeURL.appendingPathComponent(".codex/config.toml")
        refresh(force: true)
        refreshRoleSelection()
        observeDirectory()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.observeDirectory()
                self?.refresh()
            }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.observeDirectory()
                self?.refresh(force: true)
            }
        }
    }

    deinit {
        pollTimer?.invalidate()
        debounceWork?.cancel()
        configObserver?.cancel()
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
    }

    func refresh(force: Bool = false) {
        let data: Data
        do {
            data = try Data(contentsOf: configURL)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            lastSnapshot = nil
            mode = .automatic
            explanation = "未找到全局 config.toml；使用 Codex 内置默认值"
            return
        } catch {
            mode = .unknown
            explanation = "无法读取 Codex 配置，请检查文件权限"
            return
        }
        guard force || lastSnapshot != data else { return }
        lastSnapshot = data
        guard let content = String(data: data, encoding: .utf8) else {
            mode = .unknown
            explanation = "配置不是 UTF-8 文本"
            return
        }
        let status = CodexConfigSnapshot.read(content)
        mode = status.mode
        explanation = status.explanation
    }

    func switchTo(_ target: CodexDelegationMode) {
        guard target != .unknown, !isSwitching else { return }
        guard let codexURL = CodexExecutableLocator.locate(homeDirectory: homeURL) else {
            error = "未找到 Codex CLI，请先安装 CLI 或检查其安装位置。"
            return
        }
        isSwitching = true
        error = nil
        let homeURL = self.homeURL
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let outcome = Self.executeCLI(codexURL: codexURL,
                                          homeURL: homeURL,
                                          mode: target)
            DispatchQueue.main.async {
                guard let self else { return }
                self.isSwitching = false
                self.refresh(force: true)
                if let outcome {
                    self.error = outcome
                } else if self.mode != target {
                    self.error = "功能开关已经写入，但其他全局设置可能覆盖了它（例如 agents.enabled=false）。"
                } else {
                    self.explanation = "全局默认模式已保存；请新建 Codex 会话或重启客户端。"
                }
                self.observeDirectory()
            }
        }
    }

    func openConfig() {
        NSWorkspace.shared.open(configURL.deletingLastPathComponent())
    }

    /// Read the existing model values without modifying role descriptions or MCP settings.
    func refreshRoleSelection() {
        do {
            roleSelection = try CodexRoleConfiguration.read(homeURL: homeURL)
            roleReadError = nil
        } catch {
            roleReadError = error.localizedDescription
        }
    }

    func saveRoleModels(_ selection: CodexRoleSelection, availableModels: [CodexAvailableModel]) {
        guard !isSavingRoles else { return }
        isSavingRoles = true
        error = nil
        defer { isSavingRoles = false }
        do {
            let backup = try CodexRoleConfiguration.save(
                homeURL: homeURL, selection: selection,
                availableIDs: Set(availableModels.map(\.id))
            )
            refreshRoleSelection()
            explanation = backup == nil
                ? "模型配置无需修改，已是最新值。"
                : "Agent 配置已保存并备份；请新建 Codex 会话。"
            if let backup { print("CodexMeter role backup created: \(backup.lastPathComponent)") }
        } catch {
            self.error = "保存 Agent 配置失败：\(error.localizedDescription)"
        }
    }

    private func observeDirectory() {
        guard configObserver == nil else { return }
        let directory = configURL.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        let fd = Darwin.open(directory.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: DispatchQueue.main
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.debounceWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.refresh(force: true)
                self?.refreshRoleSelection()
            }
            self.debounceWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(400), execute: work)
            if source.data.contains(.delete) || source.data.contains(.rename) {
                source.cancel()
                self.configObserver = nil
            }
        }
        source.setCancelHandler { Darwin.close(fd) }
        configObserver = source
        source.resume()
    }

    private nonisolated static func executeCLI(codexURL: URL, homeURL: URL,
                                               mode: CodexDelegationMode) -> String? {
        let process = Process()
        process.executableURL = codexURL
        process.arguments = ["features", mode == .automatic ? "enable" : "disable", "multi_agent"]
        var environment = ProcessInfo.processInfo.environment
        let paths = [codexURL.deletingLastPathComponent().path,
                     homeURL.appendingPathComponent(".local/bin").path,
                     "/opt/homebrew/bin", "/usr/local/bin",
                     environment["PATH"] ?? ""]
        environment["PATH"] = paths.joined(separator: ":")
        process.environment = environment
        let out = Pipe()
        process.standardOutput = out
        process.standardError = out
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                return "Codex CLI 无法切换 multi_agent（退出码 \(process.terminationStatus)）。请检查 CLI 版本。"
            }
            return nil
        } catch {
            return "无法执行 Codex CLI：\(error.localizedDescription)"
        }
    }
}
