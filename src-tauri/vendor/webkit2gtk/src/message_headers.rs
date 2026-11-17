//! Minimal stand-in for libsoup's `MessageHeaders`.
//!
//! WebKitGTK 4.1 hands request headers back as a libsoup3 `SoupMessageHeaders`.
//! The 4.0 bindings this crate was generated against exposed that object through
//! the soup2 crate, which cannot be loaded into the same process as libsoup3.
//! wry only ever calls `append`, so this wrapper keeps the same call shape and
//! forwards to libsoup3's own C function on the very same object.

use std::ffi::{c_char, c_void, CString};

#[link(name = "soup-3.0")]
extern "C" {
    fn soup_message_headers_append(headers: *mut c_void, name: *const c_char, value: *const c_char);
}

#[derive(Debug)]
pub struct MessageHeaders(*mut c_void);

unsafe impl Send for MessageHeaders {}
unsafe impl Sync for MessageHeaders {}

impl MessageHeaders {
    pub(crate) unsafe fn from_ptr(ptr: *mut c_void) -> Option<Self> {
        (!ptr.is_null()).then_some(MessageHeaders(ptr))
    }

    pub fn append(&self, name: &str, value: &str) {
        if let (Ok(name), Ok(value)) = (CString::new(name), CString::new(value)) {
            unsafe { soup_message_headers_append(self.0, name.as_ptr(), value.as_ptr()) }
        }
    }
}
