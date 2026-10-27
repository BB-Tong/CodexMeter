import Foundation
import XCTest
@testable import CodexMeterCore

final class CodexRoleConfigurationTests: XCTestCase {
    func testUpdateExistingModelsPreservesMetadataAndMCP() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("CodexMeter-role-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: home) }
        let root = home.appendingPathComponent(".codex")
        let roles = root.appendingPathComponent("agents")
        try fm.createDirectory(at: roles, withIntermediateDirectories: true)
        let config = root.appendingPathComponent("config.toml")
        let execution = roles.appendingPathComponent("meter_executor.toml")
        let review = roles.appendingPathComponent("meter_reviewer.toml")
        try """
        model = "main-model"
        [mcp_servers.demo]
        command = "echo"
        [agents.meter_executor]
        description = "自定义角色描述"
        config_file = 'agents/meter_executor.toml'
        [agents.meter_reviewer]
        description = "另一个描述"
        config_file = 'agents/meter_reviewer.toml'
        """.write(to: config, atomically: true, encoding: .utf8)
        try """
        developer_instructions = "Do not change this"
        model = "old-model" # preserve this comment
        [mcp_servers.example]
        command = "echo"
        """.write(to: execution, atomically: true, encoding: .utf8)
        try "developer_instructions = 'Review without editing'\n".write(to: review, atomically: true, encoding: .utf8)

        XCTAssertEqual(try CodexRoleConfiguration.read(homeURL: home).executor, "old-model")
        let catalog = try CodexAvailableModel.decodePage(["data": [
            ["model": "model-a", "displayName": "A", "hidden": false],
            ["model": "model-b", "displayName": "B", "hidden": false],
            ["model": "ignored", "hidden": true]]])
        XCTAssertEqual(catalog.map(\.id), ["model-a", "model-b"])
        let desired = CodexRoleSelection(executor: "model-a", reviewer: "model-b")
        let backup = try CodexRoleConfiguration.save(homeURL: home, selection: desired,
                                                        availableIDs: Set(catalog.map(\.id)))
        XCTAssertNotNil(backup)
        XCTAssertEqual(try CodexRoleConfiguration.read(homeURL: home), desired)
        XCTAssertTrue(try String(contentsOf: config).contains("[mcp_servers.demo]"))
        XCTAssertTrue(try String(contentsOf: config).contains("自定义角色描述"))
        XCTAssertTrue(try String(contentsOf: execution).contains("[mcp_servers.example]"))
        XCTAssertTrue(try String(contentsOf: execution).contains("# preserve this comment"))
        XCTAssertNil(try CodexRoleConfiguration.save(homeURL: home, selection: desired,
                                                     availableIDs: Set(catalog.map(\.id))))
        XCTAssertThrowsError(try CodexRoleConfiguration.save(
            homeURL: home, selection: .init(executor: "unknown", reviewer: ""),
            availableIDs: Set(catalog.map(\.id))))
        XCTAssertEqual(try CodexRoleConfiguration.read(homeURL: home), desired)
        _ = try CodexRoleConfiguration.save(homeURL: home,
                                            selection: .init(executor: "", reviewer: ""), availableIDs: [])
        XCTAssertEqual(try CodexRoleConfiguration.read(homeURL: home), .init())
    }

    func testFirstInstallCreatesRolesAndBackups() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("CodexMeter-install-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: home) }
        let root = home.appendingPathComponent(".codex")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let config = root.appendingPathComponent("config.toml")
        try "[mcp_servers.remain]\ncommand = 'echo'\n".write(to: config, atomically: true, encoding: .utf8)
        XCTAssertNotNil(try CodexRoleConfiguration.save(homeURL: home, selection: .init(), availableIDs: []))
        XCTAssertEqual(try CodexRoleConfiguration.read(homeURL: home), .init())
        XCTAssertTrue(try String(contentsOf: config).contains("[mcp_servers.remain]"))
        XCTAssertTrue(try String(contentsOf: config).contains("[agents.meter_executor]"))
    }
}
