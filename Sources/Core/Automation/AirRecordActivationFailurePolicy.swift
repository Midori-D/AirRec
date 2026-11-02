// Copyright 2026 AirRecord contributors. SPDX-License-Identifier: Apache-2.0
import Foundation

/// Only a confirmed failure belonging to the current activation may turn its
/// saved preference off. Pauses and cancellation do not use this transition.
enum AirRecordActivationFailurePolicy {
    static func shouldDisable(request: UUID, currentRequest: UUID,
                              isEnabled: Bool, cancelled: Bool) -> Bool {
        request == currentRequest && isEnabled && !cancelled
    }
}
