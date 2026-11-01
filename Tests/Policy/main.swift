// Copyright 2026 CallTap contributors.
// SPDX-License-Identifier: Apache-2.0
// Run with bash Tests/Policy/run.sh.

import Foundation

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fatalError("FAILED: \(message)")
    }
}

let firstID = UUID()
let secondID = UUID()
func call(_ id: UUID = firstID, connected: Bool = true, ended: Bool = false,
          held: Bool = false) -> AirRecordCallState {
    AirRecordCallState(id: id, hasConnected: connected, hasEnded: ended, isOnHold: held)
}

do {
    var policy = AirRecordPolicy()
    check(policy.decision(calls: [], enabled: true, now: 0) == .noCall, "no call")
    check(policy.decision(calls: [call(connected: false)], enabled: true, now: 0) == .connecting,
          "ringing must not start")
    check(!policy.reserveStart(for: firstID, calls: [call(connected: false)]),
          "cannot reserve an unconnected call")
    check(policy.decision(calls: [call()], enabled: true, now: 1) == .inspect(firstID),
          "connected callback starts readiness inspection")
    check(policy.decision(calls: [call()], enabled: true, now: 2) == .inspect(firstID),
          "duplicate callback remains bounded readiness inspection")
    check(policy.reserveStart(for: firstID, calls: [call()]), "first tap reservation")
    check(!policy.reserveStart(for: firstID, calls: [call()]), "no second reservation")
    check(policy.decision(calls: [call()], enabled: true, now: 3) == .handled(firstID),
          "ambiguous or successful tap is never retried")
    policy.resume()
    check(policy.decision(calls: [call()], enabled: true, now: 4) == .handled(firstID),
          "resume cannot grant a second start tap")
}

do {
    var policy = AirRecordPolicy()
    check(policy.decision(calls: [call(held: true)], enabled: true, now: 0) == .held,
          "held call")
    check(policy.decision(calls: [call(), call(secondID, connected: false)], enabled: true, now: 0)
          == .multipleCalls, "call waiting blocks start too")
    check(policy.decision(calls: [call(), call(secondID, held: true)], enabled: true, now: 1)
          == .multipleCalls, "held second call still counts")
    check(policy.decision(calls: [call()], enabled: true, now: 2) == .inspect(firstID),
          "single remaining connected call can be inspected")
    check(!policy.reserveStart(for: firstID, calls: [call(), call(secondID)]),
          "revalidate active count immediately before tap")
    check(!policy.reserveStart(for: firstID, calls: [call(held: true)]),
          "revalidate hold immediately before tap")
    check(!policy.reserveStart(for: firstID, calls: [call(ended: true)]),
          "revalidate ended immediately before tap")
    check(!policy.reserveStart(for: secondID, calls: [call()]), "must match UUID")
}

do {
    var policy = AirRecordPolicy()
    check(policy.decision(calls: [call()], enabled: false, now: 0) == .paused, "pause")
    check(!policy.reserveStart(for: firstID, calls: [call()]), "no inspection while paused")
    _ = policy.decision(calls: [call()], enabled: true, now: 1)
    _ = policy.decision(calls: [call()], enabled: false, now: 1.1)
    check(!policy.reserveStart(for: firstID, calls: [call()]), "pause revokes a pending tap")
    _ = policy.decision(calls: [call()], enabled: true, now: 1.2)
    policy.markAlreadyRecording(firstID)
    check(!policy.reserveStart(for: firstID, calls: [call()]), "manual recording is respected")
    policy.resume()
    check(policy.decision(calls: [call()], enabled: true, now: 2) == .handled(firstID),
          "manual recording stays handled after resume")
    check(policy.decision(calls: [call(ended: true)], enabled: true, now: 3) == .noCall,
          "ended call removed")
    check(policy.completedCalls.isEmpty, "ended UUID pruned")
    check(policy.decision(calls: [call()], enabled: true, now: 4) == .inspect(firstID),
          "reused UUID after ended session is new")
    check(policy.reserveStart(for: firstID, calls: [call()]), "new session can reserve")
    _ = policy.decision(calls: [], enabled: false, now: 5)
    check(policy.reservedStarts.isEmpty, "cleanup runs while paused too")
}

