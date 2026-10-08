// SPDX-License-Identifier: EUPL-1.2
//! turns analyzed project files into SCIP documents, collecting the symbols
//! they reference from outside the project along the way

const std = @import("std");
const Ast = std.zig.Ast;
const Node = Ast.Node;
const TokenIndex = Ast.TokenIndex;
const Allocator = std.mem.Allocator;

const Analyzer = @import("Analyzer.zig");
const File = Analyzer.File;
const Decl = Analyzer.Decl;
const Ref = Analyzer.Ref;
const scip = @import("scip.zig");
const symbol = @import("symbol.zig");

const Emitter = @This();

analyzer: *Analyzer,
arena: Allocator,
/// symbols defined outside the project, keyed by symbol
externals: std.StringArrayHashMapUnmanaged(scip.SymbolInformation) = .empty,

/// signatures longer than this are cut down to their head
const max_signature_len = 160;

const Positions = struct {
    file: *const File,
    line_starts: []const u32,

    fn init(arena: Allocator, file: *const File) Allocator.Error!Positions {
        var starts: std.ArrayList(u32) = .empty;
        try starts.append(arena, 0);
        for (file.source, 0..) |c, i| {
            if (c == '\n') try starts.append(arena, @intCast(i + 1));
        }
        return .{ .file = file, .line_starts = starts.items };
    }

    fn lineOf(p: Positions, offset: u32) u32 {
        var lo: usize = 0;
        var hi: usize = p.line_starts.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (p.line_starts[mid] <= offset) lo = mid + 1 else hi = mid;
        }
        return @intCast(lo - 1);
    }

    fn span(p: Positions, start: u32, end: u32) scip.Range {
        const start_line = p.lineOf(start);
        const end_line = p.lineOf(end);
        return .{
            .start_line = start_line,
            .start_character = start - p.line_starts[start_line],
            .end_line = end_line,
            .end_character = end - p.line_starts[end_line],
        };
    }

    fn token(p: Positions, t: TokenIndex) scip.Range {
        const start = p.file.tree.tokenStart(t);
        return p.span(start, start + @as(u32, @intCast(p.file.tree.tokenSlice(t).len)));
    }

    fn node(p: Positions, n: Node.Index) scip.Range {
        const tree = &p.file.tree;
        const last = tree.lastToken(n);
        return p.span(tree.tokenStart(tree.firstToken(n)), tree.tokenStart(last) + @as(u32, @intCast(tree.tokenSlice(last).len)));
    }
};

pub fn document(e: *Emitter, file: *File) !scip.Document {
    const a = e.analyzer;
    const tree = &file.tree;
    const positions: Positions = try .init(e.arena, file);
    var occurrences: std.ArrayList(scip.Occurrence) = .empty;
    var symbols: std.ArrayList(scip.SymbolInformation) = .empty;

    // the file itself is a namespace, defined at its very start
    try occurrences.append(e.arena, .{
        .range = .{ .start_line = 0, .start_character = 0, .end_line = 0, .end_character = 0 },
        .symbol = file.symbol,
        .symbol_roles = scip.SymbolRole.definition,
    });
    try symbols.append(e.arena, try e.fileInfo(file));

    // tokens whose meaning depends on the node around them
    var accesses: std.AutoHashMapUnmanaged(TokenIndex, Node.Index) = .empty;
    var imports: std.AutoHashMapUnmanaged(TokenIndex, Node.Index) = .empty;
    var results: Results = .{ .emitter = e, .file = file };
    try results.collect();
    for (0..tree.nodes.len) |i| {
        const node: Node.Index = @enumFromInt(i);
        switch (tree.nodeTag(node)) {
            .field_access => try accesses.put(e.arena, tree.nodeData(node).node_and_token[1], node),
            .builtin_call_two, .builtin_call_two_comma => {
                if (!std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), "@import")) continue;
                var buf: [2]Node.Index = undefined;
                const params = tree.builtinCallParams(&buf, node).?;
                if (params.len == 0) continue;
                try imports.put(e.arena, tree.nodeMainToken(params[0]), params[0]);
            },
            else => {},
        }
    }

    for (0..tree.tokens.len) |i| {
        const token: TokenIndex = @intCast(i);
        switch (tree.tokenTag(token)) {
            .identifier => {
                if (file.decl_at.get(token)) |index| {
                    const decl = &file.decls.items[index];
                    try occurrences.append(e.arena, .{
                        .range = positions.token(token),
                        .symbol = decl.symbol,
                        .symbol_roles = scip.SymbolRole.definition,
                        .enclosing_range = if (decl.node.unwrap()) |node| positions.node(node) else null,
                    });
                    try symbols.append(e.arena, try e.declInfo(file, decl));
                    continue;
                }
                const ref = e.resolveToken(file, token, &accesses, &results) orelse continue;
                const decl = ref.get();
                // locals of other files mean nothing in this document
                if (symbol.isLocal(decl.symbol) and ref.file != file) continue;
                try occurrences.append(e.arena, .{
                    .range = positions.token(token),
                    .symbol = decl.symbol,
                });
                if (!ref.file.document) try e.addExternal(decl.symbol, ref.file, decl);
            },
            .string_literal => {
                const node = imports.get(token) orelse continue;
                const imported = a.importFile(file, node) orelse continue;
                try occurrences.append(e.arena, .{
                    .range = positions.token(token),
                    .symbol = imported.symbol,
                    .symbol_roles = scip.SymbolRole.import,
                });
                if (!imported.document and !e.externals.contains(imported.symbol)) {
                    try e.externals.put(e.arena, imported.symbol, try e.fileInfo(imported));
                }
            },
            else => {},
        }
    }

    return .{
        .relative_path = file.rel,
        .occurrences = occurrences.items,
        .symbols = symbols.items,
    };
}

