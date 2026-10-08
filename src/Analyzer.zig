// SPDX-License-Identifier: EUPL-1.2
//! loads zig files, builds their lexical scopes and declarations, and
//! resolves identifiers, namespace accesses and method calls to the
//! declarations they refer to.
//!
//! resolution is purely syntactic plus a light type inference: a value's
//! container is found through its type annotation, initializer, or the
//! return type of the function producing it. nothing is evaluated at
//! comptime, except that a function returning `type` is followed into its
//! `return struct { ... }`.

const std = @import("std");
const Ast = std.zig.Ast;
const Node = Ast.Node;
const TokenIndex = Ast.TokenIndex;
const Allocator = std.mem.Allocator;
const Io = std.Io;

const compat = @import("compat.zig");
const symbol = @import("symbol.zig");

const Analyzer = @This();

/// everything is allocated here and lives until the index is written
arena: Allocator,
io: Io,
packages: std.ArrayList(Package) = .empty,
file_by_path: std.StringHashMapUnmanaged(*File) = .empty,
/// `@import("name")` targets
modules: std.StringHashMapUnmanaged(Module) = .empty,

pub const Package = struct {
    /// absolute directory every file of the package is relative to
    root: []const u8,
    /// `scip-zig zig <name> <version> `
    prefix: []const u8,
};

pub const Module = struct {
    root_file: []const u8,
    package: u32,
};

pub const File = struct {
    path: []const u8,
    /// relative to its package root
    rel: []const u8,
    package: u32,
    source: [:0]const u8,
    tree: Ast,
    /// symbol of the file itself, a namespace descriptor per path component
    symbol: []const u8,
    scopes: std.ArrayList(Scope) = .empty,
    /// scope indices sorted by start ascending, then end descending, so that
    /// nested scopes always come after the scopes containing them
    order: []u32 = &.{},
    decls: std.ArrayList(Decl) = .empty,
    decl_at: std.AutoHashMapUnmanaged(TokenIndex, u32) = .empty,
    container_scope: std.AutoHashMapUnmanaged(Node.Index, u32) = .empty,
    next_local: u32 = 0,
    /// part of the indexed project, gets a SCIP document
    document: bool = false,

    pub fn tokenName(file: *const File, token: TokenIndex) []const u8 {
        return identifierName(file.tree.tokenSlice(token));
    }
};

pub const Scope = struct {
    /// inclusive token range
    start: TokenIndex,
    end: TokenIndex,
    parent: ?u32 = null,
    /// declarations visible by bare name inside the scope
    names: std.StringHashMapUnmanaged(u32) = .empty,
    container: ?Container = null,
};

pub const Container = struct {
    node: Node.Index,
    kind: Kind,
    /// declarations and fields, reachable through `Container.member`
    members: std.StringHashMapUnmanaged(u32) = .empty,
    member_list: std.ArrayList(u32) = .empty,
    /// symbol of the container, members append their descriptor to it.
    /// null for containers without a stable name, whose members are locals.
    symbol: ?[]const u8 = null,

    pub const Kind = enum { file, @"struct", @"enum", @"union", @"opaque" };
};

pub const Decl = struct {
    name: []const u8,
    name_token: TokenIndex,
    kind: Kind,
    /// the declaring var decl, fn decl or container field
    node: Node.OptionalIndex = .none,
    type_node: Node.OptionalIndex = .none,
    /// initializer, or the expression a capture unwraps
    init_node: Node.OptionalIndex = .none,
    /// scope of the container this is a member of
    container: ?u32 = null,
    /// for parameters, the fn decl they belong to and their position
    owner: Node.OptionalIndex = .none,
    param_index: u32 = 0,
    symbol: []const u8 = "",

    pub const Kind = enum {
        constant,
        variable,
        function,
        field,
        param,
        capture,
    };
};

pub const Ref = struct {
    file: *File,
    decl: u32,
    /// the generic instantiation the declaration is seen in
    env: ?*const Env = null,

    pub fn get(ref: Ref) *Decl {
        return &ref.file.decls.items[ref.decl];
    }
};

pub const Target = struct {
    file: *File,
    scope: u32,
    env: ?*const Env = null,

    pub fn container(target: Target) *Container {
        return &target.file.scopes.items[target.scope].container.?;
    }
};