do {
    var policy = AirRecordPolicy(retryWindow: 2, maximumInspections: 10)
    check(policy.decision(calls: [call()], enabled: true, now: 0) == .inspect(firstID), "window starts")
    check(policy.decision(calls: [call()], enabled: true, now: 3) == .expired(firstID), "deadline bound")
    check(policy.decision(calls: [call()], enabled: true, now: 4) == .handled(firstID),
          "deadline is not reset by another callback")
    policy.resume()
    check(policy.decision(calls: [call()], enabled: true, now: 5) == .handled(firstID),
          "expired call remains handled until new call")
    check(!policy.reserveStart(for: firstID, calls: [call()]), "expired never reserves")
}

do {
    var policy = AirRecordPolicy(retryWindow: 100, maximumInspections: 2)
    _ = policy.decision(calls: [call()], enabled: true, now: 0)
    _ = policy.decision(calls: [call()], enabled: true, now: 0.1)
    check(policy.decision(calls: [call()], enabled: true, now: 0.2) == .expired(firstID),
          "inspection count bound")
}

do {
    check(AirRecordCallUI.recognizes(buttonLabels: ["더 보기", "소리 끔", "스피커", "키패드"]),
          "captured iOS 27 Korean call controls work without a recognized end label")
    check(AirRecordCallUI.recognizes(buttonLabels: ["more options", " MUTE ", "Audio", "Keypad"]),
          "English controls use the same normalized semantic families")
    check(AirRecordCallUI.recognizes(buttonLabels: ["통화 종료", "소리 끔"]),
          "the existing end-call plus control route still works")
    check(!AirRecordCallUI.recognizes(buttonLabels: ["더 보기", "키패드"]),
          "a generic More menu and keypad alone are not a call screen")
    check(!AirRecordCallUI.recognizes(buttonLabels: ["More", "Mute", "음소거", "Keypad"]),
          "multiple mute aliases cannot replace the missing audio family")
    check(!AirRecordCallUI.recognizes(buttonLabels: ["More", "More Options", "Mute", "Speaker", "Keypad"]),
          "an ambiguous More target cannot verify the fallback screen")
    check(!AirRecordCallUI.recognizes(buttonLabels: ["Mute", "Speaker", "Keypad"]),
          "the fallback requires the actual More menu too")
    check(!AirRecordCallUI.recognizes(buttonLabels: ["Hang Up"]),
          "an end-call label alone is insufficient")
    check(!AirRecordCallUI.recognizes(buttonLabels: ["More", "one", "two", "three"]),
          "unknown buttons cannot replace known call controls")
}

do {
    var policy = AirRecordPolicy()
    _ = policy.decision(calls: [call()], enabled: true, now: 0)
    check(policy.reserveMenuWindow(for: firstID, calls: [call()], now: 19.5) == 27.5,
          "a late More request receives eight seconds for menu readiness and confirmation")
    check(policy.reserveMenuWindow(for: firstID, calls: [call()], now: 21) == nil,
          "the same menu cannot repeatedly extend its deadline")
    check(policy.decision(calls: [call()], enabled: true, now: 22) == .inspect(firstID),
          "record inspection survives the old twenty-second boundary")
    check(policy.reserveStart(for: firstID, calls: [call()]), "start can be reserved in menu phase")
    policy.resume()
    check(policy.reserveMenuWindow(for: firstID, calls: [call()], now: 23) == nil,
          "rearm cannot reopen the window of a submitted recording start")
    check(policy.decision(calls: [call()], enabled: true, now: 23) == .handled(firstID),
          "rearm never submits a second recording start")
}

