//! The pack index: the tar's last entry, `/.h9x/index`, listing each
//! file's path, offset, and size.
//!
//! Owned by W3.

const std = @import("std");
