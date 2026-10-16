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
/// error values, which belong to no declaration: the information of each,
/// and whether a document defines it so that it's no external symbol
errors: std.StringArrayHashMapUnmanaged(ErrorValue) = .empty,
kinds: std.AutoHashMapUnmanaged(*const Decl, scip.Kind) = .empty,

const ErrorValue = struct {
    info: scip.SymbolInformation,
    defined: bool = false,
};

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

    fn tokenEnd(p: Positions, t: TokenIndex) u32 {
        return p.file.tree.tokenStart(t) + @as(u32, @intCast(p.file.tree.tokenSlice(t).len));
    }

    fn token(p: Positions, t: TokenIndex) scip.Range {
        return p.span(p.file.tree.tokenStart(t), p.tokenEnd(t));
    }

    fn tokens(p: Positions, first: TokenIndex, last: TokenIndex) scip.Range {
        return p.span(p.file.tree.tokenStart(first), p.tokenEnd(last));
    }

    fn node(p: Positions, n: Node.Index) scip.Range {
        return p.tokens(p.file.tree.firstToken(n), p.file.tree.lastToken(n));
    }
};

/// a node with its token range, worked out once
const Spanned = struct {
    node: Node.Index,
    first: TokenIndex,
    last: TokenIndex,

    fn of(tree: *const Ast, node: Node.Index) Spanned {
        return .{ .node = node, .first = tree.firstToken(node), .last = tree.lastToken(node) };
    }

    /// the innermost of `spans` around `token`
    fn innermost(spans: []const Spanned, token: TokenIndex) ?Node.Index {
        var best: ?Spanned = null;
        for (spans) |span| {
            if (span.first <= token and token <= span.last and (best == null or span.first > best.?.first)) best = span;
        }
        return if (best) |span| span.node else null;
    }
};

/// an occurrence along with the bytes it covers, to find the references
/// that fall within a signature
const Located = struct {
    occurrence: scip.Occurrence,
    start: u32,
    end: u32,
};

