use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::path::Path;
use voanisa_core::{probe_path, ProbeResult};

const VERSION: &str = concat!(env!("CARGO_PKG_VERSION"), "\0");

/// Returns a static NUL-terminated version string. Do not free it.
#[no_mangle]
pub extern "C" fn voanisa_core_version() -> *const c_char {
    VERSION.as_ptr() as *const c_char
}

/// Returns a heap-allocated JSON probe result. Free it with
/// `voanisa_string_free`.
#[no_mangle]
pub extern "C" fn voanisa_probe_json(path: *const c_char) -> *mut c_char {
    if path.is_null() {
        return to_c_string(error_json("null path"));
    }

    let path = unsafe { CStr::from_ptr(path) }
        .to_string_lossy()
        .into_owned();

    let result = catch_unwind(AssertUnwindSafe(|| probe_path(Path::new(&path))));
    let json = match result {
        Ok(Ok(probe)) => serde_json::to_string(&probe)
            .unwrap_or_else(|error| error_json(&error.to_string())),
        Ok(Err(error)) => error_json(&error),
        Err(_) => error_json("panic in Rust core"),
    };
    to_c_string(json)
}

#[no_mangle]
pub extern "C" fn voanisa_string_free(value: *mut c_char) {
    if !value.is_null() {
        unsafe {
            drop(CString::from_raw(value));
        }
    }
}

fn error_json(message: &str) -> String {
    serde_json::to_string(&ProbeResult {
        container: "unknown".to_string(),
        codec: None,
        recognized: false,
        error: Some(message.to_string()),
    })
    .unwrap_or_else(|_| {
        "{\"container\":\"unknown\",\"codec\":null,\"recognized\":false,\"error\":\"unknown\"}"
            .to_string()
    })
}

fn to_c_string(json: String) -> *mut c_char {
    CString::new(json)
        .unwrap_or_else(|_| {
            CString::new(
                "{\"container\":\"unknown\",\"codec\":null,\"recognized\":false,\"error\":\"nul byte\"}",
            )
            .expect("static JSON has no NUL")
        })
        .into_raw()
}
