//! C ABI. Calls for one handle are serialized by the Swift main thread.
use std::ffi::{CStr, c_char};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::path::Path;
use std::ptr;
use std::time::{Duration, Instant};

use crate::{frames::SpriteFrames, model::Pet, runtime::PetRuntime};

pub struct EchoRuntime {
    runtime: PetRuntime,
    frames: SpriteFrames,
    clock: Instant,
}

#[repr(C)]
pub struct EchoInfo {
    pub width: u32,
    pub height: u32,
    pub frame_count: u32,
}

#[repr(C)]
pub struct EchoFrame {
    pub data: *const u8,
    pub length: usize,
}

#[repr(C)]
pub struct EchoTick {
    pub sprite_index: u32,
    /// Zero means the image is static and no next timer is needed.
    pub next_frame_seconds: f64,
}

unsafe fn write_error(buffer: *mut c_char, capacity: usize, error: &str) {
    if buffer.is_null() || capacity == 0 {
        return;
    }
    let length = error.floor_char_boundary(capacity - 1);
    unsafe {
        ptr::copy_nonoverlapping(error.as_ptr(), buffer.cast(), length);
        *buffer.add(length) = 0;
    }
}

/// Load a pet directory. Errors are copied into the caller's UTF-8 buffer.
/// # Safety
/// `directory` must be a NUL-terminated string; `error` must be writable for
/// `capacity` bytes (or null). Destroy the returned handle exactly once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn echo_create(
    directory: *const c_char,
    error: *mut c_char,
    capacity: usize,
) -> *mut EchoRuntime {
    unsafe {
        write_error(error, capacity, "");
    }
    let result = catch_unwind(|| -> anyhow::Result<EchoRuntime> {
        anyhow::ensure!(!directory.is_null(), "missing pet directory");
        let directory = unsafe { CStr::from_ptr(directory) }.to_str()?;
        let pet = Pet::load(Path::new(directory))?;
        let frames = SpriteFrames::load(&pet)?;
        let runtime = PetRuntime::new(pet)?;
        Ok(EchoRuntime {
            runtime,
            frames,
            clock: Instant::now(),
        })
    });
    let message = match result {
        Ok(Ok(runtime)) => return Box::into_raw(Box::new(runtime)),
        Ok(Err(cause)) => format!("{cause:#}"),
        Err(_) => "Rust runtime initialization panicked".into(),
    };
    unsafe {
        write_error(error, capacity, &message);
    }
    ptr::null_mut()
}

/// Release a runtime and all borrowed frame buffers. Null is a no-op.
/// # Safety
/// `handle` must be null or a live handle returned by echo_create, used once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn echo_destroy(handle: *mut EchoRuntime) {
    if !handle.is_null() {
        drop(unsafe { Box::from_raw(handle) });
    }
}

/// Read the sprite dimensions and count.
/// # Safety
/// The non-null pointers must reference a live handle and writable output.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn echo_info(handle: *const EchoRuntime, out: *mut EchoInfo) -> bool {
    let (Some(handle), Some(out)) = (unsafe { handle.as_ref() }, unsafe { out.as_mut() }) else {
        return false;
    };
    *out = EchoInfo {
        width: handle.frames.width,
        height: handle.frames.height,
        frame_count: handle.frames.len() as u32,
    };
    true
}

/// Borrow immutable, top-to-bottom, straight-alpha RGBA8 frame bytes.
/// # Safety
/// Pointers must be live. The returned bytes remain valid until destroy;
/// copy them into Swift-owned storage before releasing the handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn echo_frame(
    handle: *const EchoRuntime,
    index: u32,
    out: *mut EchoFrame,
) -> bool {
    let (Some(handle), Some(out)) = (unsafe { handle.as_ref() }, unsafe { out.as_mut() }) else {
        return false;
    };
    let frame = handle.frames.get(index as usize);
    *out = frame.map_or(
        EchoFrame {
            data: ptr::null(),
            length: 0,
        },
        |frame| EchoFrame {
            data: frame.as_ptr(),
            length: frame.len(),
        },
    );
    frame.is_some()
}

/// Runs `change` on a live handle at the runtime's current time; a null handle, an error or a
/// panic is false.
unsafe fn drive(
    handle: *mut EchoRuntime,
    change: impl FnOnce(&mut PetRuntime, Duration) -> anyhow::Result<()>,
) -> bool {
    let Some(handle) = (unsafe { handle.as_mut() }) else {
        return false;
    };
    catch_unwind(AssertUnwindSafe(|| {
        change(&mut handle.runtime, handle.clock.elapsed()).is_ok()
    }))
    .unwrap_or(false)
}

/// `drive` with a NUL-terminated UTF-8 animation name; a null or non-UTF-8 name is false.
unsafe fn drive_named(
    handle: *mut EchoRuntime,
    name: *const c_char,
    change: impl FnOnce(&mut PetRuntime, &str, Duration) -> anyhow::Result<()>,
) -> bool {
    if name.is_null() {
        return false;
    }
    unsafe {
        drive(handle, |runtime, now| {
            change(runtime, CStr::from_ptr(name).to_str()?, now)
        })
    }
}

/// Set the pet's state animation. It restarts at the runtime's current monotonic time, or when it
/// first shows if a drag, a one-shot or the hover jump covers it now.
/// # Safety
/// `handle` must be live, and `name` a NUL-terminated UTF-8 string.
/// Do not call concurrently with another operation on this handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn echo_set_animation(handle: *mut EchoRuntime, name: *const c_char) -> bool {
    unsafe { drive_named(handle, name, PetRuntime::set_animation) }
}

/// Play a named animation once over the pet's state, as a click's wave does: the part before
/// its loop. Hovering and the pointer cannot cut it short; a drag ends it.
/// # Safety
/// `handle` must be live, and `name` a NUL-terminated UTF-8 string.
/// Do not call concurrently with another operation on this handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn echo_play_once(handle: *mut EchoRuntime, name: *const c_char) -> bool {
    unsafe { drive_named(handle, name, PetRuntime::play_once) }
}

/// Update hover and drag direction (-1 left, 0 released, 1 right).
/// # Safety
/// The handle must be live and accessed serially.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn echo_set_interaction(
    handle: *mut EchoRuntime,
    hovered: bool,
    direction: i32,
) -> bool {
    unsafe {
        drive(handle, |runtime, now| {
            runtime.set_interaction(hovered, direction, now)
        })
    }
}

/// Set a pointer offset from the pet center, with positive Y pointing down. A changed offset is
/// the pointer moving: an idle pet faces it until it has been still for two seconds.
/// # Safety
/// The handle must be live and accessed serially.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn echo_look_at(handle: *mut EchoRuntime, dx: f64, dy: f64) -> bool {
    unsafe { drive(handle, |runtime, now| runtime.look_at(dx, dy, now)) }
}

/// Advance animation and return the visible sprite and next wake-up delay.
/// # Safety
/// Pointers must reference a live handle and writable output. Calls for this
/// handle must be serialized, including set_animation and destroy.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn echo_tick(handle: *mut EchoRuntime, out: *mut EchoTick) -> bool {
    if handle.is_null() || out.is_null() {
        return false;
    }
    catch_unwind(AssertUnwindSafe(|| {
        let handle = unsafe { &mut *handle };
        let tick = handle.runtime.advance(handle.clock.elapsed());
        unsafe {
            *out = EchoTick {
                sprite_index: tick.sprite_index as u32,
                next_frame_seconds: tick.next_frame_in.map_or(0.0, |delay| delay.as_secs_f64()),
            };
        }
        true
    }))
    .unwrap_or(false)
}