pub fn document(e: *Emitter, file: *File) !scip.Document {
    const tree = &file.tree;
    const positions: Positions = try .init(e.arena, file);
    var occurrences: std.ArrayList(Located) = .empty;
    var symbols: std.ArrayList(scip.SymbolInformation) = .empty;

    // the file itself is a namespace, defined at its very start
    try occurrences.append(e.arena, .{
        .occurrence = .{
            .range = .{ .start_line = 0, .start_character = 0, .end_line = 0, .end_character = 0 },
            .symbol = file.symbol,
            .symbol_roles = scip.SymbolRole.definition,
            .syntax_kind = .identifier_namespace,
        },
        .start = 0,
        .end = 0,
    });
    try symbols.append(e.arena, try e.fileInfo(file));

    var context: Context = try .init(e, file);
    var results: Results = .{ .emitter = e, .file = file };
    try results.collect();

    for (0..tree.tokens.len) |i| {
        const token: TokenIndex = @intCast(i);
        const in_test = context.tests.isSet(token);
        const test_role: u32 = if (in_test) scip.SymbolRole.@"test" else 0;
        const start = tree.tokenStart(token);
        const end = positions.tokenEnd(token);

        if (file.decl_at.get(token)) |index| {
            const decl = &file.decls.items[index];
            const ref: Ref = .{ .file = file, .decl = index };
            const kind = e.kindOf(ref);
            const roles = test_role | if (decl.forward) scip.SymbolRole.forward_definition else scip.SymbolRole.definition;
            try occurrences.append(e.arena, .{
                .occurrence = .{
                    .range = positions.token(token),
                    .symbol = decl.symbol,
                    .symbol_roles = roles,
                    .syntax_kind = syntaxKind(kind, decl, true),
                    .enclosing_range = if (decl.node.unwrap()) |node| positions.tokens(withDocs(tree, tree.firstToken(node)), tree.lastToken(node)) else null,
                },
                .start = start,
                .end = end,
            });
            var info = try e.declInfo(ref);
            if (symbol.isLocal(decl.symbol)) info.enclosing_symbol = context.ownerOf(decl.name_token);
            try symbols.append(e.arena, info);
            continue;
        }

        switch (tree.tokenTag(token)) {
            .identifier => {
                const error_name = context.error_names.get(token) orelse
                    if (context.isErrorAccess(token)) false else null;
                if (error_name) |defines| {
                    const value = try e.errorValue(file.tokenName(token));
                    if (defines and !value.defined) {
                        // documented where it's first defined
                        value.defined = true;
                        value.info.documentation = try e.documentation(try docsBefore(e.arena, tree, token));
                        try symbols.append(e.arena, value.info);
                    }
                    try occurrences.append(e.arena, .{
                        .occurrence = .{
                            .range = positions.token(token),
                            .symbol = value.info.symbol,
                            .symbol_roles = (if (defines) scip.SymbolRole.definition else 0) | test_role,
                            .syntax_kind = .identifier_constant,
                            .enclosing_range = context.enclosing(&positions, token),
                        },
                        .start = start,
                        .end = end,
                    });
                    continue;
                }
                const ref = e.resolveToken(file, token, &context, &results) orelse continue;
                const decl = ref.get();
                // locals of other files mean nothing in this document
                if (symbol.isLocal(decl.symbol) and ref.file != file) continue;
                const kind = e.kindOf(ref);
                const access: u32 = if (isValue(kind)) context.writes.get(token) orelse scip.SymbolRole.read_access else 0;
                try occurrences.append(e.arena, .{
                    .occurrence = .{
                        .range = positions.token(token),
                        .symbol = decl.symbol,
                        .symbol_roles = access | test_role,
                        .syntax_kind = syntaxKind(kind, decl, false),
                        .enclosing_range = context.enclosing(&positions, token),
                    },
                    .start = start,
                    .end = end,
                });
                if (ref.file.document == null) try e.addExternal(decl.symbol, ref);
            },
            .string_literal => {
                if (context.imports.get(token)) |node| {
                    const imported = e.analyzer.importFile(file, node) orelse continue;
                    try occurrences.append(e.arena, .{
                        .occurrence = .{
                            .range = positions.token(token),
                            .symbol = imported.symbol,
                            .symbol_roles = scip.SymbolRole.import | test_role,
                            .syntax_kind = .string_literal,
                            .enclosing_range = if (context.parentOf(node)) |call| positions.node(call) else null,
                        },
                        .start = start,
                        .end = end,
                    });
                    if (imported.document == null and !e.externals.contains(imported.symbol)) {
                        try e.externals.put(e.arena, imported.symbol, try e.fileInfo(imported));
                    }
                } else if (context.fields.get(token)) |call| {
                    const ref = e.analyzer.fieldOf(file, call) orelse continue;
                    const decl = ref.get();
                    const kind = e.kindOf(ref);
                    const access: u32 = if (isValue(kind)) context.writes.get(token) orelse scip.SymbolRole.read_access else 0;
                    try occurrences.append(e.arena, .{
                        .occurrence = .{
                            .range = positions.token(token),
                            .symbol = decl.symbol,
                            .symbol_roles = access | test_role,
                            .syntax_kind = .string_literal,
                            .enclosing_range = positions.node(call),
                        },
                        .start = start,
                        .end = end,
                    });
                    if (ref.file.document == null) try e.addExternal(decl.symbol, ref);
                }
            },
            else => {},
        }
    }

    try e.linkSignatures(file, &positions, occurrences.items, symbols.items);
    // last, as signatures rely on occurrences being in source order
    try e.parseErrors(file, &positions, &occurrences);

    const out = try e.arena.alloc(scip.Occurrence, occurrences.items.len);
    for (out, occurrences.items) |*o, located| o.* = located.occurrence;
    return .{
        .relative_path = file.document.?,
        .occurrences = out,
        .symbols = symbols.items,
    };
}

/// symbols the documents reference without defining, once every document
/// has been emitted
pub fn externalSymbols(e: *Emitter) ![]const scip.SymbolInformation {
    var out: std.ArrayList(scip.SymbolInformation) = .empty;
    try out.appendSlice(e.arena, e.externals.values());
    for (e.errors.values()) |value| {
        if (!value.defined) try out.append(e.arena, value.info);
    }
    return out.items;
}

