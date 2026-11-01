// Copyright 2026 AirRecord contributors. SPDX-License-Identifier: Apache-2.0

/// Stores the preference separately from the currently observed authorization.
/// A saved preference alone never authorizes suppressing the location indicator.
struct AirRecordLocationIndicatorPolicy {
    enum Authorization: CaseIterable, Equatable {
        case notDetermined, whenInUse, always, denied, restricted, unknown
    }

    private(set) var minimizationEnabled = false
    private(set) var authorization: Authorization = .unknown

    var showsBackgroundLocationIndicator: Bool {
        !minimizationEnabled || authorization != .always
    }

    mutating func setMinimizationEnabled(_ enabled: Bool) {
        minimizationEnabled = enabled
    }

    mutating func updateAuthorization(_ current: Authorization) {
        authorization = current
    }
}