do {
    var policy = AirRecordPolicy()
    _ = policy.decision(calls: [call()], enabled: true, now: 0)
    check(policy.reserveMenuWindow(for: firstID, calls: [call(held: true)], now: 1) == nil,
          "held calls cannot reserve a menu phase")
    check(policy.reserveMenuWindow(for: firstID, calls: [call(), call(secondID)], now: 1) == nil,
          "multiple calls cannot reserve a menu phase")
    check(policy.reserveMenuWindow(for: secondID, calls: [call()], now: 1) == nil,
          "menu phase must match the active call")
    check(policy.reserveMenuWindow(for: firstID, calls: [call()], now: 19.5) != nil,
          "only a valid call enters the menu phase")
    check(policy.decision(calls: [call()], enabled: true, now: 28) == .expired(firstID),
          "menu phase is still bounded")
    check(!policy.reserveStart(for: firstID, calls: [call()]), "expired menu never starts recording")
    check(policy.decision(calls: [], enabled: true, now: 29) == .noCall,
          "ended calls clear their menu reservations")
    check(policy.decision(calls: [call()], enabled: true, now: 30) == .inspect(firstID),
          "a genuinely new session may reuse an ended UUID")
    check(policy.reserveMenuWindow(for: firstID, calls: [call()], now: 30) != nil,
          "the new session can reserve its own menu phase")
}

do {
    var lease = AirRecordKeepAliveLease()
    let current = UUID(), old = UUID()
    lease.begin(current)
    lease.hostDebuggerReported(current)
    lease.helperDebuggerReported(current)
    check(!lease.isValid(now: 10, hostTraced: true), "attach reports without a heartbeat never maintain runtime")
    lease.receivedHeartbeat(current, hostAttached: true, helperTraced: true, now: 10)
    check(lease.isValid(now: 16, hostTraced: true), "a fresh, traced two-process session maintains runtime")
    check(!lease.isValid(now: 16.01, hostTraced: true), "stale helper heartbeat revokes runtime")
    check(!lease.isValid(now: 11, hostTraced: false), "persistent JIT state cannot replace live host tracing")
    lease.receivedHeartbeat(old, hostAttached: false, helperTraced: false, now: 11)
    check(lease.isValid(now: 11, hostTraced: true), "an old session cannot revoke a newer lease")
    lease.receivedHeartbeat(current, hostAttached: false, helperTraced: true, now: 12)
    check(!lease.isValid(now: 12, hostTraced: true), "negative peer evidence revokes immediately")
    lease.invalidate()
    lease.receivedHeartbeat(current, hostAttached: true, helperTraced: true, now: 13)
    check(!lease.isValid(now: 13, hostTraced: true), "late heartbeat after Stop cannot restore a lease")
    lease.begin(old)
    lease.hostDebuggerReported(current)
    lease.helperDebuggerReported(current)
    lease.receivedHeartbeat(old, hostAttached: true, helperTraced: true, now: 20)
    check(!lease.isValid(now: 20, hostTraced: true), "old debugger completions cannot complete a new session")
}

do {
    let current = UUID()
    var lease = AirRecordKeepAliveLease()
    check(lease.issue(now: 10, hostTraced: true) == .missingEvidence,
          "an unconfigured lease reports missing evidence")
    lease.begin(current)
    lease.hostDebuggerReported(current)
    lease.helperDebuggerReported(current)
    lease.receivedHeartbeat(current, hostAttached: true, helperTraced: true, now: 10)
    check(lease.issue(now: 17, hostTraced: true) == .staleHeartbeat,
          "a delayed heartbeat is distinguished from a detached host")
    check(lease.issue(now: 17, hostTraced: false) == .hostUntraced,
          "actual host trace loss is not treated as only a delayed heartbeat")
    lease.receivedHeartbeat(current, hostAttached: true, helperTraced: false, now: 17)
    check(lease.issue(now: 17, hostTraced: true) == .helperUntraced,
          "negative helper trace evidence is diagnosed immediately")
    check(lease.issue(now: .nan, hostTraced: true) == .invalidTime,
          "non-finite diagnostic time fails closed")
}