/// a call of a fn, binding its parameters to the call's arguments so that
/// `ArrayList(Foo)` knows its `T` is `Foo`. envs chain to the instantiation
/// the fn itself was found in, e.g. a method of `ArrayList(Foo)`.
pub const Env = struct {
    file: *File,
    fn_decl: Node.Index,
    args: []const Node.Index,
    /// where the arguments are written, and the instantiation they are seen in
    arg_file: *File,
    arg_env: ?*const Env,
    /// 1 when called as a method, `value.f(x)`, where `value` is the first parameter
    skip: u32,
    parent: ?*const Env,

    /// the argument bound to a parameter, as `(file, node, env)`
    fn argument(env: *const Env, file: *const File, decl: *const Decl) ?struct { *File, Node.Index, ?*const Env } {
        var it: ?*const Env = env;
        while (it) |e| : (it = e.parent) {
            if (e.file != file or decl.owner.unwrap() != e.fn_decl) continue;
            if (decl.param_index < e.skip) return null;
            const index = decl.param_index - e.skip;
            if (index >= e.args.len) return null;
            return .{ e.arg_file, e.args[index], e.arg_env };
        }
        return null;
    }
};

const max_depth = 32;

pub fn identifierName(slice: []const u8) []const u8 {
    if (std.mem.startsWith(u8, slice, "@\"") and slice.len >= 3) return slice[2 .. slice.len - 1];
    return slice;
}

pub fn addPackage(a: *Analyzer, root: []const u8, name: []const u8, version: []const u8) Allocator.Error!u32 {
    try a.packages.append(a.arena, .{
        .root = root,
        .prefix = try symbol.packagePrefix(a.arena, name, version),
    });
    return @intCast(a.packages.items.len - 1);
}

pub fn addModule(a: *Analyzer, name: []const u8, root_file: []const u8, package: u32) Allocator.Error!void {
    try a.modules.put(a.arena, name, .{ .root_file = root_file, .package = package });
}

/// loads, parses and collects the declarations of `path`, which must be
/// absolute and normalized. files are only loaded once.
pub fn loadFile(a: *Analyzer, path: []const u8, package: u32) !*File {
    if (a.file_by_path.get(path)) |file| return file;

    const source = try std.Io.Dir.cwd().readFileAllocOptions(a.io, path, a.arena, .limited(1 << 30), .of(u8), 0);
    const pkg = a.packages.items[package];
    const rel = relativeTo(pkg.root, path);

    var file_symbol: std.ArrayList(u8) = .empty;
    try file_symbol.appendSlice(a.arena, pkg.prefix);
    var components = std.mem.tokenizeScalar(u8, rel, '/');
    while (components.next()) |component| {
        try symbol.appendDescriptor(a.arena, &file_symbol, component, .namespace);
    }

    const file = try a.arena.create(File);
    file.* = .{
        .path = path,
        .rel = rel,
        .package = package,
        .source = source,
        .tree = try compat.parse(a.arena, source, .zig),
        .symbol = file_symbol.items,
    };
    try a.file_by_path.put(a.arena, path, file);
    try a.collect(file);
    return file;
}

/// `path` relative to `root`, or `path` without its leading `/` if outside
fn relativeTo(root: []const u8, path: []const u8) []const u8 {
    if (std.mem.startsWith(u8, path, root) and path.len > root.len and path[root.len] == '/') {
        return path[root.len + 1 ..];
    }
    return std.mem.trimStart(u8, path, "/");
}

/// lexically normalizes an absolute path, resolving `.` and `..`
pub fn normalize(arena: Allocator, path: []const u8) Allocator.Error![]const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeScalar(u8, path, '/');
    while (it.next()) |part| {
        if (std.mem.eql(u8, part, ".")) continue;
        if (std.mem.eql(u8, part, "..")) {
            _ = parts.pop();
            continue;
        }
        try parts.append(arena, part);
    }
    var out: std.ArrayList(u8) = .empty;
    for (parts.items) |part| {
        try out.append(arena, '/');
        try out.appendSlice(arena, part);
    }
    if (out.items.len == 0) try out.append(arena, '/');
    return out.items;
}

// collection

fn addScope(a: *Analyzer, file: *File, scope: Scope) Allocator.Error!u32 {
    try file.scopes.append(a.arena, scope);
    return @intCast(file.scopes.items.len - 1);
}

fn addDecl(a: *Analyzer, file: *File, decl: Decl) Allocator.Error!u32 {
    try file.decls.append(a.arena, decl);
    const index: u32 = @intCast(file.decls.items.len - 1);
    try file.decl_at.put(a.arena, decl.name_token, index);
    return index;
}

