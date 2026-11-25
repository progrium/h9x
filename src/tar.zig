//! Deterministic tar writing (design/prototype.md, "Packs"): entries sorted
//! by path, mtimes 0, uid and gid 0, no host names, so the same tree makes
//! the same bytes; and flattening layers with their whiteouts applied.
//!
//! Owned by W3.

const std = @import("std");