/// what the tokens of a file mean beyond the declaration they name,
/// gathered in one walk over its nodes
const Context = struct {
    emitter: *Emitter,
    file: *File,
    /// the field access each `.name` token is the name of
    accesses: std.AutoHashMapUnmanaged(TokenIndex, Node.Index) = .empty,
    /// the path argument of `@import(path)`, by its string token
    imports: std.AutoHashMapUnmanaged(TokenIndex, Node.Index) = .empty,
    /// the `@field(value, "name")` call of each name string token
    fields: std.AutoHashMapUnmanaged(TokenIndex, Node.Index) = .empty,
    /// names of error values, true where `error{...}` defines one
    error_names: std.AutoHashMapUnmanaged(TokenIndex, bool) = .empty,
    /// roles of tokens naming what an assignment writes to
    writes: std.AutoHashMapUnmanaged(TokenIndex, u32) = .empty,
    /// the node a token is the name of, for its enclosing range
    named: std.AutoHashMapUnmanaged(TokenIndex, Node.Index) = .empty,
    /// tokens inside tests
    tests: std.DynamicBitSetUnmanaged,
    /// fn and test decls, which locals are enclosed by
    owners: std.ArrayList(Spanned) = .empty,
    /// innermost node around each node, null for the root
    parents: []Node.OptionalIndex,

    fn init(e: *Emitter, file: *File) !Context {
        const tree = &file.tree;
        var c: Context = .{
            .emitter = e,
            .file = file,
            .tests = try .initEmpty(e.arena, tree.tokens.len),
            .parents = try parentsOf(e.arena, tree),
        };
        for (0..tree.nodes.len) |i| {
            const node: Node.Index = @enumFromInt(i);
            switch (tree.nodeTag(node)) {
                .identifier, .enum_literal => try c.named.put(e.arena, tree.nodeMainToken(node), node),
                .field_access => {
                    const name = tree.nodeData(node).node_and_token[1];
                    try c.accesses.put(e.arena, name, node);
                    try c.named.put(e.arena, name, node);
                },
                .builtin_call_two, .builtin_call_two_comma => {
                    const builtin = tree.tokenSlice(tree.nodeMainToken(node));
                    var buf: [2]Node.Index = undefined;
                    const params = tree.builtinCallParams(&buf, node).?;
                    if (std.mem.eql(u8, builtin, "@import") and params.len > 0) {
                        try c.imports.put(e.arena, tree.nodeMainToken(params[0]), params[0]);
                    } else if (std.mem.eql(u8, builtin, "@field") and params.len == 2 and tree.nodeTag(params[1]) == .string_literal) {
                        try c.fields.put(e.arena, tree.nodeMainToken(params[1]), node);
                    }
                },
                .error_set_decl => {
                    const lbrace, const rbrace = tree.nodeData(node).token_and_token;
                    for (lbrace + 1..rbrace) |t| {
                        if (tree.tokenTag(@intCast(t)) == .identifier) try c.error_names.put(e.arena, @intCast(t), true);
                    }
                },
                .error_value => {
                    const name = tree.nodeMainToken(node) + 2;
                    try c.error_names.put(e.arena, name, false);
                    try c.named.put(e.arena, name, node);
                },
                .assign => try c.write(tree.nodeData(node).node_and_node[0], scip.SymbolRole.write_access),
                .assign_mul,
                .assign_div,
                .assign_mod,
                .assign_add,
                .assign_sub,
                .assign_shl,
                .assign_shl_sat,
                .assign_shr,
                .assign_bit_and,
                .assign_bit_xor,
                .assign_bit_or,
                .assign_mul_wrap,
                .assign_add_wrap,
                .assign_sub_wrap,
                .assign_mul_sat,
                .assign_add_sat,
                .assign_sub_sat,
                => try c.write(tree.nodeData(node).node_and_node[0], scip.SymbolRole.write_access | scip.SymbolRole.read_access),
                .assign_destructure => {
                    for (tree.assignDestructure(node).ast.variables) |variable| {
                        try c.write(variable, scip.SymbolRole.write_access);
                    }
                },
                .struct_init_one,
                .struct_init_one_comma,
                .struct_init,
                .struct_init_comma,
                .struct_init_dot,
                .struct_init_dot_comma,
                .struct_init_dot_two,
                .struct_init_dot_two_comma,
                => {
                    // `.name = value` initializes the field
                    var buf: [2]Node.Index = undefined;
                    for (tree.fullStructInit(&buf, node).?.ast.fields) |value| {
                        try c.writes.put(e.arena, tree.firstToken(value) - 2, scip.SymbolRole.write_access);
                    }
                },
                .test_decl => {
                    const span: Spanned = .of(tree, node);
                    try c.owners.append(e.arena, span);
                    for (span.first..span.last + 1) |t| c.tests.set(t);
                },
                .fn_decl => try c.owners.append(e.arena, .of(tree, node)),
                else => {},
            }
        }
        return c;
    }

    /// whether `token` names a member of an error set, `Set.Name`
    fn isErrorAccess(c: *const Context, token: TokenIndex) bool {
        const node = c.accesses.get(token) orelse return false;
        const lhs = c.file.tree.nodeData(node).node_and_token[0];
        return c.emitter.analyzer.isErrorSet(c.file, lhs);
    }

    /// marks the variable or field an assignment target names
    fn write(c: *Context, target: Node.Index, roles: u32) !void {
        const tree = &c.file.tree;
        const token = switch (tree.nodeTag(target)) {
            .identifier => tree.nodeMainToken(target),
            .field_access => tree.nodeData(target).node_and_token[1],
            else => return,
        };
        try c.writes.put(c.emitter.arena, token, roles);
    }

    fn parentOf(c: *const Context, node: Node.Index) ?Node.Index {
        return c.parents[@intFromEnum(node)].unwrap();
    }

    /// the parent expression of a reference: the call it's the callee of,
    /// the field access it names, or the expression it's an operand of
    fn enclosing(c: *const Context, positions: *const Positions, token: TokenIndex) ?scip.Range {
        const tree = &c.file.tree;
        const node = c.named.get(token) orelse return null;
        const parent = c.parentOf(node);
        if (parent) |p| switch (tree.nodeTag(p)) {
            .call, .call_comma, .call_one, .call_one_comma => {
                var buf: [1]Node.Index = undefined;
                if (tree.fullCall(&buf, p).?.ast.fn_expr == node) return positions.node(p);
            },
            else => {},
        };
        if (tree.nodeTag(node) != .identifier and tree.nodeTag(node) != .enum_literal) return positions.node(node);
        const p = parent orelse return null;
        if (!isExpression(tree.nodeTag(p))) return null;
        return positions.node(p);
    }

    /// the symbol of the innermost fn or test around a token
    fn ownerOf(c: *const Context, token: TokenIndex) []const u8 {
        const tree = &c.file.tree;
        const owner = Spanned.innermost(c.owners.items, token) orelse return "";
        const name_token = switch (tree.nodeTag(owner)) {
            .fn_decl => blk: {
                var buf: [1]Node.Index = undefined;
                break :blk tree.fullFnProto(&buf, owner).?.name_token orelse return "";
            },
            else => blk: {
                const name = tree.nodeData(owner).opt_token_and_node[0].unwrap();
                if (name) |t| if (tree.tokenTag(t) == .string_literal) break :blk t;
                break :blk tree.nodeMainToken(owner);
            },
        };
        const index = c.file.decl_at.get(name_token) orelse return "";
        const owner_symbol = c.file.decls.items[index].symbol;
        return if (symbol.isLocal(owner_symbol)) "" else owner_symbol;
    }
};