do {
    let current = UUID()
    var lease = AirRecordKeepAliveLease()
    lease.begin(current)
    lease.hostDebuggerReported(current)
    lease.helperDebuggerReported(current)
    lease.receivedHeartbeat(current, hostAttached: true, helperTraced: true, now: 10)
    lease.receivedHeartbeat(current, hostAttached: true, helperTraced: true, now: 17, sampledAt: 10)
    check(lease.heartbeat == 10 && lease.issue(now: 17, hostTraced: true) == .staleHeartbeat,
          "a queued old heartbeat cannot become fresh at receive time")
    lease.receivedHeartbeat(current, hostAttached: true, helperTraced: true, now: 17, sampledAt: 18)
    lease.receivedHeartbeat(current, hostAttached: true, helperTraced: true, now: 17, sampledAt: .infinity)
    lease.receivedHeartbeat(current, hostAttached: true, helperTraced: true, now: .nan, sampledAt: 17)
    check(lease.heartbeat == 10, "future and non-finite samples cannot refresh evidence")
    lease.receivedHeartbeat(current, hostAttached: true, helperTraced: true, now: 17, sampledAt: 16)
    check(lease.heartbeatAge(now: 18) == 2,
          "freshness measures sampling age instead of callback age")
    lease.receivedHeartbeat(current, hostAttached: true, helperTraced: true, now: 18, sampledAt: 15.5)
    lease.receivedHeartbeat(current, hostAttached: true, helperTraced: true, now: 16.9, sampledAt: 16.5)
    check(lease.heartbeat == 16, "backwards sampling or receive clocks cannot replace newer evidence")
    check(lease.issue(now: 16.5, hostTraced: true) == .invalidTime,
          "a backwards current clock is reported separately")
}

do {
    let current = UUID(), old = UUID()
    var lease = AirRecordKeepAliveLease()
    lease.begin(current)
    lease.hostDebuggerReported(current)
    lease.helperDebuggerReported(current)
    lease.receivedHeartbeat(current, hostAttached: true, helperTraced: true, now: 10)
    guard let ping = lease.beginRecheck(current, now: 20) else { fatalError("expected recheck") }
    check(lease.pendingDeadline == 28 && lease.sentAt == 20,
          "a recheck has a fixed eight-second deadline")
    check(lease.beginRecheck(current, now: 21) == nil && lease.pendingDeadline == 28,
          "repeated health ticks cannot extend an outstanding challenge")
    lease.receivedHeartbeat(current, hostAttached: true, helperTraced: true, now: 21, sampledAt: 21)
    check(lease.issue(now: 21, hostTraced: true) == .challengePending
          && !lease.isValid(now: 21, hostTraced: true),
          "even a positive ordinary heartbeat cannot satisfy the pending challenge")
    check(!lease.acceptPong(old, pingID: ping, sampledAt: 22, hostAttached: true,
                           helperTraced: true, hostTraced: true, now: 22),
          "an old session cannot answer the current challenge")
    check(!lease.acceptPong(current, pingID: ping + 1, sampledAt: 22, hostAttached: true,
                           helperTraced: true, hostTraced: true, now: 22),
          "a mismatched challenge identifier is rejected")
    check(!lease.acceptPong(current, pingID: ping, sampledAt: 19.9, hostAttached: true,
                           helperTraced: true, hostTraced: true, now: 22),
          "a sample predating the ping cannot prove a fresh peer response")
    check(!lease.acceptPong(current, pingID: ping, sampledAt: 23, hostAttached: true,
                           helperTraced: true, hostTraced: true, now: 22),
          "a pong with a future sample is rejected")
    check(!lease.acceptPong(current, pingID: ping, sampledAt: 22, hostAttached: true,
                           helperTraced: true, hostTraced: false, now: 22),
          "a fresh pong cannot replace actual host tracing")
    check(!lease.acceptPong(current, pingID: ping, sampledAt: 22, hostAttached: true,
                           helperTraced: false, hostTraced: true, now: 22),
          "a fresh pong cannot replace actual helper tracing")
    check(!lease.acceptPong(current, pingID: ping, sampledAt: 22, hostAttached: false,
                           helperTraced: true, hostTraced: true, now: 22),
          "a helper without a host debugger connection cannot restore runtime")
    check(lease.pendingID == ping && lease.pendingDeadline == 28,
          "rejected responses neither clear nor extend the challenge")
    check(lease.acceptPong(current, pingID: ping, sampledAt: 22.5, hostAttached: true,
                          helperTraced: true, hostTraced: true, now: 23),
          "a fresh matching pong restores the current two-process session")
    check(lease.isValid(now: 23, hostTraced: true) && lease.pendingID == nil
          && lease.pendingDeadline == nil && lease.sentAt == nil,
          "successful recovery clears the challenge and leaves valid fresh evidence")
    guard let next = lease.beginRecheck(current, now: 30) else { fatalError("expected next recheck") }
    check(next != ping, "each challenge in one session uses a new identifier")
    check(!lease.acceptPong(current, pingID: ping, sampledAt: 30, hostAttached: true,
                           helperTraced: true, hostTraced: true, now: 30),
          "a delayed old pong cannot satisfy a newer challenge")
    check(!lease.recheckExpired(now: 37.99) && lease.recheckExpired(now: 38),
          "the recovery deadline expires at its original bound")
    check(!lease.acceptPong(current, pingID: next, sampledAt: 38, hostAttached: true,
                           helperTraced: true, hostTraced: true, now: 38),
          "an expired challenge cannot revive the session")
    lease.receivedHeartbeat(current, hostAttached: true, helperTraced: true, now: 39, sampledAt: 39)
    check(!lease.isValid(now: 39, hostTraced: true) && lease.pendingDeadline == 38,
          "ordinary heartbeat after timeout still cannot revive or extend recovery")
    lease.invalidate()
    check(!lease.acceptPong(current, pingID: next, sampledAt: 39, hostAttached: true,
                           helperTraced: true, hostTraced: true, now: 39),
          "late pong after Stop cannot restore a lease")
    check(lease.pendingID == nil && lease.pendingDeadline == nil && !lease.recheckExpired(now: 40),
          "Stop removes all pending recovery state")
}

