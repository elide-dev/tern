//! Private C ABI. Loaded only by the disposable worker, never by the UI process.
use libloading::Library;
use std::{
    ffi::{c_char, c_void, CString},
    path::Path,
    ptr,
};

#[repr(C)]
#[derive(Default)]
struct Buffer {
    data: *mut u8,
    size: u64,
}

#[repr(C)]
#[derive(Default)]
struct Api {
    struct_size: u32,
    major: u32,
    minor: u32,
    reserved: u32,
    build_info: Option<unsafe extern "C" fn() -> *const c_void>,
    capability: Option<unsafe extern "C" fn(u32) -> u32>,
    open: Option<unsafe extern "C" fn(*const c_char, *mut *mut c_void) -> u32>,
    exchange: Option<unsafe extern "C" fn(*mut c_void, *const u8, u64, *mut Buffer) -> u32>,
    close: Option<unsafe extern "C" fn(*mut c_void) -> u32>,
    release: Option<unsafe extern "C" fn(*mut Buffer)>,
}

pub struct Session {
    api: Api,
    session: *mut c_void,
}
impl Session {
    pub fn open(home: &Path) -> Result<Self, String> {
        let (facade, backend) = if cfg!(all(target_os = "macos", target_arch = "aarch64")) {
            ("lib/libelide_embed.dylib", "lib/libelideengine.dylib")
        } else if cfg!(all(target_os = "linux", target_arch = "x86_64")) {
            ("lib/libelide_embed.so", "lib/elide.so")
        } else {
            return Err("Embedded SDK supports macOS arm64 and Linux amd64 only".into());
        };
        let home = home.canonicalize().map_err(|e| e.to_string())?;
        let backend = home.join(backend);
        let backend = CString::new(backend.to_str().ok_or("SDK path must be UTF-8")?)
            .map_err(|e| e.to_string())?;
        // The absolute facade path is selected by the host, never by a guest request.
        #[cfg(unix)]
        let library: Library = unsafe {
            libloading::os::unix::Library::open(
                Some(home.join(facade)),
                libloading::os::unix::RTLD_NOW | libloading::os::unix::RTLD_LOCAL,
            )
        }
        .map_err(|e| e.to_string())?
        .into();
        #[cfg(not(unix))]
        let library = unsafe { Library::new(home.join(facade)) }.map_err(|e| e.to_string())?;
        let mut api = Api::default();
        let status = unsafe {
            let get = library
                .get::<unsafe extern "C" fn(u32, u32, u32, *mut Api) -> u32>(b"elide_get_api\0")
                .map_err(|e| e.to_string())?;
            get(1, 1, size_of::<Api>() as u32, &mut api)
        };
        if status != 0
            || api.struct_size < size_of::<Api>() as u32
            || api.major != 1
            || api.minor < 1
            || api.open.is_none()
            || api.exchange.is_none()
            || api.close.is_none()
            || api.release.is_none()
        {
            return Err(format!("Incompatible Elide embedding ABI ({status})"));
        }
        // Opening initializes process-lifetime runtime state, even on a failed open.
        // Intentionally retain the library until the worker process terminates.
        std::mem::forget(library);
        let mut session = ptr::null_mut();
        let status = unsafe { api.open.unwrap()(backend.as_ptr(), &mut session) };
        if status != 0 || session.is_null() {
            return Err(format!("Elide session open failed ({status})"));
        }
        Ok(Self { api, session })
    }

    pub fn exchange(&mut self, request: &[u8]) -> Result<Vec<u8>, String> {
        if request.is_empty() || request.len() > crate::MAX_REQUEST {
            return Err("Invalid request size".into());
        }
        let mut response = Buffer::default();
        let status = unsafe {
            self.api.exchange.unwrap()(
                self.session,
                request.as_ptr(),
                request.len() as u64,
                &mut response,
            )
        };
        if status != 0 {
            return Err(format!("Elide transport failed ({status})"));
        }
        let result = if response.data.is_null()
            || response.size == 0
            || response.size > crate::MAX_RESPONSE as u64
        {
            Err("Invalid Elide response buffer".into())
        } else {
            Ok(
                unsafe { std::slice::from_raw_parts(response.data, response.size as usize) }
                    .to_vec(),
            )
        };
        unsafe { self.api.release.unwrap()(&mut response) };
        result
    }
}
impl Drop for Session {
    fn drop(&mut self) {
        unsafe { self.api.close.unwrap()(self.session) };
    }
}
