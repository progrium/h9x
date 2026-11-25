//! Ad-hoc signing of macOS executables with the
//! `com.apple.security.hypervisor` entitlement, from any host: a port of
//! the ad-hoc signer in Zig's Mach-O linker.
//!
//! Owned by W4.

const std = @import("std");
