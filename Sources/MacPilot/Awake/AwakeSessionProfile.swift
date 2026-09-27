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
/// 结束时间计算、显示器、合盖运行、屏幕保护程序、电量保护与电源适配器。
struct AwakeSessionProfileConfiguration: Codable, Equatable, Sendable {
    /// 分钟数；`0` 表示不限时（手动结束）。「直到指定时间」预设不进方案：
    /// 绝对日期保存后必然过期，捕获时按剩余时间折算成分钟。
    var durationMinutes: Int
    /// 定时 Session 的倒计时如何对待系统睡眠。
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
            endCalculation: settings.defaultPolicy.endCalculation,
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

    /// 方案的 Session 策略。阻止系统休眠是保持唤醒的基线（与默认策略一致）。
    var policy: SessionPolicy {
        SessionPolicy(
            preventSystemSleep: true,
            preventDisplaySleep: preventDisplaySleep,
            preventClosedLidSleep: preventClosedLidSleep,
            endCalculation: endCalculation,
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