/// nodes whose range is a fitting enclosing range for an operand
fn isExpression(tag: Node.Tag) bool {
    return switch (tag) {
        .call,
        .call_comma,
        .call_one,
        .call_one_comma,
        .builtin_call,
        .builtin_call_comma,
        .builtin_call_two,
        .builtin_call_two_comma,
        .field_access,
        .array_access,
        .slice,
        .slice_open,
        .slice_sentinel,
        .deref,
        .address_of,
        .unwrap_optional,
        .@"try",
        .@"orelse",
        .@"catch",
        .negation,
        .negation_wrap,
        .bool_not,
        .bit_not,
        .equal_equal,
        .bang_equal,
        .less_than,
        .greater_than,
        .less_or_equal,
        .greater_or_equal,
        .mul,
        .div,
        .mod,
        .mul_wrap,
        .mul_sat,
        .add,
        .sub,
        .array_cat,
        .add_wrap,
        .sub_wrap,
        .add_sat,
        .sub_sat,
        .shl,
        .shl_sat,
        .shr,
        .bit_and,
        .bit_xor,
        .bit_or,
        .bool_and,
        .bool_or,
        .merge_error_sets,
        .error_union,
        .struct_init_one,
        .struct_init_one_comma,
        .struct_init,
        .struct_init_comma,
        .array_init_one,
        .array_init_one_comma,
        .array_init,
        .array_init_comma,
        .assign,
        .assign_mul,
        .assign_div,
        .assign_mod,
        .assign_add,
        .assign_sub,
        .assign_shl,
        .assign_shl_sat,
        .assign_shr,
        .assign_bit_and,
        .assign_bit_xor,
        .assign_bit_or,
        .assign_mul_wrap,
        .assign_add_wrap,
        .assign_sub_wrap,
        .assign_mul_sat,
        .assign_add_sat,
        .assign_sub_sat,
        => true,
        else => false,
    };
}

