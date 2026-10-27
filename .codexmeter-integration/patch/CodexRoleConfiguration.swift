import Foundation

/// A picker entry from Codex App Server's model/list response. Listing is not proof of entitlement.
struct CodexAvailableModel: Identifiable, Equatable {
    let id: String
    let displayName: String

    static func decodePage(_ result: [String: Any]) throws -> [CodexAvailableModel] {
        guard let data = result["data"] as? [[String: Any]] else {
            throw CodexRoleError("Codex 未返回有效的模型目录")
        }
        var seen = Set<String>()
        return data.compactMap { item in
            guard item["hidden"] as? Bool != true,
                  let id = (item["model"] as? String) ?? (item["id"] as? String),
                  validModelID(id), seen.insert(id).inserted else { return nil }
            return CodexAvailableModel(id: id, displayName: (item["displayName"] as? String) ?? id)
        }
    }
}

struct CodexRoleSelection: Equatable {
    var executor = ""
    var reviewer = ""
}

struct CodexRoleError: LocalizedError {
    let reason: String
    init(_ reason: String) { self.reason = reason }
    var errorDescription: String? { reason }
}

private func validModelID(_ value: String) -> Bool {
    !value.isEmpty && value.range(of: #"^[a-zA-Z0-9._-]+$"#, options: .regularExpression) != nil
}

/// Edits only the root-level `model` key in role TOML files. Other keys, sections,
/// descriptions, instructions and MCP configuration are retained verbatim.
enum CodexRoleConfiguration {
    private struct Role {
        let name: String
        let description: String
        let instructions: String
        let model: String
    }

    static func read(homeURL: URL) throws -> CodexRoleSelection {
        let configRoot = homeURL.appendingPathComponent(".codex", isDirectory: true)
        let rootText = try readFile(configRoot.appendingPathComponent("config.toml"))
        let roles = definitions(executor: "", reviewer: "")
        var result = CodexRoleSelection()
        for role in roles {
            let path = try rolePath(role.name, rootText: rootText, root: configRoot)
            let text = try readFile(path)
            let model = try modelValue(from: text)
            if role.name == "meter_executor" { result.executor = model }
            else { result.reviewer = model }
        }
        return result
    }

    /// Only IDs enumerated by the local Codex model catalog can be set. Empty is always valid.
    /// On success returns a private on-disk backup folder (nil means no changes).
    @discardableResult
    static func save(homeURL: URL, selection: CodexRoleSelection,
                     availableIDs: Set<String>) throws -> URL? {
        for id in [selection.executor, selection.reviewer] where !id.isEmpty {
            guard validModelID(id), availableIDs.contains(id) else {
                throw CodexRoleError("模型 \(id) 不在当前 Codex 模型目录中。请刷新列表或选择『继承主模型』。")
            }
        }
        let fm = FileManager.default
        let root = homeURL.appendingPathComponent(".codex", isDirectory: true)
        let agents = root.appendingPathComponent("agents", isDirectory: true)
        let config = root.appendingPathComponent("config.toml")
        let originalRoot = try readFile(config)
        try checkSafeText(originalRoot)
        var updatedRoot = originalRoot
        var changes: [(path: URL, old: Data?, new: Data)] = []
        for role in definitions(executor: selection.executor, reviewer: selection.reviewer) {
            // Never modify descriptions or existing role registrations. Add only absent registrations.
            if updatedRoot.split(separator: "\n").filter({
                $0.trimmingCharacters(in: .whitespacesAndNewlines) == "[agents.\(role.name)]"
            }).count > 1 { throw CodexRoleError("\(role.name) 存在重复注册段") }
            if sectionRange(role.name, in: updatedRoot) == nil {
                let path = agents.appendingPathComponent(role.name + ".toml")
                guard !path.path.contains("'") else { throw CodexRoleError("角色配置路径包含不支持的引号") }
                updatedRoot += (updatedRoot.isEmpty || updatedRoot.hasSuffix("\n") ? "" : "\n")
                    + "\n[agents.\(role.name)]\n"
                    + "description = \"\(role.description)\"\n"
                    + "config_file = '\(path.path)'\n"
            }
            let path = try rolePath(role.name, rootText: updatedRoot, root: root)
            let original = try readFile(path)
            try checkSafeText(original)
            let content = try setRootModel(in: original, to: role.model,
                                           instructions: role.instructions)
            if original != content || !fm.fileExists(atPath: path.path) {
                changes.append((path, fm.fileExists(atPath: path.path) ? Data(original.utf8) : nil,
                                Data(content.utf8)))
            }
        }
        if updatedRoot != originalRoot {
            changes.insert((config, fm.fileExists(atPath: config.path) ? Data(originalRoot.utf8) : nil,
                            Data(updatedRoot.utf8)), at: 0)
        }
        guard !changes.isEmpty else { return nil }
        let backup = root.appendingPathComponent("codexmeter-backups", isDirectory: true)
            .appendingPathComponent("roles-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: backup, withIntermediateDirectories: true)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: backup.path)
        // Retain a backup copy of every existing file before changing any file.
        for (index, change) in changes.enumerated() {
            if let original = change.old {
                let backupFile = backup.appendingPathComponent("\(index)-\(change.path.lastPathComponent)")
                try original.write(to: backupFile, options: .atomic)
                try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backupFile.path)
            }
        }
        var applied: [(path: URL, old: Data?, permissions: Any?)] = []
        do {
            for change in changes {
                let existing = fm.fileExists(atPath: change.path.path)
                guard existing == (change.old != nil) else {
                    throw CodexRoleError("配置文件已被其他程序修改，保存已取消")
                }
                if existing {
                    let current = try Data(contentsOf: change.path)
                    guard current == change.old else {
                        throw CodexRoleError("配置文件已被其他程序修改，保存已取消")
                    }
                }
                try fm.createDirectory(at: change.path.deletingLastPathComponent(), withIntermediateDirectories: true)
                let attributes = existing ? try fm.attributesOfItem(atPath: change.path.path) : [:]
                // Register this write before attempting it, in case a partial write fails.
                applied.append((change.path, change.old, attributes[.posixPermissions]))
                try change.new.write(to: change.path, options: .atomic)
                try fm.setAttributes([.posixPermissions: attributes[.posixPermissions] ?? NSNumber(value: 0o600)],
                                     ofItemAtPath: change.path.path)
            }
            // Verify the exact stored selection rather than assuming a write succeeded.
            guard try read(homeURL: homeURL) == selection else {
                throw CodexRoleError("写入校验失败，已尝试恢复原配置")
            }
            return backup
        } catch {
            var rollbackFailures: [String] = []
            for item in applied.reversed() {
                do {
                    if let old = item.old {
                        try old.write(to: item.path, options: .atomic)
                        try fm.setAttributes([.posixPermissions: item.permissions ?? NSNumber(value: 0o600)],
                                             ofItemAtPath: item.path.path)
                    } else if fm.fileExists(atPath: item.path.path) { try fm.removeItem(at: item.path) }
                } catch { rollbackFailures.append(item.path.lastPathComponent) }
            }
            if !rollbackFailures.isEmpty {
                throw CodexRoleError("保存失败且部分文件恢复失败：\(rollbackFailures.joined(separator: ", "))；备份位置：\(backup.path)")
            }
            throw error
        }
    }

    private static func definitions(executor: String, reviewer: String) -> [Role] {
        [Role(name: "meter_executor", description: "CodexMeter: scoped UI/code implementation tasks",
              instructions: "Implement focused UI, CSS and well-scoped fixes. Test changes; report files and failures.",
              model: executor),
         Role(name: "meter_reviewer", description: "CodexMeter: architecture and complex-bug reviewer",
              instructions: "Investigate complex bugs and architecture. Review risks. Do not edit files unless asked.",
              model: reviewer)]
    }

    private static func readFile(_ path: URL) throws -> String {
        if !FileManager.default.fileExists(atPath: path.path) { return "" }
        guard let data = try? Data(contentsOf: path), let text = String(data: data, encoding: .utf8) else {
            throw CodexRoleError("无法读取 UTF-8 配置文件：\(path.lastPathComponent)")
        }
        return text
    }

    private static func checkSafeText(_ text: String) throws {
        // Refuse multiline TOML because section-looking lines can occur inside strings.
        let tripleDouble = String(repeating: "\"", count: 3)
        let tripleSingle = String(repeating: "'", count: 3)
        if text.contains(tripleDouble) || text.contains(tripleSingle) {
            throw CodexRoleError("配置包含多行 TOML 字符串，已停止自动修改以保护原有内容")
        }
    }

    private static func sectionRange(_ name: String, in text: String) -> Range<String.Index>? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let matches = lines.enumerated().filter { _, l in l.trimmingCharacters(in: .whitespacesAndNewlines) == "[agents.\(name)]" }
        guard matches.count == 1 else { return nil }
        let start = matches[0].offset
        let end = lines.indices.dropFirst(start + 1).first { i in
            lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("[")
        } ?? lines.count
        let prefix = lines.prefix(start).joined(separator: "\n")
        let before = text.index(text.startIndex, offsetBy: prefix.utf16.count == 0 ? 0 : prefix.count + 1)
        let count = lines[start..<end].joined(separator: "\n").count
        return before..<text.index(before, offsetBy: count)
    }

    private static func rolePath(_ name: String, rootText: String, root: URL) throws -> URL {
        let fallback = root.appendingPathComponent("agents/\(name).toml")
        let sectionCount = rootText.split(separator: "\n").filter {
            $0.trimmingCharacters(in: .whitespacesAndNewlines) == "[agents.\(name)]"
        }.count
        guard sectionCount <= 1 else { throw CodexRoleError("\(name) 有重复的注册段，已阻止覆盖") }
        guard let section = sectionRange(name, in: rootText) else { return fallback }
        let lines = rootText[section].split(separator: "\n").map(String.init)
        let setting = lines.filter { $0.range(of: #"^\s*config_file\s*="#,
                                            options: .regularExpression) != nil }
        guard setting.count == 1 else {
            throw CodexRoleError("\(name) 已登记但 config_file 缺失或重复，请先检查原配置")
        }
        let pattern = #"^\s*config_file\s*=\s*['\"]([^'\"]+)['\"]\s*(?:#.*)?$"#
        guard let match = setting[0].range(of: pattern, options: .regularExpression),
              let pathRange = setting[0].range(of: #"(?<=['\"])[^'\"]+(?=['\"])"#, options: .regularExpression) else {
            throw CodexRoleError("\(name) 的 config_file 使用了无法识别的写法")
        }
        _ = match
        let raw = String(setting[0][pathRange])
        let expanded = raw.hasPrefix("~/") ? root.deletingLastPathComponent().appendingPathComponent(String(raw.dropFirst(2))) :
            (raw.hasPrefix("/") ? URL(fileURLWithPath: raw) : root.appendingPathComponent(raw))
        return expanded.standardizedFileURL
    }

    private static func modelValue(from text: String) throws -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let beforeSection = lines.prefix { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("[") }
        let matching = beforeSection.filter { $0.range(of: #"^\s*model\s*="#,
                                                        options: .regularExpression) != nil }
        guard matching.count <= 1 else { throw CodexRoleError("角色配置有重复的 model 键") }
        guard let line = matching.first else { return "" }
        let value = line.split(separator: "=", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces) ?? ""
        let pattern = #"^['\"]([a-zA-Z0-9._-]+)['\"]\s*(?:#.*)?$"#
        guard value.range(of: pattern, options: .regularExpression) != nil else {
            throw CodexRoleError("角色配置中的 model 值无法识别，请手动检查")
        }
        return String(value.dropFirst().prefix { $0 != "\"" && $0 != "'" })
    }

    private static func setRootModel(in text: String, to model: String,
                                     instructions: String) throws -> String {
        _ = try modelValue(from: text) // validate existing field before editing
        if text.isEmpty {
            return "developer_instructions = \"\(instructions)\"\n" +
                (model.isEmpty ? "" : "model = \"\(model)\"\n")
        }
        var lines = text.components(separatedBy: "\n")
        var rootModelIndex: Int?
        for (index, line) in lines.enumerated() {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("[") { break }
            if line.range(of: #"^\s*model\s*="#,
                          options: .regularExpression) != nil { rootModelIndex = index; break }
        }
        if let index = rootModelIndex {
            if model.isEmpty { lines.remove(at: index) }
            else {
                // Preserve same-line explanatory comments, without touching other fields.
                let oldLine = lines[index]
                let comment = oldLine.firstIndex(of: "#").map { " " + oldLine[$0...] } ?? ""
                lines[index] = "model = \"\(model)\"" + comment
            }
        } else if !model.isEmpty {
            let beforeTable = lines.firstIndex { $0.trimmingCharacters(in: .whitespaces).hasPrefix("[") } ?? lines.count
            lines.insert("model = \"\(model)\"", at: beforeTable)
        }
        return lines.joined(separator: "\n")
    }
}
