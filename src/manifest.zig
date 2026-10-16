// SPDX-License-Identifier: EUPL-1.2
//! reads the parts of build.zig.zon scip-zig needs: the package's name and
//! version, and where each of its dependencies lives

const std = @import("std");
const Ast = std.zig.Ast;
const Node = Ast.Node;
const Allocator = std.mem.Allocator;
const Io = std.Io;

const compat = @import("compat.zig");

pub const Manifest = struct {
    name: ?[]const u8 = null,
    version: ?[]const u8 = null,
    dependencies: []const Dependency = &.{},
};

pub const Dependency = struct {
    name: []const u8,
    location: Location,

    pub const Location = union(enum) {
        /// fetched, unpacked under `zig-pkg/<hash>` of the root package
        hash: []const u8,
        /// relative to the package declaring it
        path: []const u8,
    };
};

/// `root`/build.zig.zon, empty without a readable one
pub fn read(arena: Allocator, io: Io, root: []const u8) Manifest {
    const path = std.fs.path.join(arena, &.{ root, "build.zig.zon" }) catch return .{};
    const source = Io.Dir.cwd().readFileAllocOptions(io, path, arena, .limited(1 << 20), .of(u8), 0) catch return .{};
    const tree = compat.parse(arena, source, .zon) catch return .{};
    if (tree.errors.len > 0) return .{};

    var manifest: Manifest = .{};
    const top = tree.nodeData(.root).node;
    var buf: [2]Node.Index = undefined;
    const init = tree.fullStructInit(&buf, top) orelse return .{};
    for (init.ast.fields) |value| {
        const field = fieldName(&tree, value);
        if (std.mem.eql(u8, field, "name")) {
            manifest.name = switch (tree.nodeTag(value)) {
                .enum_literal => identifier(tree.tokenSlice(tree.nodeMainToken(value))),
                else => string(&tree, value),
            };
        } else if (std.mem.eql(u8, field, "version")) {
            manifest.version = string(&tree, value);
        } else if (std.mem.eql(u8, field, "dependencies")) {
            manifest.dependencies = dependencies(arena, &tree, value) catch &.{};
        }
    }
    return manifest;
}

fn dependencies(arena: Allocator, tree: *const Ast, node: Node.Index) Allocator.Error![]const Dependency {
    var buf: [2]Node.Index = undefined;
    const init = tree.fullStructInit(&buf, node) orelse return &.{};
    var out: std.ArrayList(Dependency) = .empty;
    for (init.ast.fields) |value| {
        var dep_buf: [2]Node.Index = undefined;
        const dep = tree.fullStructInit(&dep_buf, value) orelse continue;
        var location: ?Dependency.Location = null;
        for (dep.ast.fields) |dep_value| {
            const field = fieldName(tree, dep_value);
            const text = string(tree, dep_value) orelse continue;
            if (std.mem.eql(u8, field, "hash")) {
                location = .{ .hash = text };
            } else if (std.mem.eql(u8, field, "path")) {
                location = .{ .path = text };
            }
        }
        try out.append(arena, .{ .name = fieldName(tree, value), .location = location orelse continue });
    }
    return out.items;
}

/// `.name = value`, the name sits two tokens before its value
fn fieldName(tree: *const Ast, value: Node.Index) []const u8 {
    return identifier(tree.tokenSlice(tree.firstToken(value) - 2));
}

fn identifier(slice: []const u8) []const u8 {
    if (std.mem.startsWith(u8, slice, "@\"") and slice.len >= 3) return slice[2 .. slice.len - 1];
    return slice;
}

/// contents of a plain string literal node
fn string(tree: *const Ast, node: Node.Index) ?[]const u8 {
    if (tree.nodeTag(node) != .string_literal) return null;
    const literal = tree.tokenSlice(tree.nodeMainToken(node));
    if (literal.len < 2) return null;
    return literal[1 .. literal.len - 1];
}