do {
    let nonce = String(repeating: "a", count: 64)
    let hello = AirRecordKeepAliveMessage(type: "hello", session: firstID.uuidString, nonce: nonce, helperPID: 42)
    let data = try AirRecordKeepAliveWire.encode(hello)
    var buffer = Data()
    let incomplete = try AirRecordKeepAliveWire.append(Data(data.prefix(7)), to: &buffer)
    check(incomplete.isEmpty,
          "a split IPC frame waits for the remaining bytes")
    let messages = try AirRecordKeepAliveWire.append(Data(data.dropFirst(7)) + data, to: &buffer)
    check(messages.count == 2 && messages.allSatisfy { $0.helperPID == 42 } && buffer.isEmpty,
          "fragmented and coalesced IPC frames preserve message boundaries")
    check(AirRecordKeepAliveWire.matchesNonce(nonce, nonce), "matching session nonce is accepted")
    check(!AirRecordKeepAliveWire.matchesNonce(nonce, String(repeating: "b", count: 64)), "wrong nonce is rejected")
    do {
        _ = try AirRecordKeepAliveWire.append(Data(repeating: 65, count: AirRecordKeepAliveWire.maximumFrameBytes + 2), to: &buffer)
        check(false, "oversized IPC data must be rejected")
    } catch { }
    do {
        var invalid = Data()
        _ = try AirRecordKeepAliveWire.append(Data("\n".utf8), to: &invalid)
        check(false, "empty IPC frame must be rejected")
    } catch { }
}

do {
    var location = AirRecordLocationSessionPolicy()
    check(location.session == nil && !location.isReady,
          "location standby begins without an execution session")
    let current = location.begin()
    check(location.matches(current) && !location.isReady && location.lastSampledAt == nil,
          "starting or waiting for permission does not claim location readiness")
    check(!location.receivedSample(for: current, now: 1_000, sampledAt: 939.9)
          && !location.isReady,
          "a delayed cached fix cannot establish readiness at callback time")
    check(location.receivedSample(for: current, now: 1_000, sampledAt: 940)
          && location.isReady,
          "a first sample within sixty seconds establishes this manager's readiness")
    check(location.matches(current) && location.isReady,
          "an already running location session can be reused without beginning a new generation")
}