fn resolveToken(
    e: *Emitter,
    file: *File,
    token: TokenIndex,
    accesses: *const std.AutoHashMapUnmanaged(TokenIndex, Node.Index),
    results: *const Results,
) ?Ref {
    const tree = &file.tree;
    const name = file.tokenName(token);
    if (token > 0 and tree.tokenTag(token - 1) == .period) {
        if (accesses.get(token)) |node| return e.analyzer.resolveDecl(file, node);
        // enum literals, decl literals and struct init fields with a known result type
        const result = results.types.get(token) orelse return null;
        const target = e.analyzer.containerOfIn(result.file, result.node, result.env) orelse return null;
        return Analyzer.member(target, name);
    }
    if (token + 1 < tree.tokens.len and tree.tokenTag(token + 1) == .colon) {
        // label `blk: {` or a parameter name of a fn type `fn (x: u8) void`
        const before = if (token > 0) tree.tokenTag(token - 1) else .invalid;
        if (before == .l_paren or before == .comma) return null;
        if (token + 2 < tree.tokens.len) switch (tree.tokenTag(token + 2)) {
            .l_brace, .keyword_while, .keyword_for, .keyword_inline, .keyword_switch => return null,
            else => {},
        };
    }
    // `break :blk` and `continue :blk`
    if (token > 0 and tree.tokenTag(token - 1) == .colon and token > 1) switch (tree.tokenTag(token - 2)) {
        .keyword_break, .keyword_continue => return null,
        else => {},
    };
    return Analyzer.lookup(file, token, name, null);
}