/// a scope holding a single declaration, visible from its name to `end`
fn addLocal(a: *Analyzer, file: *File, decl: Decl, end: TokenIndex) Allocator.Error!void {
    const index = try a.addDecl(file, decl);
    var scope: Scope = .{ .start = decl.name_token, .end = end };
    try scope.names.put(a.arena, decl.name, index);
    _ = try a.addScope(file, scope);
}

fn collect(a: *Analyzer, file: *File) !void {
    const tree = &file.tree;

    try a.addContainer(file, .root, .file, tree.rootDecls(), 0, @intCast(tree.tokens.len - 1));

    for (1..tree.nodes.len) |i| {
        const node: Node.Index = @enumFromInt(i);
        switch (tree.nodeTag(node)) {
            .container_decl,
            .container_decl_trailing,
            .container_decl_two,
            .container_decl_two_trailing,
            .container_decl_arg,
            .container_decl_arg_trailing,
            .tagged_union,
            .tagged_union_trailing,
            .tagged_union_two,
            .tagged_union_two_trailing,
            .tagged_union_enum_tag,
            .tagged_union_enum_tag_trailing,
            => {
                var buf: [2]Node.Index = undefined;
                const decl = tree.fullContainerDecl(&buf, node).?;
                const kind: Container.Kind = switch (tree.tokenTag(decl.ast.main_token)) {
                    .keyword_enum => .@"enum",
                    .keyword_union => .@"union",
                    .keyword_opaque => .@"opaque",
                    else => .@"struct",
                };
                try a.addContainer(file, node, kind, decl.ast.members, tree.firstToken(node), tree.lastToken(node));
            },
            .fn_decl => try a.collectParams(file, node),
            .block, .block_semicolon, .block_two, .block_two_semicolon => try a.collectBlock(file, node),
            .@"if", .if_simple => {
                const full = tree.fullIf(node).?;
                if (full.payload_token) |token| {
                    try a.addCaptures(file, token, full.ast.cond_expr, tree.lastToken(full.ast.then_expr));
                }
                if (full.error_token) |token| {
                    if (full.ast.else_expr.unwrap()) |else_expr| {
                        try a.addCaptures(file, token, null, tree.lastToken(else_expr));
                    }
                }
            },
            .@"while", .while_simple, .while_cont => {
                const full = tree.fullWhile(node).?;
                if (full.payload_token) |token| {
                    try a.addCaptures(file, token, full.ast.cond_expr, tree.lastToken(full.ast.then_expr));
                }
                if (full.error_token) |token| {
                    if (full.ast.else_expr.unwrap()) |else_expr| {
                        try a.addCaptures(file, token, null, tree.lastToken(else_expr));
                    }
                }
            },
            .@"for", .for_simple => {
                const full = tree.fullFor(node).?;
                try a.addForCaptures(file, full.payload_token, full.ast.inputs, tree.lastToken(full.ast.then_expr));
            },
            .switch_case, .switch_case_one, .switch_case_inline, .switch_case_inline_one => {
                const full = tree.fullSwitchCase(node).?;
                if (full.payload_token) |token| {
                    try a.addCaptures(file, token, null, tree.lastToken(full.ast.target_expr));
                }
            },
            .@"catch" => {
                const catch_token = tree.nodeMainToken(node);
                if (tree.tokenTag(catch_token + 1) == .pipe) {
                    const rhs = tree.nodeData(node).node_and_node[1];
                    try a.addCaptures(file, catch_token + 2, null, tree.lastToken(rhs));
                }
            },
            else => {},
        }
    }

    try a.sortScopes(file);
    try a.nameContainer(file, 0, file.symbol);
    for (file.decls.items) |*decl| {
        if (decl.symbol.len == 0) decl.symbol = try a.declSymbol(file, decl);
    }
}

