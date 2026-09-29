import Foundation

//
//  AwakeSessionProfile.swift
//  MacPilot
//
//  会话方案：把一次完整的 Awake Session 业务配置保存为可复用的模板。
//
//  方案只保存最终业务配置，不保存 UI 状态；启动方案时把它原样转换成
//  SessionEndCondition + SessionPolicy 交给 `AwakeSessionManager.startSession`，
//  之后方案本身的修改、删除都不影响已经开始的 Session。
//

/// 一次完整 Session 的业务配置快照。
///
/// 覆盖「Session 配置」卡与「Session 保护」弹窗里的全部选项：时长、
/// 显示器、合盖运行、屏幕保护程序、强制睡眠、电量保护与电源适配器。
/// 结束时间计算已统一为「使用计时器」，不再是用户可配置项。
struct AwakeSessionProfileConfiguration: Codable, Equatable, Sendable {
    /// 分钟数；`0` 表示不限时（手动结束）。「直到指定时间」预设不进方案：
    /// 绝对日期保存后必然过期，捕获时按剩余时间折算成分钟。
    var durationMinutes: Int
    /// 已废弃的用户选项，但字段必须永久保留并始终编码：旧版本解码本结构
    /// 时要求这个键存在，删掉它会让旧版本读不了新配置，降级时整份配置
    /// 被重置（v1.1.482-beta.5 的教训）。新方案一律写入 `.timer`。
    var endCalculation: SessionEndCalculation
    var endOnForcedSleep: Bool
    var preventDisplaySleep: Bool
    var allowSystemSleepWhenDisplayOff: Bool
    var preventClosedLidSleep: Bool
    var blockScreenSaver: Bool
    var screenSaverIdleMinutes: Int
    var lowBatteryProtectionEnabled: Bool
    var minimumBatteryLevel: Int
    var warnBeforeBatteryTermination: Bool
    var ignoreBatteryLevelOnExternalPower: Bool
    var restartOnPowerReconnect: Bool

    /// 从当前全局 Awake 设置捕获一套完整配置。捕获的是「现在这一刻」的
    /// 业务配置，之后全局设置的漂移不会影响已保存的方案。
    static func capture(from settings: AwakeSettings, now: Date = Date()) -> Self {
        var durationMinutes = settings.defaultSession.durationMinutes
        if settings.defaultSession.usesUntilDate, let untilDate = settings.defaultSession.untilDate {
            let remaining = untilDate.timeIntervalSince(now)
            durationMinutes = remaining > 0 ? max(1, Int(ceil(remaining / 60))) : 0
        }
        return Self(
            durationMinutes: max(0, durationMinutes),
            endCalculation: .timer,
            endOnForcedSleep: settings.defaultPolicy.endOnForcedSleep,
            preventDisplaySleep: settings.defaultPolicy.preventDisplaySleep,
            allowSystemSleepWhenDisplayOff: settings.defaultPolicy.allowSystemSleepWhenDisplayOff,
            preventClosedLidSleep: settings.defaultPolicy.preventClosedLidSleep,
            blockScreenSaver: settings.defaultPolicy.blockScreenSaver,
            screenSaverIdleMinutes: settings.defaultPolicy.screenSaverIdleMinutes,
            lowBatteryProtectionEnabled: settings.safetyPolicy.lowBatteryProtectionEnabled,
            minimumBatteryLevel: settings.safetyPolicy.minimumBatteryLevel,
            warnBeforeBatteryTermination: settings.defaultSession.warnBeforeBatteryTermination,
            ignoreBatteryLevelOnExternalPower: settings.defaultSession.ignoreBatteryLevelOnExternalPower,
            restartOnPowerReconnect: settings.defaultSession.restartOnPowerReconnect
        )
    }

    /// 方案的结束条件。空缺字段在捕获时就已折算，这里只有两个分支。
    var endCondition: SessionEndCondition {
        durationMinutes > 0 ? .duration(TimeInterval(durationMinutes) * 60) : .manual
    }

