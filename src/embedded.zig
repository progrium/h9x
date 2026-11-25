//! Files built into the `h9x` binary: the guest scripts, mounted into
//! build machines from memory, and the host's runner, which `pack --exe`
//! joins to a pack.

/// build.sh LAYER: builds one layer from the plan's steps for it.
pub const build_sh = @embedFile("build_sh");
/// roots.sh ARCH REPO PACKAGES...: installs Wolfi packages into a root.
pub const roots_sh = @embedFile("roots_sh");
/// The host target's h9x-runner, as built alongside h9x.
pub const runner = @embedFile("h9x_runner");

test {
    const std = @import("std");
    try std.testing.expect(std.mem.startsWith(u8, build_sh, "#!/bin/sh"));
    try std.testing.expect(std.mem.startsWith(u8, roots_sh, "#!/bin/sh"));
    try std.testing.expect(runner.len > 0);
}
