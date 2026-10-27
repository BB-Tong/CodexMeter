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

    /// Installs templates only when the user explicitly requests it.
    /// Empty model IDs intentionally inherit the coordinator model.
    func installRoles(executionModel: String, reviewModel: String) {
        do {
            try RoleInstaller.install(homeURL: homeURL,
                                      executionModel: executionModel,
                                      reviewModel: reviewModel)
            refresh(force: true)
            explanation = "角色模板已写入；请检查模型 ID，重新开启 Codex 会话后使用。"
            error = nil
        } catch {
            self.error = "安装角色失败：\(error.localizedDescription)"
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

private enum RoleInstaller {
    static func install(homeURL: URL, executionModel: String, reviewModel: String) throws {
        let fm = FileManager.default
        let folder = homeURL.appendingPathComponent(".codex", isDirectory: true)
        let agents = folder.appendingPathComponent("agents", isDirectory: true)
        let config = folder.appendingPathComponent("config.toml")
        try fm.createDirectory(at: agents, withIntermediateDirectories: true)
        let existing: String
        if fm.fileExists(atPath: config.path) {
            existing = try String(contentsOf: config, encoding: .utf8)
        } else {
            existing = ""
        }
        let entries: [(String, String, String, String)] = [
            ("meter_executor", "CodexMeter: scoped UI/code implementation tasks",
             "Implement focused UI, CSS and well-scoped fixes. Test changes; report files and failures.", executionModel),
            ("meter_reviewer", "CodexMeter: architecture and complex-bug reviewer",
             "Investigate complex bugs and architecture. Review risks. Do not edit files unless asked.", reviewModel)
        ]
        var additions = ""
        var filesToCreate: [(URL, String)] = []
        for (name, description, instructions, model) in entries {
            let target = agents.appendingPathComponent(name + ".toml")
            // Never modify an existing role declaration or role file.
            if existing.contains("[agents.\(name)]") { continue }
            guard !target.path.contains("'") else {
                throw NSError(domain: "CodexMeter", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "配置路径包含不支持的单引号"])
            }
            let cleanModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
            guard cleanModel.isEmpty || cleanModel.range(of: "^[a-zA-Z0-9._-]+$", options: .regularExpression) != nil else {
                throw NSError(domain: "CodexMeter", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "模型 ID 包含无效字符"])
            }
            var role = "developer_instructions = \"\(instructions)\"\n"
            if !cleanModel.isEmpty { role += "model = \"\(cleanModel)\"\n" }
            if !fm.fileExists(atPath: target.path) {
                filesToCreate.append((target, role))
            }
            additions += "\n[agents.\(name)]\n"
            additions += "description = \"\(description)\"\n"
            additions += "config_file = '\(target.path)'\n"
        }
        guard !additions.isEmpty else { return }
        // Do not append tables into an unterminated TOML multiline string.
        for quote in ["\"\"\"", "'''"] {
            let count = existing.components(separatedBy: quote).count - 1
            guard count % 2 == 0 else {
                throw NSError(domain: "CodexMeter", code: 3,
                              userInfo: [NSLocalizedDescriptionKey: "检测到未闭合的多行 TOML 字符串"])
            }
        }
        let backup = folder.appendingPathComponent("config.toml.codexmeter-backup-\(Int(Date().timeIntervalSince1970))")
        if fm.fileExists(atPath: config.path) { try fm.copyItem(at: config, to: backup) }
        var createdFiles: [URL] = []
        do {
            for (path, text) in filesToCreate {
                try text.write(to: path, atomically: true, encoding: .utf8)
                createdFiles.append(path)
            }
            let current = (try? String(contentsOf: config, encoding: .utf8)) ?? ""
            guard current == existing else {
                throw NSError(domain: "CodexMeter", code: 4,
                              userInfo: [NSLocalizedDescriptionKey: "配置已被其他程序修改；没有覆盖它"])
            }
            let permissions = (try? fm.attributesOfItem(atPath: config.path))?[.posixPermissions]
            let updated = existing + (existing.hasSuffix("\n") ? "" : "\n") + additions
            try updated.write(to: config, atomically: true, encoding: .utf8)
            if let permissions {
                try fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: config.path)
            } else {
                try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: config.path)
            }
        } catch {
            for file in createdFiles { try? fm.removeItem(at: file) }
            throw error
        }
    }
}
