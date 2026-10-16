// SPDX-License-Identifier: EUPL-1.2
//! finds the named modules a project's build.zig declares, without running
//! it: `b.addModule("name", ...)`, `.addImport("name", module)` and
//! `.imports = &.{ .{ .name = "name", .module = module } }`, where a module
//! is a `b.addModule`/`b.createModule` call with a `b.path(...)` root source
//! file, or a constant holding one. modules of dependencies are
//! `b.dependency("dep", ...).module("name")`, or a constant holding the
//! dependency. the std.Build API differs between zig releases and running
//! build.zig needs a build runner per release, while these few calls have
//! stayed put.

const std = @import("std");
const Ast = std.zig.Ast;
const Node = Ast.Node;
const Allocator = std.mem.Allocator;
const Io = std.Io;

const compat = @import("compat.zig");

pub const Module = struct {
    name: []const u8,
    source: Source,
    /// declared with `b.addModule`, so dependents can import it
    exported: bool,
};

pub const Source = union(enum) {
    /// absolute root source file
    file: []const u8,
    /// a module exported by a dependency of the package
    dependency: struct { dependency: []const u8, module: []const u8 },
};

const Scan = struct {
    arena: Allocator,
    tree: Ast,
    root: []const u8,
    /// constants holding a module, by name
    variables: std.StringHashMapUnmanaged(Source) = .empty,
    /// constants holding `b.dependency(name, ...)`, to the name
    dependencies: std.StringHashMapUnmanaged([]const u8) = .empty,
    modules: std.StringArrayHashMapUnmanaged(Entry) = .empty,

    const Entry = struct { source: Source, exported: bool };

    fn name(s: *const Scan, token: Ast.TokenIndex) []const u8 {
        return s.tree.tokenSlice(token);
    }

    /// contents of a plain string literal node
    fn string(s: *const Scan, node: Node.Index) ?[]const u8 {
        if (s.tree.nodeTag(node) != .string_literal) return null;
        const literal = s.tree.tokenSlice(s.tree.nodeMainToken(node));
        if (literal.len < 2) return null;
        return literal[1 .. literal.len - 1];
    }

    /// `receiver.method(...)` called as `method`
    fn calledMethod(s: *const Scan, node: Node.Index, buf: *[1]Node.Index) ?struct { []const u8, []const Node.Index } {
        const call = s.tree.fullCall(buf, node) orelse return null;
        if (s.tree.nodeTag(call.ast.fn_expr) != .field_access) return null;
        const method = s.tree.nodeData(call.ast.fn_expr).node_and_token[1];
        return .{ s.name(method), call.ast.params };
    }

    /// the value of `.field = value` in an anonymous struct init
    fn field(s: *const Scan, init_node: Node.Index, field_name: []const u8) ?Node.Index {
        var buf: [2]Node.Index = undefined;
        const init = s.tree.fullStructInit(&buf, init_node) orelse return null;
        for (init.ast.fields) |value| {
            if (std.mem.eql(u8, s.name(s.tree.firstToken(value) - 2), field_name)) return value;
        }
        return null;
    }

    /// where a module expression comes from
    fn moduleSource(s: *const Scan, node: Node.Index) ?Source {
        const tree = &s.tree;
        if (tree.nodeTag(node) == .identifier) return s.variables.get(s.name(tree.nodeMainToken(node)));
        var buf: [1]Node.Index = undefined;
        const method, const params = s.calledMethod(node, &buf) orelse return null;
        if (std.mem.eql(u8, method, "module")) {
            if (params.len != 1) return null;
            const module = s.string(params[0]) orelse return null;
            const receiver = tree.nodeData(tree.fullCall(&buf, node).?.ast.fn_expr).node_and_token[0];
            const dependency = s.dependencyName(receiver) orelse return null;
            return .{ .dependency = .{ .dependency = dependency, .module = module } };
        }
        if (!std.mem.eql(u8, method, "addModule") and !std.mem.eql(u8, method, "createModule")) return null;
        if (params.len == 0) return null;
        const source = s.field(params[params.len - 1], "root_source_file") orelse return null;
        var path_buf: [1]Node.Index = undefined;
        const path_method, const path_params = s.calledMethod(source, &path_buf) orelse return null;
        if (!std.mem.eql(u8, path_method, "path") or path_params.len != 1) return null;
        const relative = s.string(path_params[0]) orelse return null;
        return .{ .file = std.fs.path.join(s.arena, &.{ s.root, relative }) catch return null };
    }

    /// the dependency name of `b.dependency("name", ...)`, or of a constant holding one
    fn dependencyName(s: *const Scan, node: Node.Index) ?[]const u8 {
        const tree = &s.tree;
        if (tree.nodeTag(node) == .identifier) return s.dependencies.get(s.name(tree.nodeMainToken(node)));
        var buf: [1]Node.Index = undefined;
        const method, const params = s.calledMethod(node, &buf) orelse return null;
        if (!std.mem.eql(u8, method, "dependency") and !std.mem.eql(u8, method, "lazyDependency")) return null;
        if (params.len == 0) return null;
        return s.string(params[0]);
    }

    fn add(s: *Scan, module_name: []const u8, source: Source, exported: bool) Allocator.Error!void {
        // the first declaration wins when several artifacts reuse a name,
        // but a later `b.addModule` still exports it
        const entry = try s.modules.getOrPut(s.arena, module_name);
        if (!entry.found_existing) {
            entry.value_ptr.* = .{ .source = source, .exported = exported };
        } else if (exported) {
            entry.value_ptr.exported = true;
        }
    }

    fn run(s: *Scan) Allocator.Error!void {
        const tree = &s.tree;
        // dependencies first, as modules can come from them
        for (0..tree.nodes.len) |i| {
            const node: Node.Index = @enumFromInt(i);
            const var_decl = tree.fullVarDecl(node) orelse continue;
            const init_node = var_decl.ast.init_node.unwrap() orelse continue;
            const variable = s.name(var_decl.ast.mut_token + 1);
            // `lazyDependency` returns an optional, unwrapped with `orelse return`
            const value = if (tree.nodeTag(init_node) == .@"orelse") tree.nodeData(init_node).node_and_node[0] else init_node;
            if (s.dependencyName(value)) |dependency| {
                try s.dependencies.put(s.arena, variable, dependency);
            }
        }
        for (0..tree.nodes.len) |i| {
            const node: Node.Index = @enumFromInt(i);
            const var_decl = tree.fullVarDecl(node) orelse continue;
            const init_node = var_decl.ast.init_node.unwrap() orelse continue;
            const source = s.moduleSource(init_node) orelse continue;
            try s.variables.put(s.arena, s.name(var_decl.ast.mut_token + 1), source);
        }

        for (0..tree.nodes.len) |i| {
            const node: Node.Index = @enumFromInt(i);
            switch (tree.nodeTag(node)) {
                .call, .call_comma, .call_one, .call_one_comma => {
                    var buf: [1]Node.Index = undefined;
                    const method, const params = s.calledMethod(node, &buf) orelse continue;
                    if (params.len < 2) continue;
                    const module_name = s.string(params[0]) orelse continue;
                    if (std.mem.eql(u8, method, "addModule")) {
                        try s.add(module_name, s.moduleSource(node) orelse continue, true);
                    } else if (std.mem.eql(u8, method, "addImport")) {
                        try s.add(module_name, s.moduleSource(params[1]) orelse continue, false);
                    }
                },
                .struct_init_dot, .struct_init_dot_comma, .struct_init_dot_two, .struct_init_dot_two_comma => {
                    const name_node = s.field(node, "name") orelse continue;
                    const module_node = s.field(node, "module") orelse continue;
                    const module_name = s.string(name_node) orelse continue;
                    try s.add(module_name, s.moduleSource(module_node) orelse continue, false);
                },
                else => {},
            }
        }
    }
};

/// the modules declared by `root`/build.zig, empty without one
pub fn modules(arena: Allocator, io: Io, root: []const u8) ![]const Module {
    const path = try std.fs.path.join(arena, &.{ root, "build.zig" });
    const source = Io.Dir.cwd().readFileAllocOptions(io, path, arena, .limited(1 << 24), .of(u8), 0) catch |err| switch (err) {
        error.FileNotFound => return &.{},
        else => |e| return e,
    };
    var scan: Scan = .{
        .arena = arena,
        .tree = try compat.parse(arena, source, .zig),
        .root = root,
    };
    try scan.run();

    const found = try arena.alloc(Module, scan.modules.count());
    for (found, scan.modules.keys(), scan.modules.values()) |*module, name, entry| {
        module.* = .{ .name = name, .source = entry.source, .exported = entry.exported };
    }
    return found;
}
