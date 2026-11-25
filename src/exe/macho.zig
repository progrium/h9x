//! macOS executables: the archive in a `__H9X,__pack` section of its own
//! segment, before `__LINKEDIT`, then the trailer.
//!
//! Owned by W4. Treats the archive as opaque bytes.

const std = @import("std");