/// the innermost node containing each node, by sorting nodes by their
/// token ranges, outer ones first, and sweeping over them with a stack
fn parentsOf(arena: Allocator, tree: *const Ast) Allocator.Error![]Node.OptionalIndex {
    const Span = struct { first: TokenIndex, last: TokenIndex, node: u32 };
    const spans = try arena.alloc(Span, tree.nodes.len - 1);
    for (spans, 1..) |*span, i| {
        const node: Node.Index = @enumFromInt(i);
        span.* = .{ .first = tree.firstToken(node), .last = tree.lastToken(node), .node = @intCast(i) };
    }
    std.mem.sort(Span, spans, {}, struct {
        fn lessThan(_: void, l: Span, r: Span) bool {
            if (l.first != r.first) return l.first < r.first;
            if (l.last != r.last) return l.last > r.last;
            return l.node > r.node;
        }
    }.lessThan);

    const parents = try arena.alloc(Node.OptionalIndex, tree.nodes.len);
    @memset(parents, .none);
    var stack: std.ArrayList(Span) = .empty;
    for (spans) |span| {
        while (stack.items.len > 0 and stack.items[stack.items.len - 1].last < span.first) _ = stack.pop();
        if (stack.items.len > 0) parents[span.node] = @as(Node.Index, @enumFromInt(stack.items[stack.items.len - 1].node)).toOptional();
        try stack.append(arena, span);
    }
    return parents;
}

/// the first of the doc comments before `token`, or `token` itself
fn withDocs(tree: *const Ast, token: TokenIndex) TokenIndex {
    var first = token;
    while (first > 0 and tree.tokenTag(first - 1) == .doc_comment) first -= 1;
    return first;
}

fn resolveToken(e: *Emitter, file: *File, token: TokenIndex, context: *const Context, results: *const Results) ?Ref {
    const tree = &file.tree;
    const name = file.tokenName(token);
    if (token > 0 and tree.tokenTag(token - 1) == .period) {
        if (context.accesses.get(token)) |node| return e.analyzer.resolveDecl(file, node);
        // enum literals, decl literals and struct init fields with a known result type
        const result = results.types.get(token) orelse return null;
        const target = e.analyzer.containerOfIn(result.file, result.node, result.env) orelse return null;
        return Analyzer.member(target, name);
    }
    if (token + 1 < tree.tokens.len and tree.tokenTag(token + 1) == .colon) {
        // a parameter name of a fn type `fn (x: u8) void`
        const before = if (token > 0) tree.tokenTag(token - 1) else .invalid;
        if (before == .l_paren or before == .comma) return null;
    }
    // `break :blk` and `continue :blk`
    if (token > 1 and tree.tokenTag(token - 1) == .colon) switch (tree.tokenTag(token - 2)) {
        .keyword_break, .keyword_continue => {
            const key = Decl.key(e.arena, .label, name) catch return null;
            return Analyzer.lookup(file, token, key, null);
        },
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
    fns: std.ArrayList(Spanned) = .empty,

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
            if (tree.nodeTag(node) == .fn_decl) try r.fns.append(r.emitter.arena, .of(tree, node));
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
        return Spanned.innermost(r.fns.items, token);
    }
};

/// the error value `name`. error values are global to a program, so all
/// of them share one namespace outside of any package.
fn errorValue(e: *Emitter, name: []const u8) !*ErrorValue {
    const sym = try symbol.withDescriptor(e.arena, symbol.error_prefix, name, .term);
    const entry = try e.errors.getOrPut(e.arena, sym);
    if (!entry.found_existing) entry.value_ptr.* = .{ .info = .{
        .symbol = sym,
        .kind = .@"error",
        .display_name = name,
        .signature = .{ .text = try std.fmt.allocPrint(e.arena, "error.{s}", .{name}) },
    } };
    return entry.value_ptr;
}

/// the doc comments right before `token`, one line each
fn docsBefore(arena: Allocator, tree: *const Ast, token: TokenIndex) ![]const u8 {
    var docs: std.ArrayList(u8) = .empty;
    var t = withDocs(tree, token);
    while (t < token) : (t += 1) try appendDocLine(arena, &docs, tree.tokenSlice(t));
    return docs.items;
}