/// result types of `.name` tokens, the types that enum literals, decl
/// literals like `.init()` and the fields of `.{ .name = value }` are
/// looked up in
const Results = struct {
    emitter: *Emitter,
    file: *File,
    types: std.AutoHashMapUnmanaged(TokenIndex, ResultType) = .empty,
    /// fn decls of the file, for finding what a `return` returns into
    fns: std.ArrayList(Node.Index) = .empty,

    const ResultType = struct {
        file: *File,
        /// an expression whose container is the result type
        node: Node.Index,
        env: ?*const Analyzer.Env = null,
    };

    const max_nesting = 8;

    fn collect(r: *Results) !void {
        const file = r.file;
        const tree = &file.tree;
        for (0..tree.nodes.len) |i| {
            const node: Node.Index = @enumFromInt(i);
            if (tree.nodeTag(node) == .fn_decl) try r.fns.append(r.emitter.arena, node);
        }

        for (0..tree.nodes.len) |i| {
            const node: Node.Index = @enumFromInt(i);
            switch (tree.nodeTag(node)) {
                .global_var_decl, .local_var_decl, .simple_var_decl, .aligned_var_decl => {
                    const var_decl = tree.fullVarDecl(node).?;
                    const type_node = var_decl.ast.type_node.unwrap() orelse continue;
                    const init_node = var_decl.ast.init_node.unwrap() orelse continue;
                    try r.assign(init_node, .{ .file = file, .node = type_node }, 0);
                },
                .container_field_init, .container_field_align, .container_field => {
                    const field = tree.fullContainerField(node).?;
                    if (field.ast.tuple_like) continue;
                    const type_node = field.ast.type_expr.unwrap() orelse continue;
                    const value = field.ast.value_expr.unwrap() orelse continue;
                    try r.assign(value, .{ .file = file, .node = type_node }, 0);
                },
                .@"return" => {
                    const value = tree.nodeData(node).opt_node.unwrap() orelse continue;
                    const fn_decl = r.enclosingFn(tree.nodeMainToken(node)) orelse continue;
                    var buf: [1]Node.Index = undefined;
                    const proto = tree.fullFnProto(&buf, fn_decl).?;
                    const return_type = proto.ast.return_type.unwrap() orelse continue;
                    try r.assign(value, .{ .file = file, .node = return_type }, 0);
                },
                .equal_equal, .bang_equal => {
                    const lhs, const rhs = tree.nodeData(node).node_and_node;
                    try r.assign(rhs, .{ .file = file, .node = lhs }, 0);
                    try r.assign(lhs, .{ .file = file, .node = rhs }, 0);
                },
                .assign => {
                    const lhs, const rhs = tree.nodeData(node).node_and_node;
                    try r.assign(rhs, .{ .file = file, .node = lhs }, 0);
                },
                .@"switch", .switch_comma => {
                    const full = tree.fullSwitch(node).?;
                    for (full.ast.cases) |case| {
                        for (tree.fullSwitchCase(case).?.ast.values) |value| {
                            try r.assign(value, .{ .file = file, .node = full.ast.condition }, 0);
                        }
                    }
                },
                .struct_init_one, .struct_init_one_comma, .struct_init, .struct_init_comma => {
                    var buf: [2]Node.Index = undefined;
                    const init = tree.fullStructInit(&buf, node).?;
                    const type_expr = init.ast.type_expr.unwrap() orelse continue;
                    try r.assignFields(init.ast.fields, .{ .file = file, .node = type_expr }, 0);
                },
                .call, .call_comma, .call_one, .call_one_comma => try r.collectCall(node),
                else => {},
            }
        }
    }

    /// arguments take the types of the callee's parameters
    fn collectCall(r: *Results, node: Node.Index) !void {
        const a = r.emitter.analyzer;
        const tree = &r.file.tree;
        var buf: [1]Node.Index = undefined;
        const call = tree.fullCall(&buf, node).?;
        if (call.ast.params.len == 0) return;
        const callee = a.resolveFunction(r.file, call.ast.fn_expr) orelse return;
        const skip: usize = if (a.isMethodCall(r.file, call.ast.fn_expr, null, 0)) 1 else 0;

        const callee_tree = &callee.file.tree;
        var proto_buf: [1]Node.Index = undefined;
        const proto = callee_tree.fullFnProto(&proto_buf, callee.get().node.unwrap().?).?;
        var it = proto.iterate(callee_tree);
        var index: usize = 0;
        while (it.next()) |param| : (index += 1) {
            if (index < skip) continue;
            const arg_index = index - skip;
            if (arg_index >= call.ast.params.len) break;
            const type_expr = param.type_expr orelse continue;
            try r.assign(call.ast.params[arg_index], .{ .file = callee.file, .node = type_expr, .env = callee.env }, 0);
        }
    }

    fn assign(r: *Results, value: Node.Index, result: ResultType, depth: u32) Allocator.Error!void {
        if (depth > max_nesting) return;
        const tree = &r.file.tree;
        switch (tree.nodeTag(value)) {
            .enum_literal => try r.types.put(r.emitter.arena, tree.nodeMainToken(value), result),
            .call, .call_comma, .call_one, .call_one_comma => {
                var buf: [1]Node.Index = undefined;
                const fn_expr = tree.fullCall(&buf, value).?.ast.fn_expr;
                if (tree.nodeTag(fn_expr) == .enum_literal) {
                    try r.types.put(r.emitter.arena, tree.nodeMainToken(fn_expr), result);
                }
            },
            .struct_init_dot, .struct_init_dot_comma, .struct_init_dot_two, .struct_init_dot_two_comma => {
                var buf: [2]Node.Index = undefined;
                try r.assignFields(tree.fullStructInit(&buf, value).?.ast.fields, result, depth);
            },
            .grouped_expression => try r.assign(tree.nodeData(value).node_and_token[0], result, depth + 1),
            .@"try", .@"comptime" => try r.assign(tree.nodeData(value).node, result, depth + 1),
            .@"orelse", .@"catch" => try r.assign(tree.nodeData(value).node_and_node[1], result, depth + 1),
            .@"if", .if_simple => {
                const full = tree.fullIf(value).?;
                try r.assign(full.ast.then_expr, result, depth + 1);
                if (full.ast.else_expr.unwrap()) |else_expr| try r.assign(else_expr, result, depth + 1);
            },
            .@"switch", .switch_comma => {
                for (tree.fullSwitch(value).?.ast.cases) |case| {
                    try r.assign(tree.fullSwitchCase(case).?.ast.target_expr, result, depth + 1);
                }
            },
            .block, .block_semicolon, .block_two, .block_two_semicolon => try r.assignBreaks(value, result, depth),
            else => {},
        }
    }

    /// `blk: { ... break :blk value; }`
    fn assignBreaks(r: *Results, block: Node.Index, result: ResultType, depth: u32) Allocator.Error!void {
        const tree = &r.file.tree;
        const first = tree.firstToken(block);
        if (tree.tokenTag(first) != .identifier or tree.tokenTag(first + 1) != .colon) return;
        const label = tree.tokenSlice(first);
        const last = tree.lastToken(block);
        for (0..tree.nodes.len) |i| {
            const node: Node.Index = @enumFromInt(i);
            if (tree.nodeTag(node) != .@"break") continue;
            const token = tree.nodeMainToken(node);
            if (token < first or token > last) continue;
            const label_token, const operand = tree.nodeData(node).opt_token_and_opt_node;
            if (!std.mem.eql(u8, tree.tokenSlice(label_token.unwrap() orelse continue), label)) continue;
            try r.assign(operand.unwrap() orelse continue, result, depth + 1);
        }
    }

    /// `.name = value` fields, each name sits two tokens before its value
    fn assignFields(r: *Results, fields: []const Node.Index, result: ResultType, depth: u32) Allocator.Error!void {
        const tree = &r.file.tree;
        const target = r.emitter.analyzer.containerOfIn(result.file, result.node, result.env);
        for (fields) |field| {
            const name_token = tree.firstToken(field) - 2;
            try r.types.put(r.emitter.arena, name_token, result);
            const ref = Analyzer.member(target orelse continue, r.file.tokenName(name_token)) orelse continue;
            const type_node = ref.get().type_node.unwrap() orelse continue;
            try r.assign(field, .{ .file = ref.file, .node = type_node, .env = ref.env }, depth + 1);
        }
    }

    fn enclosingFn(r: *const Results, token: TokenIndex) ?Node.Index {
        const tree = &r.file.tree;
        var best: ?Node.Index = null;
        var best_start: TokenIndex = 0;
        for (r.fns.items) |fn_decl| {
            const start = tree.firstToken(fn_decl);
            if (start <= token and token <= tree.lastToken(fn_decl) and (best == null or start > best_start)) {
                best = fn_decl;
                best_start = start;
            }
        }
        return best;
    }
};

