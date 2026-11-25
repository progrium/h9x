//! The subset of TOML `h9x.toml` needs: tables, strings, integers,
//! booleans, arrays of strings, and multi-line basic strings. Anything else
//! is a config error with its line (exit 2).
//!
//! Owned by W1.

const std = @import("std");
