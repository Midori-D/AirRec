// AirRecord, 2026. SPDX-License-Identifier: Apache-2.0
//! A deliberately small debugger connection used only between AirRecord's
//! trusted host and helper. It never changes memory, registers or breakpoints.
use std::{future::Future, time::Duration};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use crate::{IdeviceError, ReadWrite, RsdService, debug_proxy::DebugProxyClient,
            provider::RsdProvider, rsd::RsdHandshake};

const MAX_PACKET: usize = 8192;
const READ_CHUNK: usize = 1024;
fn target_allowed(pid: u32) -> bool { pid > 1 && pid != std::process::id() }
fn error(message: &str) -> IdeviceError {
    IdeviceError::UnexpectedResponse(format!("CallTap KeepAlive: {message}"))
}

#[derive(Clone, Copy)]
struct Timing { startup: Duration, poll: Duration, cleanup: Duration }
impl Default for Timing {
    fn default() -> Self {
        Self { startup: Duration::from_secs(10), poll: Duration::from_millis(500),
               cleanup: Duration::from_secs(3) }
    }
}

#[derive(Debug, PartialEq)]
enum Event { Ack, Nack, Packet(Vec<u8>) }

// Persistent buffering is important: cancelling an individual socket read must
// not discard the prefix of a fragmented packet. ACK mode validates checksums;
// Apple's debugserver deliberately emits #00 after no-ACK negotiation.
#[derive(Default)]
struct Framer { buffer: Vec<u8>, no_ack: bool }
impl Framer {
    fn feed(&mut self, bytes: &[u8]) -> Result<(), IdeviceError> {
        // One read may contain the end of a full-size packet and the beginning
        // of the next one. Enforce each payload's limit separately in next().
        if self.buffer.len() + bytes.len() > MAX_PACKET + 4 + READ_CHUNK {
            return Err(error("debugger packet exceeds limit"));
        }
        self.buffer.extend_from_slice(bytes);
        Ok(())
    }
    fn next(&mut self) -> Result<Option<Event>, IdeviceError> {
        let Some(first) = self.buffer.first().copied() else { return Ok(None); };
        if first == b'+' || first == b'-' {
            self.buffer.remove(0);
            return Ok(Some(if first == b'+' { Event::Ack } else { Event::Nack }));
        }
        if first != b'$' { return Err(error("invalid debugger framing")); }
        let mut escaped = false;
        let mut end = None;
        for (index, byte) in self.buffer.iter().enumerate().skip(1) {
            if escaped { escaped = false; continue; }
            if *byte == b'}' { escaped = true; continue; }
            if *byte == b'#' { end = Some(index); break; }
        }
        let Some(end) = end else {
            if self.buffer.len() > MAX_PACKET + 1 { return Err(error("debugger packet exceeds limit")); }
            return Ok(None);
        };
        if end > MAX_PACKET + 1 { return Err(error("debugger packet exceeds limit")); }
        if self.buffer.len() < end + 3 { return Ok(None); }
        let checksum = |byte: u8| (byte as char).to_digit(16).map(|n| n as u8);
        let Some(high) = checksum(self.buffer[end + 1]) else { return Err(error("invalid debugger checksum")); };
        let Some(low) = checksum(self.buffer[end + 2]) else { return Err(error("invalid debugger checksum")); };
        let actual = self.buffer[1..end].iter().fold(0u8, |sum, byte| sum.wrapping_add(*byte));
        if !self.no_ack && actual != high * 16 + low { return Err(error("debugger checksum mismatch")); }
        let payload = self.buffer[1..end].to_vec();
        self.buffer.drain(..end + 3);
        Ok(Some(Event::Packet(payload)))
    }
}

fn packet(payload: &[u8]) -> Vec<u8> {
    let sum = payload.iter().fold(0u8, |sum, byte| sum.wrapping_add(*byte));
    let mut result = Vec::with_capacity(payload.len() + 4);
    result.push(b'$'); result.extend_from_slice(payload);
    result.extend_from_slice(format!("#{sum:02x}").as_bytes());
    result
}
fn stop_reply(payload: &[u8]) -> bool {
    matches!(payload.first(), Some(b'T' | b'S')) && payload.len() >= 3
        && payload[1..3].iter().all(u8::is_ascii_hexdigit)
}
fn exited(payload: &[u8]) -> bool { matches!(payload.first(), Some(b'W' | b'X')) }
fn output(payload: &[u8]) -> bool {
    payload.first() == Some(&b'O') && payload.len() > 1 && payload.len() % 2 == 1
        && payload[1..].iter().all(u8::is_ascii_hexdigit)
}
fn matching_pid(payload: &[u8], expected: u32) -> bool {
    let Ok(text) = std::str::from_utf8(payload) else { return false; };
    let values: Vec<_> = text.split(';').filter_map(|field| field.strip_prefix("pid:")).collect();
    values.len() == 1 && !values[0].is_empty()
        && values[0].bytes().all(|byte| byte.is_ascii_hexdigit())
        && u32::from_str_radix(values[0], 16).ok() == Some(expected)
}