do {
    var location = AirRecordLocationSessionPolicy()
    let current = location.begin()
    for sample in [TimeInterval.nan, .infinity, -.infinity, -1, 1_001] {
        check(!location.receivedSample(for: current, now: 1_000, sampledAt: sample),
              "invalid or future location sampling times cannot establish readiness")
    }
    for received in [TimeInterval.nan, .infinity, -.infinity, -1] {
        check(!location.receivedSample(for: current, now: received, sampledAt: 999),
              "invalid callback times cannot establish readiness")
    }
    check(!location.isReady && location.lastSampledAt == nil,
          "rejected initial callbacks leave the session unready")
    check(location.receivedSample(for: current, now: 1_000, sampledAt: 999),
          "valid data can arrive after permission and invalid cached callbacks")
    check(!location.receivedSample(for: current, now: 1_001, sampledAt: 998),
          "out-of-order location data cannot replace a newer accepted sample")
    check(!location.receivedSample(for: current, now: 999.5, sampledAt: 999.5),
          "a backwards callback clock does not replace current session evidence")
    check(location.lastSampledAt == 999 && location.isReady,
          "rejected later samples preserve valid execution evidence")
}

do {
    var location = AirRecordLocationSessionPolicy()
    let old = location.begin()
    check(location.receivedSample(for: old, now: 1_000, sampledAt: 1_000),
          "the initial manager establishes readiness")
    let current = location.begin()
    check(current != old && !location.isReady,
          "a replacement manager requires a new generation and a new fresh sample")
    check(!location.receivedSample(for: old, now: 1_001, sampledAt: 1_001)
          && !location.isReady,
          "a queued callback from the previous manager cannot ready the replacement")
    check(!location.pause(for: old) && location.matches(current),
          "an old manager's pause callback cannot stop the replacement")
    check(location.receivedSample(for: current, now: 1_002, sampledAt: 1_002),
          "the replacement manager can independently establish readiness")
    check(location.pause(for: current) && !location.isReady && location.session == nil,
          "a current pause revokes execution and invalidates its generation")
    check(!location.receivedSample(for: current, now: 1_003, sampledAt: 1_003),
          "a callback arriving after pause cannot silently resume execution")
}

do {
    var location = AirRecordLocationSessionPolicy()
    let stopped = location.begin()
    location.stop()
    check(!location.matches(stopped) && !location.isReady,
          "Stop revokes a pending permission or sampling session")
    check(!location.receivedSample(for: stopped, now: 1_000, sampledAt: 1_000),
          "late authorization-following data cannot restart a stopped session")
    let current = location.begin()
    check(current != stopped && !location.isReady,
          "an explicit later start waits for its own sample")
    check(location.receivedSample(for: current, now: 1_001, sampledAt: 1_001),
          "the explicit new start can become ready")
    location.stop()
    check(location.session == nil && !location.isReady && location.lastSampledAt == nil,
          "Stop clears the current execution evidence")
}