fn addContainer(
    a: *Analyzer,
    file: *File,
    node: Node.Index,
    kind: Container.Kind,
    members: []const Node.Index,
    start: TokenIndex,
    end: TokenIndex,
) !void {
    const tree = &file.tree;
    const scope_index = try a.addScope(file, .{
        .start = start,
        .end = end,
        .container = .{ .node = node, .kind = kind },
    });
    try file.container_scope.put(a.arena, node, scope_index);

    for (members) |member_node| {
        var decl: Decl = switch (tree.nodeTag(member_node)) {
            .fn_decl => blk: {
                var buf: [1]Node.Index = undefined;
                const proto = tree.fullFnProto(&buf, member_node).?;
                const name_token = proto.name_token orelse continue;
                break :blk .{
                    .name = file.tokenName(name_token),
                    .name_token = name_token,
                    .kind = .function,
                    .node = member_node.toOptional(),
                };
            },
            .global_var_decl, .local_var_decl, .simple_var_decl, .aligned_var_decl => blk: {
                const var_decl = tree.fullVarDecl(member_node).?;
                const name_token = var_decl.ast.mut_token + 1;
                break :blk .{
                    .name = file.tokenName(name_token),
                    .name_token = name_token,
                    .kind = if (tree.tokenTag(var_decl.ast.mut_token) == .keyword_var) .variable else .constant,
                    .node = member_node.toOptional(),
                    .type_node = var_decl.ast.type_node,
                    .init_node = var_decl.ast.init_node,
                };
            },
            .container_field_init, .container_field_align, .container_field => blk: {
                const field = tree.fullContainerField(member_node).?;
                // `a`, `a = 1` in enums and unions parse like tuple fields,
                // with the name in place of a type
                const named = !field.ast.tuple_like or
                    ((kind == .@"enum" or kind == .@"union") and tree.tokenTag(field.ast.main_token) == .identifier);
                if (!named) continue;
                break :blk .{
                    .name = file.tokenName(field.ast.main_token),
                    .name_token = field.ast.main_token,
                    .kind = .field,
                    .node = member_node.toOptional(),
                    .type_node = if (field.ast.tuple_like) .none else field.ast.type_expr,
                    .init_node = field.ast.value_expr,
                };
            },
            else => continue,
        };
        decl.container = scope_index;
        const index = try a.addDecl(file, decl);
        // the scope list may have grown, so look the container up again
        const scope = &file.scopes.items[scope_index];
        // fields are only reachable through a value or the type, never by bare name
        if (decl.kind != .field) try scope.names.put(a.arena, decl.name, index);
        try scope.container.?.members.put(a.arena, decl.name, index);
        try scope.container.?.member_list.append(a.arena, index);
    }
}

fn collectParams(a: *Analyzer, file: *File, fn_decl: Node.Index) !void {
    const tree = &file.tree;
    var buf: [1]Node.Index = undefined;
    const proto = tree.fullFnProto(&buf, fn_decl).?;
    const end = tree.lastToken(fn_decl);
    var it = proto.iterate(tree);
    var index: u32 = 0;
    while (it.next()) |param| : (index += 1) {
        const name_token = param.name_token orelse continue;
        if (std.mem.eql(u8, tree.tokenSlice(name_token), "_")) continue;
        try a.addLocal(file, .{
            .name = file.tokenName(name_token),
            .name_token = name_token,
            .kind = .param,
            .type_node = .fromOptional(param.type_expr),
            .owner = fn_decl.toOptional(),
            .param_index = index,
        }, end);
    }
}

fn collectBlock(a: *Analyzer, file: *File, block: Node.Index) !void {
    const tree = &file.tree;
    var buf: [2]Node.Index = undefined;
    const statements = tree.blockStatements(&buf, block) orelse return;
    const end = tree.lastToken(block);
    for (statements) |statement| {
        switch (tree.nodeTag(statement)) {
            .global_var_decl, .local_var_decl, .simple_var_decl, .aligned_var_decl => {
                try a.collectLocalVar(file, statement, end);
            },
            .assign_destructure => {
                const destructure = tree.assignDestructure(statement);
                for (destructure.ast.variables) |variable| {
                    if (tree.fullVarDecl(variable) != null) try a.collectLocalVar(file, variable, end);
                }
            },
            else => {},
        }
    }
}

fn collectLocalVar(a: *Analyzer, file: *File, node: Node.Index, end: TokenIndex) !void {
    const tree = &file.tree;
    const var_decl = tree.fullVarDecl(node).?;
    const name_token = var_decl.ast.mut_token + 1;
    try a.addLocal(file, .{
        .name = file.tokenName(name_token),
        .name_token = name_token,
        .kind = if (tree.tokenTag(var_decl.ast.mut_token) == .keyword_var) .variable else .constant,
        .node = node.toOptional(),
        .type_node = var_decl.ast.type_node,
        .init_node = var_decl.ast.init_node,
    }, end);
}