fn addExternal(e: *Emitter, sym: []const u8, ref: Ref) Allocator.Error!void {
    if (e.externals.contains(sym)) return;
    try e.externals.put(e.arena, sym, try e.declInfo(ref));
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

fn declInfo(e: *Emitter, ref: Ref) Allocator.Error!scip.SymbolInformation {
    const file = ref.file;
    const decl = ref.get();
    const docs = if (decl.node.unwrap()) |node| try docsBefore(e.arena, &file.tree, file.tree.firstToken(node)) else "";
    var relationships: []const scip.Relationship = &.{};
    // symbol information holds for every instantiation of a generic, so
    // its type is looked up outside of the one it was reached through
    if (e.analyzer.typeOf(.{ .file = file, .decl = ref.decl })) |target| {
        if (try e.typeSymbol(target)) |type_symbol| {
            relationships = try e.arena.dupe(scip.Relationship, &.{.{ .symbol = type_symbol, .is_type_definition = true }});
        }
    }
    return .{
        .symbol = decl.symbol,
        .kind = e.kindOf(ref),
        .display_name = decl.name,
        .documentation = try e.documentation(docs),
        .relationships = relationships,
        .signature = if (try e.signature(file, decl)) |text| .{ .text = text } else null,
    };
}

/// the symbol of a container a relationship can point at, one that's
/// defined somewhere in the index
fn typeSymbol(e: *Emitter, target: Analyzer.Target) Allocator.Error!?[]const u8 {
    const container = target.container();
    const type_symbol = container.symbol orelse return null;
    if (target.file.container_scope.get(.root).? == target.scope) {
        if (target.file.document == null and !e.externals.contains(type_symbol)) {
            try e.externals.put(e.arena, type_symbol, try e.fileInfo(target.file));
        }
        return type_symbol;
    }
    const decl = container.decl orelse return null;
    if (target.file.document == null) try e.addExternal(type_symbol, .{ .file = target.file, .decl = decl });
    return type_symbol;
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

fn kindOf(e: *Emitter, ref: Ref) scip.Kind {
    const decl = ref.get();
    if (e.kinds.get(decl)) |kind| return kind;
    const kind = e.computeKind(ref);
    e.kinds.put(e.arena, decl, kind) catch {};
    return kind;
}

fn computeKind(e: *Emitter, ref: Ref) scip.Kind {
    const file = ref.file;
    const decl = ref.get();
    const container_kind: ?Analyzer.Container.Kind = if (decl.container) |scope| file.scopes.items[scope].container.?.kind else null;
    return switch (decl.kind) {
        .function => if (e.analyzer.takesSelf(file, decl))
            .method
        else if (container_kind == null or container_kind == .file)
            .function
        else
            .static_method,
        .@"test" => .function,
        .label => .unspecified,
        .field => if (container_kind == .@"enum") .enum_member else .field,
        .param => if (e.analyzer.isType(ref)) .type_parameter else .parameter,
        .capture => .variable,
        .constant, .variable => {
            const init_node = decl.init_node.unwrap() orelse return if (decl.kind == .constant) .constant else .variable;
            const tree = &file.tree;
            switch (tree.nodeTag(init_node)) {
                .error_set_decl, .merge_error_sets => return .type,
                .builtin_call_two, .builtin_call_two_comma => {
                    if (std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(init_node)), "@import")) return .module;
                },
                else => {},
            }
            if (file.container_scope.get(init_node)) |scope| return containerKind(file.scopes.items[scope].container.?.kind);
            if (Analyzer.initIsType(file, decl)) return .@"struct";
            if (decl.kind == .constant and e.analyzer.isType(ref)) {
                // an alias, of the kind of what it names
                const target = e.analyzer.containerOf(file, init_node) orelse return .type;
                if (target.file.container_scope.get(.root) == target.scope) return .module;
                return containerKind(target.container().kind);
            }
            return if (decl.kind == .constant) .constant else .variable;
        },
    };
}

fn containerKind(kind: Analyzer.Container.Kind) scip.Kind {
    return switch (kind) {
        .file, .@"struct" => .@"struct",
        .@"enum" => .@"enum",
        .@"union" => .@"union",
        .@"opaque" => .type,
    };
}

/// whether references to a symbol of this kind read or write a value
fn isValue(kind: scip.Kind) bool {
    return switch (kind) {
        .constant, .variable, .field, .parameter => true,
        else => false,
    };
}

