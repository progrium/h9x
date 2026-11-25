//! The Debian-to-Wolfi package table: the plan's apt packages as Wolfi
//! package names, or alternatives (`a|b|c`) for roots.sh to try.
//!
//! Owned by W2.

const std = @import("std");
