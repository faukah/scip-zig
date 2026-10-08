// SPDX-License-Identifier: EUPL-1.2
//! the few std APIs that differ between the zig releases we build with.
//! untaken branches are never analyzed, so each one only has to compile
//! under the version it is written for.

const std = @import("std");
const builtin = @import("builtin");
const Ast = std.zig.Ast;
const Allocator = std.mem.Allocator;

pub const at_least_0_17 = builtin.zig_version.order(.{ .major = 0, .minor = 17, .patch = 0 }) != .lt;

pub fn parse(gpa: Allocator, source: [:0]const u8, mode: Ast.Mode) Allocator.Error!Ast {
    if (at_least_0_17) return Ast.parse(gpa, source, .{ .mode = mode });
    return Ast.parse(gpa, source, mode);
}
