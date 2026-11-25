//! Roots (design/prototype.md, "The build engine"): the bootstrap (Alpine's
//! minirootfs and Railpack, pinned by version and sha256), and the base and
//! builder roots, made by the embedded roots.sh in a machine on the Alpine
//! root, keyed by architecture, repository, and package set.
//!
//! Owned by W7. Every root gets `/app` and the mount points the guest
//! scripts' trees need, `/h9x/{src,tools,guest,railpack,ca}`.

const std = @import("std");
const types = @import("types.zig");