/// `|x|`, `|*x|` or `|x, i|` starting at `first`, the token after the `|`
fn addCaptures(a: *Analyzer, file: *File, first: TokenIndex, unwraps: ?Node.Index, end: TokenIndex) !void {
    const tree = &file.tree;
    var token = first;
    var index: usize = 0;
    while (true) {
        if (tree.tokenTag(token) == .asterisk) token += 1;
        if (tree.tokenTag(token) != .identifier) return;
        if (!std.mem.eql(u8, tree.tokenSlice(token), "_")) {
            try a.addLocal(file, .{
                .name = file.tokenName(token),
                .name_token = token,
                .kind = .capture,
                // only the first capture holds the unwrapped value, the
                // second one of a switch prong is the tag
                .init_node = if (index == 0) .fromOptional(unwraps) else .none,
            }, end);
        }
        if (tree.tokenTag(token + 1) != .comma) return;
        token += 2;
        index += 1;
    }
}

fn addForCaptures(a: *Analyzer, file: *File, first: TokenIndex, inputs: []const Node.Index, end: TokenIndex) !void {
    const tree = &file.tree;
    var token = first;
    for (inputs) |input| {
        if (tree.tokenTag(token) == .asterisk) token += 1;
        if (tree.tokenTag(token) != .identifier) return;
        if (!std.mem.eql(u8, tree.tokenSlice(token), "_")) {
            const is_range = tree.nodeTag(input) == .for_range;
            try a.addLocal(file, .{
                .name = file.tokenName(token),
                .name_token = token,
                .kind = .capture,
                .init_node = if (is_range) .none else input.toOptional(),
            }, end);
        }
        if (tree.tokenTag(token + 1) != .comma) return;
        token += 2;
    }
}

fn sortScopes(a: *Analyzer, file: *File) !void {
    const order = try a.arena.alloc(u32, file.scopes.items.len);
    for (order, 0..) |*o, i| o.* = @intCast(i);
    std.mem.sort(u32, order, file.scopes.items, struct {
        fn lessThan(scopes: []const Scope, lhs: u32, rhs: u32) bool {
            const l = scopes[lhs];
            const r = scopes[rhs];
            if (l.start != r.start) return l.start < r.start;
            if (l.end != r.end) return l.end > r.end;
            return lhs < rhs;
        }
    }.lessThan);
    file.order = order;

    var stack: std.ArrayList(u32) = .empty;
    for (order) |index| {
        const scope = &file.scopes.items[index];
        while (stack.items.len > 0 and file.scopes.items[stack.items[stack.items.len - 1]].end < scope.start) {
            _ = stack.pop();
        }
        if (stack.items.len > 0) scope.parent = stack.items[stack.items.len - 1];
        try stack.append(a.arena, index);
    }
}

/// gives stable symbols to containers reachable through named declarations,
/// including `fn Generic(...) type { return struct { ... }; }`
fn nameContainer(a: *Analyzer, file: *File, scope_index: u32, container_symbol: []const u8) !void {
    const tree = &file.tree;
    const container = &file.scopes.items[scope_index].container.?;
    if (container.symbol != null) return;
    container.symbol = container_symbol;

    for (container.member_list.items) |decl_index| {
        const decl = file.decls.items[decl_index];
        const child_node = switch (decl.kind) {
            .constant, .variable => decl.init_node.unwrap() orelse continue,
            .function => returnedExpression(tree, decl.node.unwrap().?) orelse continue,
            else => continue,
        };
        const child_scope = file.container_scope.get(child_node) orelse continue;
        const child_symbol = try symbol.withDescriptor(a.arena, container_symbol, decl.name, .type);
        try a.nameContainer(file, child_scope, child_symbol);
    }
}

/// the operand of `return` if it's the first one among a fn body's statements
fn returnedExpression(tree: *const Ast, fn_decl: Node.Index) ?Node.Index {
    const body = tree.nodeData(fn_decl).node_and_node[1];
    var buf: [2]Node.Index = undefined;
    const statements = tree.blockStatements(&buf, body) orelse return null;
    for (statements) |statement| {
        if (tree.nodeTag(statement) == .@"return") return tree.nodeData(statement).opt_node.unwrap();
    }
    return null;
}

fn declSymbol(a: *Analyzer, file: *File, decl: *const Decl) Allocator.Error![]const u8 {
    if (decl.container) |scope_index| {
        if (file.scopes.items[scope_index].container.?.symbol) |prefix| {
            const suffix: symbol.Suffix = switch (decl.kind) {
                .function => .method,
                .constant, .variable => if (initIsType(file, decl)) .type else .term,
                else => .term,
            };
            return symbol.withDescriptor(a.arena, prefix, decl.name, suffix);
        }
    }
    defer file.next_local += 1;
    return symbol.local(a.arena, file.next_local);
}

