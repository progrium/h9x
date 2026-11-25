//! OCI image layouts and `docker save` tarballs (design/prototype.md,
//! "Export"): the base root and each run layer as gzipped deterministic
//! tars, and the config's architecture, Env, WorkingDir, and Cmd.
//!
//! Owned by W3; `h9x export`'s wiring (cmd/export.zig) is W9's.

const std = @import("std");
const types = @import("types.zig");