#[derive(Clone, Copy, PartialEq)]
enum Target { None, MayBeAttached, Stopped, Running }
struct Wire<R: ReadWrite> { socket: R, framer: Framer, target: Target, detach_on_error: bool }
impl<R: ReadWrite> Wire<R> {
    fn new(socket: R) -> Self {
        Self { socket, framer: Framer::default(), target: Target::None, detach_on_error: false }
    }
    async fn send(&mut self, payload: &[u8]) -> Result<(), IdeviceError> {
        self.socket.write_all(&packet(payload)).await?;
        self.socket.flush().await?;
        Ok(())
    }
    async fn event(&mut self) -> Result<Event, IdeviceError> {
        loop {
            if let Some(event) = self.framer.next()? { return Ok(event); }
            let mut bytes = [0u8; READ_CHUNK];
            let count = self.socket.read(&mut bytes).await?;
            if count == 0 { return Err(error("debugger connection closed")); }
            self.framer.feed(&bytes[..count])?;
        }
    }
    async fn reply(&mut self) -> Result<Vec<u8>, IdeviceError> {
        let mut acknowledged = self.framer.no_ack;
        loop {
            match self.event().await? {
                Event::Ack => acknowledged = true,
                Event::Nack => return Err(error("debugger rejected packet")),
                Event::Packet(payload) => {
                    if !acknowledged { return Err(error("debugger acknowledgement missing")); }
                    if !self.framer.no_ack {
                        self.socket.write_all(b"+").await?;
                        self.socket.flush().await?;
                    }
                    if output(&payload) { continue; }
                    return Ok(payload);
                }
            }
        }
    }
    async fn request(&mut self, payload: &[u8]) -> Result<Vec<u8>, IdeviceError> {
        self.send(payload).await?;
        self.reply().await
    }
    async fn handshake(&mut self, pid: u32) -> Result<(), IdeviceError> {
        if self.request(b"QStartNoAckMode").await? != b"OK" {
            return Err(error("no-ACK negotiation refused"));
        }
        self.framer.no_ack = true;
        if self.request(b"QSetDetachOnError:1").await? != b"OK" {
            return Err(error("safe detach-on-error unavailable"));
        }
        self.detach_on_error = true;
        self.target = Target::MayBeAttached; // Includes a partially sent attach.
        let attached = self.request(format!("vAttach;{pid:x}").as_bytes()).await?;
        if !stop_reply(&attached) { return Err(error("debugger attach refused")); }
        self.target = Target::Stopped;
        if !matching_pid(&self.request(b"qProcessInfo").await?, pid) {
            return Err(error("attached process identity mismatch"));
        }
        // Continue has no immediate reply in all-stop RSP. Waiting for one
        // would leave the startup operation pending until the next stop.
        self.send(b"c").await?;
        self.target = Target::Running;
        Ok(())
    }
    async fn observe(&mut self, callback: &impl Fn(u32) -> bool, poll: Duration) -> Result<(), IdeviceError> {
        if !callback(1) { return Ok(()); }
        let mut ticks = tokio::time::interval(poll);
        ticks.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
        loop {
            tokio::select! {
                _ = ticks.tick() => if !callback(0) { return Ok(()); },
                event = self.event() => match event? {
                    Event::Ack => {},
                    Event::Nack => return Err(error("debugger rejected packet")),
                    Event::Packet(payload) => {
                        if stop_reply(&payload) {
                            self.target = Target::Stopped;
                            return Err(error("debugged process stopped unexpectedly"));
                        }
                        if exited(&payload) {
                            self.target = Target::None;
                            return Err(error("debugged process exited"));
                        }
                        if !output(&payload) { return Err(error("unexpected debugger response")); }
                        // Native process output may contain private data. Drop it.
                    }
                }
            }
        }
    }
    async fn detach(&mut self) -> Result<(), IdeviceError> {
        if self.target == Target::None { return Ok(()); }
        if !self.detach_on_error { return Err(error("safe detach was not established")); }
        if self.target != Target::Stopped {
            // D and qProcessInfo do not have running-state async handlers in
            // Apple's debugserver. Interrupt first, then detach from the stop.
            self.socket.write_all(&[3]).await?;
            self.socket.flush().await?;
            loop {
                match self.event().await? {
                    Event::Ack => {},
                    Event::Packet(payload) if stop_reply(&payload) => {
                        self.target = Target::Stopped; break;
                    }
                    Event::Packet(payload) if exited(&payload) => {
                        self.target = Target::None; return Ok(());
                    }
                    Event::Packet(payload) if output(&payload) => {},
                    _ => return Err(error("debugger detach stop not confirmed")),
                }
            }
        }
        if self.request(b"D").await? != b"OK" { return Err(error("debugger detach refused")); }
        self.target = Target::None;
        Ok(())
    }
}