/// whether a constant is initialized with a type, syntactically
pub fn initIsType(file: *const File, decl: *const Decl) bool {
    if (decl.kind != .constant and decl.kind != .variable) return false;
    const init_node = decl.init_node.unwrap() orelse return false;
    if (file.container_scope.contains(init_node)) return true;
    const tree = &file.tree;
    return switch (tree.nodeTag(init_node)) {
        .builtin_call_two, .builtin_call_two_comma => std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(init_node)), "@This"),
        else => false,
    };
}

// resolution

/// innermost scope containing `token`
pub fn scopeAt(file: *const File, token: TokenIndex) u32 {
    const scopes = file.scopes.items;
    // last scope in order starting at or before the token
    var lo: usize = 0;
    var hi: usize = file.order.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (scopes[file.order[mid]].start <= token) lo = mid + 1 else hi = mid;
    }
    // the root scope covers every token, so lo is at least 1
    var index = file.order[lo - 1];
    while (scopes[index].end < token) index = scopes[index].parent.?;
    return index;
}

pub fn lookup(file: *File, token: TokenIndex, name: []const u8, env: ?*const Env) ?Ref {
    var index: ?u32 = scopeAt(file, token);
    while (index) |i| : (index = file.scopes.items[i].parent) {
        if (file.scopes.items[i].names.get(name)) |decl| return .{ .file = file, .decl = decl, .env = env };
    }
    return null;
}

fn enclosingContainer(file: *File, token: TokenIndex, env: ?*const Env) Target {
    var index = scopeAt(file, token);
    while (file.scopes.items[index].container == null) index = file.scopes.items[index].parent.?;
    return .{ .file = file, .scope = index, .env = env };
}

fn rootOf(file: *File) Target {
    return .{ .file = file, .scope = file.container_scope.get(.root).? };
}

pub fn member(target: Target, name: []const u8) ?Ref {
    const decl = target.container().members.get(name) orelse return null;
    return .{ .file = target.file, .decl = decl, .env = target.env };
}

/// the declaration an identifier or field access refers to
pub fn resolveDecl(a: *Analyzer, file: *File, node: Node.Index) ?Ref {
    return a.resolveDeclDepth(file, node, null, 0);
}

fn resolveDeclDepth(a: *Analyzer, file: *File, node: Node.Index, env: ?*const Env, depth: u32) ?Ref {
    const tree = &file.tree;
    switch (tree.nodeTag(node)) {
        .identifier => {
            const token = tree.nodeMainToken(node);
            return lookup(file, token, file.tokenName(token), env);
        },
        .field_access => {
            const lhs, const rhs = tree.nodeData(node).node_and_token;
            const target = a.containerOfDepth(file, lhs, env, depth + 1) orelse return null;
            return member(target, file.tokenName(rhs));
        },
        else => return null,
    }
}

/// the container an expression denotes (for types and namespaces) or has
/// as its type (for values). pointers, optionals, error unions, slices and
/// arrays are seen through, so `[]Foo` yields `Foo` too.
pub fn containerOf(a: *Analyzer, file: *File, node: Node.Index) ?Target {
    return a.containerOfDepth(file, node, null, 0);
}

/// `containerOf` for an expression seen in a generic instantiation
pub fn containerOfIn(a: *Analyzer, file: *File, node: Node.Index, env: ?*const Env) ?Target {
    return a.containerOfDepth(file, node, env, 0);
}

