import Combine
import Foundation

//
//  AwakeProfileStore.swift
//  MacPilot
//
//  会话方案的存储层：负责方案的增删改查与「最近使用」。
//  持久化复用 config.json 的 StoredConfiguration 通道（awakeProfiles 键），
//  Session 的启动仍由 `AwakeSessionManager` 负责——方案只是配置模板。
//

@MainActor
final class AwakeProfileStore: ObservableObject {
    @Published private(set) var profiles: [AwakeSessionProfile] = []

    /// 由 `MacPilotModel` 注入，写回 config.json。
    var persist: (() -> Void)?

    /// 启动时整体载入，不触发持久化。
    func load(_ loaded: [AwakeSessionProfile]) {
        profiles = loaded
    }

    /// 旧版启动方案选择迁移到方案自身，编辑页才能显示并关闭该选项。
    /// 仅在加载时调用；历史 Codable 键仍保留，避免影响降级读取。
    func migrateLegacyAutomaticStart(in settings: inout AwakeSettings) {
        guard settings.defaultSession.launchProfileEnabled,
              let id = settings.defaultSession.launchProfileID,
              let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[index].configuration.autoStartOnLaunch = true
        settings.defaultSession.launchProfileEnabled = false
    }

    func profile(id: UUID) -> AwakeSessionProfile? {
        profiles.first { $0.id == id }
    }

    func profile(named name: String) -> AwakeSessionProfile? {
        let normalized = AwakeSessionProfile.normalizedName(name).lowercased()
        return profiles.first { $0.name.lowercased() == normalized }
    }

    /// 生成一个未被占用的名称：base、base 2、base 3…
    func availableName(base: String) -> String {
        let base = AwakeSessionProfile.normalizedName(base)
        guard profile(named: base) != nil else { return base }
        var counter = 2
        while profile(named: "\(base) \(counter)") != nil { counter += 1 }
        return "\(base) \(counter)"
    }

    @discardableResult
    func create(name: String, configuration: AwakeSessionProfileConfiguration, at date: Date = Date()) -> AwakeSessionProfile {
        let profile = AwakeSessionProfile(
            name: AwakeSessionProfile.normalizedName(name),
            createdAt: date,
            configuration: configuration
        )
        profiles.append(profile)
        persist?()
        return profile
    }

    /// 整体替换一个方案（编辑保存）。
    func update(_ updated: AwakeSessionProfile) {
        guard let index = profiles.firstIndex(where: { $0.id == updated.id }) else { return }
        profiles[index] = updated
        persist?()
    }

    /// 按名称覆盖：保留原方案的 id 与创建时间，只替换配置（保存流程的同名覆盖）。
    @discardableResult
    func overwriteConfiguration(of profileID: UUID, with configuration: AwakeSessionProfileConfiguration) -> Bool {
        guard let index = profiles.firstIndex(where: { $0.id == profileID }) else { return false }
        profiles[index].configuration = configuration
        persist?()
        return true
    }

    /// 复制方案：得到一份可以独立微调的副本，不带「最近使用」。
    @discardableResult
    func duplicate(id: UUID, suggestedName: String, at date: Date = Date()) -> AwakeSessionProfile? {
        guard let source = profile(id: id) else { return nil }
        return create(
            name: availableName(base: suggestedName),
            configuration: source.configuration,
            at: date
        )
    }

    func delete(id: UUID) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles.remove(at: index)
        persist?()
    }

    /// 记录「最近使用」。由 `launch` 调用，也可以被单独刷新。
    func markUsed(id: UUID, at date: Date = Date()) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[index].lastUsedAt = date
        persist?()
    }

    /// 一键按方案开始 Session：解析方案 → 记录最近使用 → 启动。
    /// 方案已被删除时返回 nil。
    @discardableResult
    func launch(
        _ profileID: UUID,
        in manager: AwakeSessionManager,
        replacingActiveSessions: Bool = false,
        at date: Date = Date()
    ) -> UUID? {
        guard let profile = profile(id: profileID) else { return nil }
        markUsed(id: profileID, at: date)
        return manager.startProfileSession(
            from: profile,
            replacingActiveSessions: replacingActiveSessions
        )
    }
}