    /// 方案的 Session 策略。阻止系统休眠是保持唤醒的基线（与默认策略一致）；
    /// 结束计算固定为「使用计时器」——存储的 `endCalculation` 只是兼容负载，
    /// 旧方案里残留的 `.pausesDuringSleep` 不再生效。
    var policy: SessionPolicy {
        SessionPolicy(
            preventSystemSleep: true,
            preventDisplaySleep: preventDisplaySleep,
            preventClosedLidSleep: preventClosedLidSleep,
            endCalculation: .timer,
            endOnForcedSleep: endOnForcedSleep,
            allowSystemSleepWhenDisplayOff: allowSystemSleepWhenDisplayOff,
            blockScreenSaver: blockScreenSaver,
            screenSaverIdleMinutes: screenSaverIdleMinutes
        )
    }

    /// 把方案里的电量保护与电源适配器选项写回全局设置。这些选项在
    /// AwakeSettings 中是作用于所有 Session 的全局项，与「Session 保护」
    /// 确认路径保持一致：套用方案即把整套配置落到同一处。
    func applyProtectionSettings(to settings: inout AwakeSettings) {
        settings.safetyPolicy.lowBatteryProtectionEnabled = lowBatteryProtectionEnabled
        settings.safetyPolicy.minimumBatteryLevel = minimumBatteryLevel
        settings.defaultSession.warnBeforeBatteryTermination = warnBeforeBatteryTermination
        settings.defaultSession.ignoreBatteryLevelOnExternalPower = ignoreBatteryLevelOnExternalPower
        settings.defaultSession.restartOnPowerReconnect = restartOnPowerReconnect
    }
}

struct AwakeSessionProfile: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var name: String
    var createdAt: Date
    var lastUsedAt: Date?
    var configuration: AwakeSessionProfileConfiguration

    init(
        id: UUID = UUID(),
        name: String,
        createdAt: Date = Date(),
        lastUsedAt: Date? = nil,
        configuration: AwakeSessionProfileConfiguration
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
        self.configuration = configuration
    }

    /// 方案比较名称时使用的规范形式：去首尾空白。
    static func normalizedName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension AwakeSessionProfileConfiguration {
    private enum CodingKeys: String, CodingKey {
        case durationMinutes, endCalculation, endOnForcedSleep, preventDisplaySleep
        case allowSystemSleepWhenDisplayOff, preventClosedLidSleep, blockScreenSaver
        case screenSaverIdleMinutes, lowBatteryProtectionEnabled, minimumBatteryLevel
        case warnBeforeBatteryTermination, ignoreBatteryLevelOnExternalPower, restartOnPowerReconnect
    }

    /// 宽容解码：beta.5 写出的方案缺 `endCalculation` 键，这里补默认值，
    /// 保证新版本能读回任何历史版本保存的数据。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            durationMinutes: try container.decodeIfPresent(Int.self, forKey: .durationMinutes) ?? 0,
            endCalculation: try container.decodeIfPresent(SessionEndCalculation.self, forKey: .endCalculation) ?? .timer,
            endOnForcedSleep: try container.decodeIfPresent(Bool.self, forKey: .endOnForcedSleep) ?? false,
            preventDisplaySleep: try container.decodeIfPresent(Bool.self, forKey: .preventDisplaySleep) ?? false,
            allowSystemSleepWhenDisplayOff: try container.decodeIfPresent(Bool.self, forKey: .allowSystemSleepWhenDisplayOff) ?? false,
            preventClosedLidSleep: try container.decodeIfPresent(Bool.self, forKey: .preventClosedLidSleep) ?? false,
            blockScreenSaver: try container.decodeIfPresent(Bool.self, forKey: .blockScreenSaver) ?? false,
            screenSaverIdleMinutes: try container.decodeIfPresent(Int.self, forKey: .screenSaverIdleMinutes) ?? 45,
            lowBatteryProtectionEnabled: try container.decodeIfPresent(Bool.self, forKey: .lowBatteryProtectionEnabled) ?? true,
            minimumBatteryLevel: try container.decodeIfPresent(Int.self, forKey: .minimumBatteryLevel) ?? 15,
            warnBeforeBatteryTermination: try container.decodeIfPresent(Bool.self, forKey: .warnBeforeBatteryTermination) ?? false,
            ignoreBatteryLevelOnExternalPower: try container.decodeIfPresent(Bool.self, forKey: .ignoreBatteryLevelOnExternalPower) ?? true,
            restartOnPowerReconnect: try container.decodeIfPresent(Bool.self, forKey: .restartOnPowerReconnect) ?? false
        )
    }
}