fn syntaxKind(kind: scip.Kind, decl: *const Decl, definition: bool) scip.SyntaxKind {
    const local = symbol.isLocal(decl.symbol);
    return switch (kind) {
        .function, .method, .static_method => if (definition) .identifier_function_definition else .identifier_function,
        .@"struct", .@"enum", .@"union", .type, .type_parameter => .identifier_type,
        .module, .file => .identifier_namespace,
        .parameter => .identifier_parameter,
        .constant, .enum_member, .@"error" => if (local) .identifier_local else .identifier_constant,
        .variable => if (local) .identifier_local else .identifier_mutable_global,
        else => .identifier,
    };
}

fn signature(e: *Emitter, file: *const File, decl: *const Decl) !?[]const u8 {
    const tree = &file.tree;
    const node = decl.node.unwrap() orelse {
        if (decl.kind == .label) return null;
        const type_node = decl.type_node.unwrap() orelse return decl.name;
        return try e.sourceBetween(file, decl.name_token, tree.lastToken(type_node));
    };
    const first = tree.firstToken(node);
    switch (decl.kind) {
        .function => {
            const proto = if (tree.nodeTag(node) == .fn_decl) tree.nodeData(node).node_and_node[0] else node;
            return try e.sourceBetween(file, first, tree.lastToken(proto));
        },
        .@"test" => {
            const name = tree.nodeData(node).opt_token_and_node[0].unwrap() orelse tree.nodeMainToken(node);
            return try e.sourceBetween(file, first, name);
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

/// links the references within each signature taken from the file's
/// source, with ranges relative to the signature
fn linkSignatures(e: *Emitter, file: *const File, positions: *const Positions, occurrences: []const Located, infos: []scip.SymbolInformation) !void {
    const source_start = @intFromPtr(file.source.ptr);
    for (infos) |*info| {
        const sig = &(info.signature orelse continue);
        const text_start = @intFromPtr(sig.text.ptr);
        if (text_start < source_start or text_start + sig.text.len > source_start + file.source.len) continue;
        const start: u32 = @intCast(text_start - source_start);
        const end: u32 = start + @as(u32, @intCast(sig.text.len));
        const origin = positions.span(start, start);

        // occurrences are in source order, except for the file's own first
        var lo: usize = 1;
        var hi: usize = occurrences.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (occurrences[mid].start < start) lo = mid + 1 else hi = mid;
        }
        var linked: std.ArrayList(scip.Occurrence) = .empty;
        for (occurrences[lo..]) |located| {
            if (located.start >= end) break;
            const occurrence = located.occurrence;
            if (located.end > end or occurrence.symbol.len == 0) continue;
            if (occurrence.symbol_roles & scip.SymbolRole.definition != 0 or symbol.isLocal(occurrence.symbol)) continue;
            try linked.append(e.arena, .{
                .range = relative(origin, occurrence.range),
                .symbol = occurrence.symbol,
                .syntax_kind = occurrence.syntax_kind,
            });
        }
        sig.occurrences = linked.items;
    }
}

/// `range` relative to the position `origin`
fn relative(origin: scip.Range, range: scip.Range) scip.Range {
    return .{
        .start_line = range.start_line - origin.start_line,
        .start_character = if (range.start_line == origin.start_line) range.start_character - origin.start_character else range.start_character,
        .end_line = range.end_line - origin.start_line,
        .end_character = if (range.end_line == origin.start_line) range.end_character - origin.start_character else range.end_character,
    };
}

/// the file's syntax errors as diagnostics
fn parseErrors(e: *Emitter, file: *const File, positions: *const Positions, occurrences: *std.ArrayList(Located)) !void {
    const tree = &file.tree;
    for (tree.errors) |parse_error| {
        var message: std.Io.Writer.Allocating = .init(e.arena);
        tree.renderError(parse_error, &message.writer) catch return error.OutOfMemory;
        // past the token when the error is about what follows it
        const start = tree.tokenStart(parse_error.token) + tree.errorOffset(parse_error);
        const end = if (parse_error.token_is_prev) start else positions.tokenEnd(parse_error.token);
        try occurrences.append(e.arena, .{
            .occurrence = .{
                .range = positions.span(start, end),
                .diagnostics = try e.arena.dupe(scip.Diagnostic, &.{.{ .severity = .@"error", .message = message.written() }}),
            },
            .start = start,
            .end = end,
        });
    }
}
