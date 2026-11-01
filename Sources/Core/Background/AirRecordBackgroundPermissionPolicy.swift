// Copyright 2026 AirRecord contributors. SPDX-License-Identifier: Apache-2.0

/// Plans only the explicit background-setting preflight. It does not replace
/// the existing runtime's permission handling or depend on pairing/VPN/DDI.
enum AirRecordBackgroundPermissionPolicy {
    enum Trigger { case enabledByUser, disabledByUser, passive }
    enum Authorization: Equatable { case notDetermined, authorized, denied, restricted, unknown }
    enum Action: Equatable {
        case none, requestWhenInUse, waitForDecision, showSettings
        case requireForeground, unsupportedEnvironment, missingUsageDescription
    }
    struct Plan {
        let action: Action
        let shouldPrepareMonitoring: Bool

        var requiresPermissionDecision: Bool {
            action == .requestWhenInUse || action == .waitForDecision
        }
    }

    static func plan(trigger: Trigger, monitoringEnabled: Bool,
                     authorization: Authorization, requestPending: Bool,
                     isForeground: Bool, isLiveContainer: Bool,
                     hasUsageDescription: Bool) -> Plan {
        switch trigger {
        case .disabledByUser:
            // Retain the existing finite-runtime fallback when background is off.
            return Plan(action: .none, shouldPrepareMonitoring: monitoringEnabled)
        case .passive:
            // This new preflight never adds permission prompts to launch/resume.
            return Plan(action: .none, shouldPrepareMonitoring: false)
        case .enabledByUser:
            break
        }
        switch authorization {
        case .authorized:
            return Plan(action: .none, shouldPrepareMonitoring: monitoringEnabled)
        case .denied, .restricted, .unknown:
            return Plan(action: .showSettings, shouldPrepareMonitoring: false)
        case .notDetermined:
            if requestPending { return Plan(action: .waitForDecision, shouldPrepareMonitoring: false) }
            if isLiveContainer { return Plan(action: .unsupportedEnvironment, shouldPrepareMonitoring: false) }
            if !isForeground { return Plan(action: .requireForeground, shouldPrepareMonitoring: false) }
            if !hasUsageDescription { return Plan(action: .missingUsageDescription, shouldPrepareMonitoring: false) }
            return Plan(action: .requestWhenInUse, shouldPrepareMonitoring: false)
        }
    }
}