fn containerOfDepth(a: *Analyzer, file: *File, node: Node.Index, env: ?*const Env, depth: u32) ?Target {
    if (depth > max_depth) return null;
    const tree = &file.tree;
    const next = depth + 1;
    if (file.container_scope.get(node)) |scope| return .{ .file = file, .scope = scope, .env = env };

    switch (tree.nodeTag(node)) {
        .identifier, .field_access => {
            const ref = a.resolveDeclDepth(file, node, env, next) orelse return null;
            return a.containerOfDecl(ref, next);
        },
        .builtin_call_two, .builtin_call_two_comma, .builtin_call, .builtin_call_comma => {
            const name = tree.tokenSlice(tree.nodeMainToken(node));
            var buf: [2]Node.Index = undefined;
            const params = tree.builtinCallParams(&buf, node).?;
            if (std.mem.eql(u8, name, "@This")) return enclosingContainer(file, tree.nodeMainToken(node), env);
            if (params.len == 0) return null;
            if (std.mem.eql(u8, name, "@import")) {
                const imported = a.importFile(file, params[0]) orelse return null;
                return rootOf(imported);
            }
            if (std.mem.eql(u8, name, "@as") or std.mem.eql(u8, name, "@TypeOf")) {
                return a.containerOfDepth(file, params[0], env, next);
            }
            return null;
        },
        .call, .call_comma, .call_one, .call_one_comma => {
            var buf: [1]Node.Index = undefined;
            const call = tree.fullCall(&buf, node).?;
            const callee = a.resolveFunctionDepth(file, call.ast.fn_expr, env, next) orelse return null;
            const call_env = a.arena.create(Env) catch return null;
            call_env.* = .{
                .file = callee.file,
                .fn_decl = callee.get().node.unwrap().?,
                // single-argument calls keep their params in `buf`
                .args = a.arena.dupe(Node.Index, call.ast.params) catch return null,
                .arg_file = file,
                .arg_env = env,
                .skip = if (a.isMethodCall(file, call.ast.fn_expr, env, next)) 1 else 0,
                .parent = callee.env,
            };
            return a.returnContainer(callee, call_env, next);
        },
        .@"try", .address_of, .optional_type, .deref, .@"comptime", .@"nosuspend" => {
            return a.containerOfDepth(file, tree.nodeData(node).node, env, next);
        },
        .unwrap_optional, .grouped_expression => {
            return a.containerOfDepth(file, tree.nodeData(node).node_and_token[0], env, next);
        },
        .@"catch", .@"orelse", .array_access => {
            return a.containerOfDepth(file, tree.nodeData(node).node_and_node[0], env, next);
        },
        .error_union => {
            return a.containerOfDepth(file, tree.nodeData(node).node_and_node[1], env, next);
        },
        .ptr_type_aligned, .ptr_type_sentinel, .ptr_type, .ptr_type_bit_range => {
            return a.containerOfDepth(file, tree.fullPtrType(node).?.ast.child_type, env, next);
        },
        .array_type, .array_type_sentinel => {
            return a.containerOfDepth(file, tree.fullArrayType(node).?.ast.elem_type, env, next);
        },
        .struct_init_one, .struct_init_one_comma, .struct_init, .struct_init_comma => {
            var buf: [2]Node.Index = undefined;
            const init = tree.fullStructInit(&buf, node).?;
            return a.containerOfDepth(file, init.ast.type_expr.unwrap() orelse return null, env, next);
        },
        // both branches usually agree, like std's `if (alignment) |a| []align(a) T else []T`
        .@"if", .if_simple => {
            const full = tree.fullIf(node).?;
            if (a.containerOfDepth(file, full.ast.then_expr, env, next)) |target| return target;
            return a.containerOfDepth(file, full.ast.else_expr.unwrap() orelse return null, env, next);
        },
        else => return null,
    }
}

fn containerOfDecl(a: *Analyzer, ref: Ref, depth: u32) ?Target {
    const decl = ref.get();
    switch (decl.kind) {
        .function => return null,
        .param => if (ref.env) |env| {
            // a comptime type parameter, or one whose type mentions one
            if (env.argument(ref.file, decl)) |arg| {
                const arg_file, const arg_node, const arg_env = arg;
                if (a.containerOfDepth(arg_file, arg_node, arg_env, depth)) |target| return target;
            }
        },
        else => {},
    }
    if (decl.type_node.unwrap()) |type_node| {
        return a.containerOfDepth(ref.file, type_node, ref.env, depth);
    }
    if (decl.init_node.unwrap()) |init_node| {
        return a.containerOfDepth(ref.file, init_node, ref.env, depth);
    }
    return null;
}

/// the function `node` names, following `const alias = other.function;`
pub fn resolveFunction(a: *Analyzer, file: *File, node: Node.Index) ?Ref {
    return a.resolveFunctionDepth(file, node, null, 0);
}

fn resolveFunctionDepth(a: *Analyzer, file: *File, node: Node.Index, env: ?*const Env, depth: u32) ?Ref {
    var ref = a.resolveDeclDepth(file, node, env, depth) orelse return null;
    var hops: u32 = depth;
    while (hops < max_depth) : (hops += 1) {
        const decl = ref.get();
        if (decl.kind == .function) return ref;
        if (decl.kind != .constant or decl.type_node != .none) return null;
        const init_node = decl.init_node.unwrap() orelse return null;
        ref = a.resolveDeclDepth(ref.file, init_node, ref.env, hops + 1) orelse return null;
    }
    return null;
}