do {
    var indicator = AirRecordLocationIndicatorPolicy()
    check(indicator.showsBackgroundLocationIndicator,
          "the default preference never suppresses the location indicator")
    for authorization in AirRecordLocationIndicatorPolicy.Authorization.allCases {
        indicator.updateAuthorization(authorization)
        check(indicator.showsBackgroundLocationIndicator,
              "Always authorization alone cannot opt the user into minimization")
    }
    indicator.setMinimizationEnabled(true)
    for authorization in AirRecordLocationIndicatorPolicy.Authorization.allCases where authorization != .always {
        indicator.updateAuthorization(authorization)
        check(indicator.showsBackgroundLocationIndicator,
              "a saved minimization preference cannot hide without actual Always authorization")
    }
    indicator.updateAuthorization(.always)
    check(!indicator.showsBackgroundLocationIndicator,
          "explicit preference plus actual Always permission requests minimization")
    indicator.updateAuthorization(.whenInUse)
    check(indicator.showsBackgroundLocationIndicator && indicator.minimizationEnabled,
          "revoking Always immediately restores the indicator without clearing the preference")
    indicator.updateAuthorization(.always)
    check(!indicator.showsBackgroundLocationIndicator,
          "a later actual Always grant can apply the retained preference")
    indicator.setMinimizationEnabled(false)
    check(indicator.showsBackgroundLocationIndicator,
          "opting out immediately restores the indicator even while Always is granted")
    indicator.setMinimizationEnabled(true)
    for authorization in [AirRecordLocationIndicatorPolicy.Authorization.denied, .restricted, .unknown, .notDetermined] {
        indicator.updateAuthorization(authorization)
        check(indicator.showsBackgroundLocationIndicator,
              "denied, restricted, unknown, and undecided transitions fail back to a visible indicator request")
    }
}

do {
    typealias Permission = AirRecordBackgroundPermissionPolicy
    func preflight(_ trigger: Permission.Trigger = .enabledByUser,
                   monitoring: Bool = false,
                   authorization: Permission.Authorization = .notDetermined,
                   pending: Bool = false, foreground: Bool = true,
                   liveContainer: Bool = false, purpose: Bool = true) -> Permission.Plan {
        Permission.plan(trigger: trigger, monitoringEnabled: monitoring,
                        authorization: authorization, requestPending: pending,
                        isForeground: foreground, isLiveContainer: liveContainer,
                        hasUsageDescription: purpose)
    }
    let independent = preflight()
    check(independent.action == .requestWhenInUse && !independent.shouldPrepareMonitoring,
          "explicit background-on requests basic permission while the main feature remains OFF; connection prerequisites are not inputs")
    let enabled = preflight(monitoring: true)
    check(enabled.action == .requestWhenInUse && !enabled.shouldPrepareMonitoring && enabled.requiresPermissionDecision,
          "main ON still requests basic permission first and waits rather than preparing through an inactive permission sheet")
    check(preflight(pending: true).action == .waitForDecision,
          "repeating background-on while a request is pending cannot issue a second prompt")
    check(preflight(monitoring: true, pending: true).requiresPermissionDecision,
          "a still-enabled explicit activation waits for an existing permission decision")
    for trigger in [Permission.Trigger.disabledByUser, .passive] {
        check(preflight(trigger, monitoring: true).action == .none,
              "background-off and passive preflight never add a permission request")
    }
    check(preflight(.disabledByUser, monitoring: true).shouldPrepareMonitoring,
          "background-off retains the enabled main feature's finite-runtime fallback")
    check(!preflight(.disabledByUser).shouldPrepareMonitoring,
          "background-off never turns a saved OFF main feature on")
    let permitted = preflight(monitoring: true, authorization: .authorized)
    check(permitted.action == .none && permitted.shouldPrepareMonitoring,
          "already-granted permission follows normal main-enabled preparation without a new prompt")
    check(!preflight(authorization: .authorized).shouldPrepareMonitoring,
          "permission already granted still cannot turn a saved OFF main feature on")
    for authorization in [Permission.Authorization.denied, .restricted, .unknown] {
        let blocked = preflight(monitoring: true, authorization: authorization)
        check(blocked.action == .showSettings && !blocked.shouldPrepareMonitoring && !blocked.requiresPermissionDecision,
              "denied, restricted, and unknown authorization offer Settings without fake prompts or execution")
    }
    check(preflight(foreground: false).action == .requireForeground,
          "a new permission request requires an active foreground user action")
    check(preflight(liveContainer: true).action == .unsupportedEnvironment,
          "LiveContainer cannot issue the independent-app permission request")
    check(preflight(purpose: false).action == .missingUsageDescription,
          "a package missing its privacy explanation cannot request permission")
}

print("AirRecordPolicy: call safety, lease recovery, bounded IPC, location session, indicator and explicit background permission checks passed")
