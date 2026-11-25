//! Linux executables: the archive appended after the runner's ELF image,
//! then the trailer.
//!
//! Owned by W4. Treats the archive as opaque bytes.

const std = @import("std");