// Dropping an in-progress read leaves already received bytes in Wire::framer.
// The cancel callback is polled even during a slow connect or attach.
async fn controlled<T>(future: impl Future<Output = Result<T, IdeviceError>>,
                       callback: &impl Fn(u32) -> bool, end: tokio::time::Instant,
                       poll: Duration) -> Result<T, IdeviceError> {
    tokio::pin!(future);
    let mut ticks = tokio::time::interval(poll);
    ticks.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
    loop {
        tokio::select! {
            _ = ticks.tick() => if !callback(0) { return Err(error("connection cancelled")); },
            _ = tokio::time::sleep_until(end) => return Err(error("debugger startup timed out")),
            result = &mut future => return result,
        }
    }
}

async fn drive<R: ReadWrite>(socket: R, pid: u32, callback: impl Fn(u32) -> bool,
                            timing: Timing, deadline: tokio::time::Instant) -> Result<(), IdeviceError> {
    let mut wire = Wire::new(socket);
    let start = controlled(wire.handshake(pid), &callback, deadline, timing.poll).await;
    let result = match start { Ok(()) => wire.observe(&callback, timing.poll).await, Err(e) => Err(e) };
    let cleanup = if wire.target != Target::None {
        let _ = callback(2);
        match tokio::time::timeout(timing.cleanup, wire.detach()).await {
            Ok(result) => result,
            Err(_) => Err(error("debugger detach timed out")),
        }
    } else { Ok(()) };
    // If orderly detach failed, closing a session for which we established
    // QSetDetachOnError:1 asks debugserver to detach rather than kill the target.
    let _ = tokio::time::timeout(Duration::from_millis(250), wire.socket.shutdown()).await;
    result.and(cleanup)
}