fn addExternal(e: *Emitter, sym: []const u8, file: *File, decl: *const Decl) !void {
    if (e.externals.contains(sym)) return;
    try e.externals.put(e.arena, sym, try e.declInfo(file, decl));
}

fn fileInfo(e: *Emitter, file: *File) !scip.SymbolInformation {
    const tree = &file.tree;
    var docs: std.ArrayList(u8) = .empty;
    var token: TokenIndex = 0;
    while (token < tree.tokens.len and tree.tokenTag(token) == .container_doc_comment) : (token += 1) {
        try appendDocLine(e.arena, &docs, tree.tokenSlice(token));
    }
    return .{
        .symbol = file.symbol,
        .kind = .file,
        .display_name = std.fs.path.basename(file.rel),
        .documentation = try e.documentation(docs.items),
    };
}

fn declInfo(e: *Emitter, file: *File, decl: *const Decl) !scip.SymbolInformation {
    var docs: std.ArrayList(u8) = .empty;
    if (decl.node.unwrap()) |node| {
        const tree = &file.tree;
        var first = tree.firstToken(node);
        while (first > 0 and tree.tokenTag(first - 1) == .doc_comment) first -= 1;
        var token = first;
        while (tree.tokenTag(token) == .doc_comment) : (token += 1) {
            try appendDocLine(e.arena, &docs, tree.tokenSlice(token));
        }
    }
    return .{
        .symbol = decl.symbol,
        .kind = kindOf(file, decl),
        .display_name = decl.name,
        .documentation = try e.documentation(docs.items),
        .signature = try e.signature(file, decl),
    };
}

