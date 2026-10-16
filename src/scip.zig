// SPDX-License-Identifier: EUPL-1.2
//! the subset of scip.proto that scip-zig emits, with field numbers taken
//! from https://github.com/scip-code/scip/blob/main/scip.proto

const std = @import("std");
const Encoder = @import("protobuf.zig").Encoder;
const Error = std.mem.Allocator.Error;

pub const Index = struct {
    metadata: Metadata,
    documents: []const Document,
    external_symbols: []const SymbolInformation,

    pub fn encode(self: Index, e: *Encoder) Error!void {
        try e.message(1, self.metadata);
        try e.repeatedMessage(2, self.documents);
        try e.repeatedMessage(3, self.external_symbols);
    }
};

pub const Metadata = struct {
    tool_info: ToolInfo,
    /// URI of the project root, e.g. `file:///home/me/project`
    project_root: []const u8,

    pub fn encode(self: Metadata, e: *Encoder) Error!void {
        // field 1 (protocol version) only has the default value, so it's omitted
        try e.message(2, self.tool_info);
        try e.string(3, self.project_root);
        try e.uint(4, @backingInt(TextEncoding.utf8));
    }
};

pub const TextEncoding = enum(u32) {
    unspecified = 0,
    utf8 = 1,
    utf16 = 2,
};

pub const ToolInfo = struct {
    name: []const u8,
    version: []const u8,
    arguments: []const []const u8,

    pub fn encode(self: ToolInfo, e: *Encoder) Error!void {
        try e.string(1, self.name);
        try e.string(2, self.version);
        try e.repeatedString(3, self.arguments);
    }
};

pub const Document = struct {
    relative_path: []const u8,
    occurrences: []const Occurrence,
    symbols: []const SymbolInformation,

    pub fn encode(self: Document, e: *Encoder) Error!void {
        try e.string(1, self.relative_path);
        try e.repeatedMessage(2, self.occurrences);
        try e.repeatedMessage(3, self.symbols);
        try e.string(4, language);
        try e.uint(6, @backingInt(PositionEncoding.utf8_code_unit_offset_from_line_start));
    }
};

pub const language = "zig";

pub const PositionEncoding = enum(u32) {
    unspecified = 0,
    utf8_code_unit_offset_from_line_start = 1,
    utf16_code_unit_offset_from_line_start = 2,
    utf32_code_unit_offset_from_line_start = 3,
};

/// zero-based, end exclusive
pub const Range = struct {
    start_line: u32,
    start_character: u32,
    end_line: u32,
    end_character: u32,

    const Single = struct {
        range: Range,

        pub fn encode(self: Single, e: *Encoder) Error!void {
            try e.uint(1, self.range.start_line);
            try e.uint(2, self.range.start_character);
            try e.uint(3, self.range.end_character);
        }
    };

    const Multi = struct {
        range: Range,

        pub fn encode(self: Multi, e: *Encoder) Error!void {
            try e.uint(1, self.range.start_line);
            try e.uint(2, self.range.start_character);
            try e.uint(3, self.range.end_line);
            try e.uint(4, self.range.end_character);
        }
    };

    fn encodeTyped(self: Range, e: *Encoder, single_field: u32, multi_field: u32) Error!void {
        if (self.start_line == self.end_line) {
            try e.message(single_field, Single{ .range = self });
        } else {
            try e.message(multi_field, Multi{ .range = self });
        }
    }
};

pub const SymbolRole = struct {
    pub const definition: u32 = 0x1;
    pub const import: u32 = 0x2;
    pub const write_access: u32 = 0x4;
    pub const read_access: u32 = 0x8;
    pub const generated: u32 = 0x10;
    pub const @"test": u32 = 0x20;
    pub const forward_definition: u32 = 0x40;
};

pub const Occurrence = struct {
    range: Range,
    /// empty for occurrences that only carry diagnostics
    symbol: []const u8 = "",
    symbol_roles: u32 = 0,
    syntax_kind: SyntaxKind = .unspecified,
    diagnostics: []const Diagnostic = &.{},
    enclosing_range: ?Range = null,

    pub fn encode(self: Occurrence, e: *Encoder) Error!void {
        try e.string(2, self.symbol);
        try e.uint(3, self.symbol_roles);
        try e.uint(5, @backingInt(self.syntax_kind));
        try e.repeatedMessage(6, self.diagnostics);
        try self.range.encodeTyped(e, 8, 9);
        if (self.enclosing_range) |range| try range.encodeTyped(e, 10, 11);
    }
};

pub const SyntaxKind = enum(u32) {
    unspecified = 0,
    identifier = 6,
    identifier_constant = 9,
    identifier_mutable_global = 10,
    identifier_parameter = 11,
    identifier_local = 12,
    identifier_namespace = 14,
    identifier_function = 15,
    identifier_function_definition = 16,
    identifier_type = 19,
    string_literal = 27,
};

pub const Diagnostic = struct {
    severity: Severity,
    message: []const u8,

    pub const Severity = enum(u32) {
        unspecified = 0,
        @"error" = 1,
        warning = 2,
        information = 3,
        hint = 4,
    };

    pub fn encode(self: Diagnostic, e: *Encoder) Error!void {
        try e.uint(1, @backingInt(self.severity));
        try e.string(3, self.message);
        try e.string(4, "zig");
    }
};

pub const SymbolInformation = struct {
    symbol: []const u8,
    documentation: []const []const u8 = &.{},
    relationships: []const Relationship = &.{},
    kind: Kind = .unspecified,
    display_name: []const u8 = "",
    signature: ?Signature = null,
    enclosing_symbol: []const u8 = "",

    pub fn encode(self: SymbolInformation, e: *Encoder) Error!void {
        try e.string(1, self.symbol);
        try e.repeatedString(3, self.documentation);
        try e.repeatedMessage(4, self.relationships);
        try e.uint(5, @backingInt(self.kind));
        try e.string(6, self.display_name);
        if (self.signature) |signature| try e.message(7, signature);
        try e.string(8, self.enclosing_symbol);
    }
};

/// rendered as a zig code block by consumers
pub const Signature = struct {
    text: []const u8,
    /// references within `text`, with ranges relative to it
    occurrences: []const Occurrence = &.{},

    pub fn encode(self: Signature, e: *Encoder) Error!void {
        try e.repeatedMessage(2, self.occurrences);
        try e.string(4, language);
        try e.string(5, self.text);
    }
};

pub const Relationship = struct {
    symbol: []const u8,
    is_reference: bool = false,
    is_implementation: bool = false,
    is_type_definition: bool = false,
    is_definition: bool = false,

    pub fn encode(self: Relationship, e: *Encoder) Error!void {
        try e.string(1, self.symbol);
        try e.boolean(2, self.is_reference);
        try e.boolean(3, self.is_implementation);
        try e.boolean(4, self.is_type_definition);
        try e.boolean(5, self.is_definition);
    }
};

pub const Kind = enum(u32) {
    unspecified = 0,
    constant = 8,
    @"enum" = 11,
    enum_member = 12,
    field = 15,
    file = 16,
    function = 17,
    method = 26,
    module = 29,
    parameter = 37,
    @"struct" = 49,
    type = 54,
    type_parameter = 58,
    @"union" = 59,
    variable = 61,
    @"error" = 63,
    static_method = 80,
};