/// Maintain a debugger connection to a DIFFERENT, trusted host/helper PID.
/// Events: 0 poll continuation, 1 continue sent, 2 cleanup (return ignored).
/// The callback must not reenter this runtime. Event 1 proves a connection was
/// established, not the target's trace state; the host verifies P_TRACED itself.
pub async fn maintain(provider: &mut impl RsdProvider, handshake: &mut RsdHandshake,
                      pid: u32, callback: impl Fn(u32) -> bool) -> Result<(), IdeviceError> {
    if !target_allowed(pid) { return Err(error("invalid or self target process")); }
    if !callback(0) { return Err(error("connection cancelled")); }
    let timing = Timing::default();
    let end = tokio::time::Instant::now() + timing.startup;
    let proxy = controlled(DebugProxyClient::connect_rsd(provider, handshake), &callback, end, timing.poll).await?;
    drive(proxy.into_inner(), pid, callback, timing, end).await
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{Arc, atomic::{AtomicBool, AtomicUsize, Ordering}};
    fn timing() -> Timing {
        Timing { startup: Duration::from_secs(1), poll: Duration::from_millis(5), cleanup: Duration::from_millis(150) }
    }
    async fn command(stream: &mut tokio::io::DuplexStream, expected: &[u8]) {
        let bytes = packet(expected);
        let mut received = vec![0; bytes.len()];
        stream.read_exact(&mut received).await.unwrap();
        assert_eq!(received, bytes);
    }
    async fn response(stream: &mut tokio::io::DuplexStream, payload: &[u8], no_ack: bool) {
        if !no_ack { stream.write_all(b"+").await.unwrap(); }
        let bytes = if no_ack {
            [b"$".as_slice(), payload, b"#00".as_slice()].concat()
        } else { packet(payload) };
        stream.write_all(&bytes).await.unwrap();
        if !no_ack { let mut ack = [0u8]; stream.read_exact(&mut ack).await.unwrap(); assert_eq!(ack, [b'+']); }
    }
    async fn start(stream: &mut tokio::io::DuplexStream, pid: u32) {
        command(stream, b"QStartNoAckMode").await; response(stream, b"OK", false).await;
        command(stream, b"QSetDetachOnError:1").await; response(stream, b"OK", true).await;
        command(stream, format!("vAttach;{pid:x}").as_bytes()).await; response(stream, b"T05thread:1;", true).await;
        command(stream, b"qProcessInfo").await; response(stream, format!("pid:{pid:x};cputype:100000c;").as_bytes(), true).await;
        command(stream, b"c").await;
    }
    async fn finish(stream: &mut tokio::io::DuplexStream) {
        let mut interrupt = [0u8]; stream.read_exact(&mut interrupt).await.unwrap(); assert_eq!(interrupt, [3]);
        response(stream, b"T02thread:1;", true).await;
        command(stream, b"D").await; response(stream, b"OK", true).await;
    }
    #[test]
    fn parser_retains_fragmented_packets_and_coalesced_ack() {
        let mut parser = Framer::default();
        parser.feed(b"+$O").unwrap(); assert_eq!(parser.next().unwrap(), Some(Event::Ack));
        assert_eq!(parser.next().unwrap(), None);
        parser.feed(b"K#9").unwrap(); assert_eq!(parser.next().unwrap(), None);
        parser.feed(b"a").unwrap(); assert_eq!(parser.next().unwrap(), Some(Event::Packet(b"OK".to_vec())));
    }
    #[test]
    fn parser_rejects_corrupt_ack_mode_checksum() {
        let mut parser = Framer::default(); parser.feed(b"$OK#00").unwrap(); assert!(parser.next().is_err());
    }
    #[test]
    fn parser_accepts_apples_no_ack_zero_checksum() {
        let mut parser = Framer { no_ack: true, ..Framer::default() };
        parser.feed(b"$OK#00").unwrap(); assert_eq!(parser.next().unwrap(), Some(Event::Packet(b"OK".to_vec())));
    }
    #[test]
    fn parser_bounds_incomplete_packet() {
        let mut parser = Framer::default();
        parser.feed(&[b"$".as_slice(), &vec![b'a'; MAX_PACKET + 1]].concat()).unwrap();
        assert!(parser.next().is_err());
    }
    #[test]
    fn identity_requires_one_exact_hex_pid() {
        assert!(matching_pid(b"pid:1234;cputype:100000c;", 0x1234));
        for reply in [b"pid:1235;".as_slice(), b"pid:1234;pid:1234;", b"pid:;", b"pid:+1234;", b"parent-pid:1234;"] {
            assert!(!matching_pid(reply, 0x1234));
        }
    }
    #[test]
    fn target_must_be_a_different_non_system_process() {
        assert!(!target_allowed(0)); assert!(!target_allowed(1));
        assert!(!target_allowed(std::process::id()));
        assert!(target_allowed(if std::process::id() == 42 {43} else {42}));
    }
    #[tokio::test]
    async fn cancel_after_ready_interrupts_then_detaches_without_kill() {
        let (client, mut server) = tokio::io::duplex(16384);
        let ready = Arc::new(AtomicBool::new(false)); let flag = ready.clone();
        let cleanup = Arc::new(AtomicUsize::new(0)); let count = cleanup.clone();
        let peer = tokio::spawn(async move { start(&mut server, 0x1234).await; finish(&mut server).await; });
        let result = drive(client, 0x1234, move |event| {
            if event == 1 { flag.store(true, Ordering::SeqCst); }
            if event == 2 { count.fetch_add(1, Ordering::SeqCst); }
            !flag.load(Ordering::SeqCst)
        }, timing(), tokio::time::Instant::now() + timing().startup).await;
        assert!(result.is_ok()); assert!(ready.load(Ordering::SeqCst));
        assert_eq!(cleanup.load(Ordering::SeqCst), 1); peer.await.unwrap();
    }
    #[tokio::test]
    async fn detach_safety_refusal_never_attaches() {
        let (client, mut server) = tokio::io::duplex(16384);
        let peer = tokio::spawn(async move {
            command(&mut server, b"QStartNoAckMode").await; response(&mut server, b"OK", false).await;
            command(&mut server, b"QSetDetachOnError:1").await; response(&mut server, b"E01", true).await;
            let mut tail = Vec::new(); server.read_to_end(&mut tail).await.unwrap(); assert!(tail.is_empty());
        });
        assert!(drive(client, 0x1234, |_| true, timing(), tokio::time::Instant::now() + timing().startup).await.is_err());
        peer.await.unwrap();
    }
    #[tokio::test]
    async fn mismatched_target_is_detached_before_continue() {
        let (client, mut server) = tokio::io::duplex(16384);
        let peer = tokio::spawn(async move {
            command(&mut server, b"QStartNoAckMode").await; response(&mut server, b"OK", false).await;
            command(&mut server, b"QSetDetachOnError:1").await; response(&mut server, b"OK", true).await;
            command(&mut server, b"vAttach;1234").await; response(&mut server, b"T05", true).await;
            command(&mut server, b"qProcessInfo").await; response(&mut server, b"pid:1235;", true).await;
            command(&mut server, b"D").await; response(&mut server, b"OK", true).await;
        });
        let ready = Arc::new(AtomicBool::new(false)); let flag = ready.clone();
        assert!(drive(client, 0x1234, move |event| { if event == 1 {flag.store(true, Ordering::SeqCst);} true }, timing(), tokio::time::Instant::now() + timing().startup).await.is_err());
        assert!(!ready.load(Ordering::SeqCst)); peer.await.unwrap();
    }
    #[tokio::test]
    async fn unexpected_stop_detaches_without_resuming_it() {
        let (client, mut server) = tokio::io::duplex(16384);
        let peer = tokio::spawn(async move {
            start(&mut server, 0x1234).await; response(&mut server, b"T0bthread:1;", true).await;
            command(&mut server, b"D").await; response(&mut server, b"OK", true).await;
        });
        assert!(drive(client, 0x1234, |_| true, timing(), tokio::time::Instant::now() + timing().startup).await.is_err());
        peer.await.unwrap();
    }
    #[tokio::test]
    async fn eof_is_failure_after_ready() {
        let (client, mut server) = tokio::io::duplex(16384);
        let peer = tokio::spawn(async move { start(&mut server, 0x1234).await; });
        let ready = Arc::new(AtomicBool::new(false)); let flag = ready.clone();
        assert!(drive(client, 0x1234, move |event| {if event == 1 {flag.store(true, Ordering::SeqCst);} true}, timing(), tokio::time::Instant::now() + timing().startup).await.is_err());
        assert!(ready.load(Ordering::SeqCst)); peer.await.unwrap();
    }
    #[tokio::test]
    async fn stalled_handshake_is_bounded_without_attach() {
        let (client, mut server) = tokio::io::duplex(16384);
        let peer = tokio::spawn(async move {
            command(&mut server, b"QStartNoAckMode").await;
            let mut tail = Vec::new(); server.read_to_end(&mut tail).await.unwrap(); assert!(tail.is_empty());
        });
        assert!(drive(client, 0x1234, |_| true, timing(), tokio::time::Instant::now() + Duration::from_millis(20)).await.is_err());
        peer.await.unwrap();
    }
    #[tokio::test]
    async fn cancellation_is_polled_during_a_stalled_handshake() {
        let (client, mut server) = tokio::io::duplex(16384);
        let enabled = Arc::new(AtomicBool::new(true)); let flag = enabled.clone();
        let peer = tokio::spawn(async move {
            command(&mut server, b"QStartNoAckMode").await;
            enabled.store(false, Ordering::SeqCst);
            let mut tail = Vec::new(); server.read_to_end(&mut tail).await.unwrap(); assert!(tail.is_empty());
        });
        assert!(drive(client, 0x1234, move |_| flag.load(Ordering::SeqCst), timing(), tokio::time::Instant::now() + timing().startup).await.is_err());
        peer.await.unwrap();
    }
    #[tokio::test]
    async fn unresponsive_detach_is_bounded_and_connection_is_closed() {
        let (client, mut server) = tokio::io::duplex(16384);
        let ready = Arc::new(AtomicBool::new(false)); let flag = ready.clone();
        let peer = tokio::spawn(async move {
            start(&mut server, 0x1234).await;
            let mut interrupt = [0u8]; server.read_exact(&mut interrupt).await.unwrap(); assert_eq!(interrupt, [3]);
            let mut tail = Vec::new(); server.read_to_end(&mut tail).await.unwrap(); assert!(tail.is_empty());
        });
        let result = tokio::time::timeout(Duration::from_secs(1), drive(client, 0x1234, move |event| {
            if event == 1 { flag.store(true, Ordering::SeqCst); }
            !flag.load(Ordering::SeqCst)
        }, timing(), tokio::time::Instant::now() + timing().startup)).await;
        assert!(result.unwrap().is_err()); peer.await.unwrap();
    }
}