/// whether `fn_expr` calls a method on a value, `value.f()`, rather than a
/// function of a namespace or type, `Type.f()`
pub fn isMethodCall(a: *Analyzer, file: *File, fn_expr: Node.Index, env: ?*const Env, depth: u32) bool {
    const tree = &file.tree;
    if (tree.nodeTag(fn_expr) != .field_access) return false;
    const lhs = tree.nodeData(fn_expr).node_and_token[0];
    if (file.container_scope.contains(lhs)) return false;
    switch (tree.nodeTag(lhs)) {
        .builtin_call_two, .builtin_call_two_comma => return false,
        .identifier, .field_access => {
            const ref = a.resolveDeclDepth(file, lhs, env, depth + 1) orelse return true;
            return !a.isTypeDecl(ref, depth + 1);
        },
        .call, .call_comma, .call_one, .call_one_comma => {
            // `Generic(T).f()` vs `makeValue().f()`
            var buf: [1]Node.Index = undefined;
            const callee = a.resolveFunctionDepth(file, tree.fullCall(&buf, lhs).?.ast.fn_expr, env, depth + 1) orelse return true;
            return !returnsType(callee);
        },
        else => return true,
    }
}

/// whether a declaration names a type or namespace rather than a value
fn isTypeDecl(a: *Analyzer, ref: Ref, depth: u32) bool {
    if (depth > max_depth) return false;
    const decl = ref.get();
    if (decl.kind != .constant) return decl.kind == .param and isTypeParam(ref);
    if (decl.type_node.unwrap()) |type_node| {
        const tree = &ref.file.tree;
        return tree.nodeTag(type_node) == .identifier and std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(type_node)), "type");
    }
    if (initIsType(ref.file, decl)) return true;
    const init_node = decl.init_node.unwrap() orelse return false;
    const tree = &ref.file.tree;
    switch (tree.nodeTag(init_node)) {
        .builtin_call_two, .builtin_call_two_comma => return std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(init_node)), "@import"),
        .identifier, .field_access => {
            const target = a.resolveDeclDepth(ref.file, init_node, ref.env, depth + 1) orelse return false;
            return a.isTypeDecl(target, depth + 1);
        },
        .call, .call_comma, .call_one, .call_one_comma => {
            var buf: [1]Node.Index = undefined;
            const callee = a.resolveFunctionDepth(ref.file, tree.fullCall(&buf, init_node).?.ast.fn_expr, ref.env, depth + 1) orelse return false;
            return returnsType(callee);
        },
        else => return false,
    }
}

fn isTypeParam(ref: Ref) bool {
    const tree = &ref.file.tree;
    const type_node = ref.get().type_node.unwrap() orelse return false;
    return tree.nodeTag(type_node) == .identifier and std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(type_node)), "type");
}

fn returnsType(ref: Ref) bool {
    const tree = &ref.file.tree;
    var buf: [1]Node.Index = undefined;
    const proto = tree.fullFnProto(&buf, ref.get().node.unwrap().?).?;
    const return_type = proto.ast.return_type.unwrap() orelse return false;
    return tree.nodeTag(return_type) == .identifier and std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(return_type)), "type");
}

/// the container a call to `ref` evaluates to, with its arguments in `env`
fn returnContainer(a: *Analyzer, ref: Ref, env: *const Env, depth: u32) ?Target {
    const file = ref.file;
    const tree = &file.tree;
    const fn_decl = ref.get().node.unwrap().?;
    var buf: [1]Node.Index = undefined;
    const proto = tree.fullFnProto(&buf, fn_decl).?;
    const return_type = proto.ast.return_type.unwrap() orelse return null;
    if (returnsType(ref)) {
        // a type constructor, follow what it returns
        const returned = returnedExpression(tree, fn_decl) orelse return null;
        return a.containerOfDepth(file, returned, env, depth);
    }
    return a.containerOfDepth(file, return_type, env, depth);
}

/// the file an `@import` string literal points at
pub fn importFile(a: *Analyzer, file: *File, string_node: Node.Index) ?*File {
    const tree = &file.tree;
    if (tree.nodeTag(string_node) != .string_literal) return null;
    const literal = tree.tokenSlice(tree.nodeMainToken(string_node));
    if (literal.len < 2) return null;
    const name = literal[1 .. literal.len - 1];

    if (std.mem.endsWith(u8, name, ".zig")) {
        const dir = std.fs.path.dirname(file.path) orelse "/";
        const joined = std.fs.path.join(a.arena, &.{ dir, name }) catch return null;
        const path = normalize(a.arena, joined) catch return null;
        return a.loadFile(path, file.package) catch null;
    }
    const module = a.modules.get(name) orelse return null;
    return a.loadFile(module.root_file, module.package) catch null;
}
