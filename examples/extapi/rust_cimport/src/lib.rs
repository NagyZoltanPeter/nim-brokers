//! EXTAPI example — scenario 4: a plain C-ABI library in Rust, imported by the
//! Nim host function by function. No broker or EXTAPI dependency.

use std::time::Duration;

/// # Safety
/// `buf` must point to `len` readable bytes (or `len == 0`).
#[no_mangle]
pub unsafe extern "C" fn codec_crc(seed: u32, buf: *const u8, len: u32) -> u32 {
    let data: &[u8] = if buf.is_null() || len == 0 { &[] } else { std::slice::from_raw_parts(buf, len as usize) };
    data.iter().fold(seed, |h, &b| h.wrapping_mul(31).wrapping_add(b as u32))
}

/// Blocking on purpose: sleeps `ms`, then sums the bytes. 0 = ok.
///
/// # Safety
/// `src` must point to `len` readable bytes (or `len == 0`); `out` must be valid.
#[no_mangle]
pub unsafe extern "C" fn codec_slow_sum(src: *const u8, len: u32, ms: u32, out: *mut u64) -> i32 {
    if out.is_null() {
        return -1;
    }
    std::thread::sleep(Duration::from_millis(ms as u64));
    let data: &[u8] = if src.is_null() || len == 0 { &[] } else { std::slice::from_raw_parts(src, len as usize) };
    *out = data.iter().map(|&b| b as u64).sum();
    0
}
