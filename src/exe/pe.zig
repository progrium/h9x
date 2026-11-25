//! Windows executables: the archive in a `.h9x` section, before any
//! certificate, then the trailer.
//!
//! Owned by W4. Treats the archive as opaque bytes.

const std = @import("std");
