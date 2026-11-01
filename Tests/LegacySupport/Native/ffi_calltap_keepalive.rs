// AirRecord, 2026. SPDX-License-Identifier: Apache-2.0
use std::{ffi::c_void, ptr::null_mut};
use crate::{IdeviceFfiError, ffi_err, run_sync_local,
            core_device_proxy::AdapterHandle, rsd::RsdHandshakeHandle};
use idevice::IdeviceError;

/// Event 0 polls continuation; 1 means continue was sent; 2 means cleanup begun.
/// A callback must be thread-safe and must not reenter the FFI runtime.
pub type CallTapDebugKeepAliveCallback = Option<unsafe extern "C" fn(*mut c_void, u32) -> bool>;

/// Maintain a debugger connection to the other trusted host/helper process.
/// Unlike the AX inspection this intentionally has no overall lifetime limit.
/// Cancellation/EOF ends the session with bounded detach, never target kill.
///
/// # Safety
/// Adapter/handshake/context must remain valid on this dedicated worker until
/// return, without concurrent reuse. Caller must bind target_pid to its own
/// authenticated host/helper IPC session, never arbitrary external PID input.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn calltap_debug_keepalive(
    adapter: *mut AdapterHandle, handshake: *mut RsdHandshakeHandle,
    target_pid: u32, callback: CallTapDebugKeepAliveCallback, context: *mut c_void,
) -> *mut IdeviceFfiError {
    if adapter.is_null() || handshake.is_null() || callback.is_none()
        || target_pid <= 1 || target_pid == std::process::id() {
        return ffi_err!(IdeviceError::FfiInvalidArg);
    }
    let callback = callback.unwrap(); let context = context as usize;
    let result = run_sync_local(async move {
        idevice::dvt::calltap_keepalive::maintain(unsafe { &mut (*adapter).0 },
            unsafe { &mut (*handshake).0 }, target_pid,
            move |event| unsafe { callback(context as *mut c_void, event) }).await
    });
    match result { Ok(()) => null_mut(), Err(error) => ffi_err!(error) }
}