fn documentation(e: *Emitter, docs: []const u8) ![]const []const u8 {
    if (docs.len == 0) return &.{};
    const out = try e.arena.alloc([]const u8, 1);
    out[0] = docs;
    return out;
}

fn appendDocLine(arena: Allocator, docs: *std.ArrayList(u8), comment: []const u8) !void {
    // `///` and `//!` are both three bytes
    var line = comment[3..];
    if (std.mem.startsWith(u8, line, " ")) line = line[1..];
    if (docs.items.len > 0) try docs.append(arena, '\n');
    try docs.appendSlice(arena, std.mem.trimEnd(u8, line, "\r"));
}

fn kindOf(file: *const File, decl: *const Decl) scip.Kind {
    const container_kind: ?Analyzer.Container.Kind = if (decl.container) |scope| file.scopes.items[scope].container.?.kind else null;
    return switch (decl.kind) {
        .function => if (container_kind == null or container_kind == .file) .function else .method,
        .field => if (container_kind == .@"enum") .enum_member else .field,
        .param => .parameter,
        .capture => .variable,
        .constant, .variable => {
            if (decl.init_node.unwrap()) |init_node| {
                if (Analyzer.initIsType(file, decl) and !file.container_scope.contains(init_node)) return .@"struct";
                if (file.container_scope.get(init_node)) |scope| return switch (file.scopes.items[scope].container.?.kind) {
                    .file, .@"struct" => .@"struct",
                    .@"enum" => .@"enum",
                    .@"union" => .@"union",
                    .@"opaque" => .type,
                };
                const tree = &file.tree;
                switch (tree.nodeTag(init_node)) {
                    .builtin_call_two, .builtin_call_two_comma => {
                        if (std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(init_node)), "@import")) return .module;
                    },
                    else => {},
                }
            }
            return if (decl.kind == .constant) .constant else .variable;
        },
    };
}

fn signature(e: *Emitter, file: *const File, decl: *const Decl) !?[]const u8 {
    const tree = &file.tree;
    const node = decl.node.unwrap() orelse {
        const type_node = decl.type_node.unwrap() orelse return decl.name;
        return try e.sourceBetween(file, decl.name_token, tree.lastToken(type_node));
    };
    const first = tree.firstToken(node);
    switch (decl.kind) {
        .function => {
            const proto = tree.nodeData(node).node_and_node[0];
            return try e.sourceBetween(file, first, tree.lastToken(proto));
        },
        .constant, .variable => {
            if (decl.init_node.unwrap()) |init_node| {
                if (file.container_scope.contains(init_node)) {
                    var buf: [2]Node.Index = undefined;
                    const container = tree.fullContainerDecl(&buf, init_node).?;
                    return try e.sourceBetween(file, first, container.ast.main_token);
                }
            }
            const whole = try e.sourceBetween(file, first, tree.lastToken(node));
            if (whole.len <= max_signature_len and std.mem.indexOfScalar(u8, whole, '\n') == null) return whole;
            if (decl.type_node.unwrap()) |type_node| return try e.sourceBetween(file, first, tree.lastToken(type_node));
            return try e.sourceBetween(file, first, decl.name_token);
        },
        else => {
            const whole = try e.sourceBetween(file, first, tree.lastToken(node));
            if (whole.len <= max_signature_len and std.mem.indexOfScalar(u8, whole, '\n') == null) return whole;
            if (decl.type_node.unwrap()) |type_node| return try e.sourceBetween(file, decl.name_token, tree.lastToken(type_node));
            return decl.name;
        },
    }
}

/// source from the start of `first` to the end of `last`
fn sourceBetween(_: *Emitter, file: *const File, first: TokenIndex, last: TokenIndex) ![]const u8 {
    const tree = &file.tree;
    const start = tree.tokenStart(first);
    const end = tree.tokenStart(last) + tree.tokenSlice(last).len;
    return file.source[start..end];
}
