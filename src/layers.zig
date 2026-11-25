//! Layers (design/prototype.md, "The build engine"): building the runtime,
//! deps, and app layers with the embedded build.sh, each as an up layer
//! over the builder root and the layers below, the shared runtime layer,
//! pruning, and `layers.txt`.
//!
//! Owned by W7, which also wires `h9x build` end to end (cmd/build.zig).

const std = @import("std");
const types = @import("types.zig");
