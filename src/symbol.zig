// SPDX-License-Identifier: EUPL-1.2
//! SCIP symbol string formatting, see the grammar in scip.proto:
//! `<scheme> ' ' <manager> ' ' <name> ' ' <version> ' ' (<descriptor>)+`

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const scheme = "scip-zig";
pub const manager = "zig";

pub const Suffix = enum {
    namespace,
    type,
    term,
    method,
};

/// `scip-zig zig <name> <version> `, ready for descriptors to be appended
pub fn packagePrefix(gpa: Allocator, name: []const u8, version: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(gpa, scheme ++ " " ++ manager ++ " ");
    try appendPackageField(gpa, &out, name);
    try out.append(gpa, ' ');
    try appendPackageField(gpa, &out, version);
    try out.append(gpa, ' ');
    return out.items;
}

fn appendPackageField(gpa: Allocator, out: *std.ArrayList(u8), value: []const u8) Allocator.Error!void {
    if (value.len == 0) return out.append(gpa, '.');
    for (value) |c| {
        if (c == ' ') try out.append(gpa, ' ');
        try out.append(gpa, c);
    }
}

pub fn appendDescriptor(gpa: Allocator, out: *std.ArrayList(u8), name: []const u8, suffix: Suffix) Allocator.Error!void {
    try appendName(gpa, out, name);
    try out.appendSlice(gpa, switch (suffix) {
        .namespace => "/",
        .type => "#",
        .term => ".",
        .method => "().",
    });
}

pub fn withDescriptor(gpa: Allocator, prefix: []const u8, name: []const u8, suffix: Suffix) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(gpa, prefix);
    try appendDescriptor(gpa, &out, name, suffix);
    return out.items;
}

fn isSimple(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |c| switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '_', '+', '-', '$' => {},
        else => return false,
    };
    return true;
}

fn appendName(gpa: Allocator, out: *std.ArrayList(u8), name: []const u8) Allocator.Error!void {
    if (isSimple(name)) return out.appendSlice(gpa, name);
    try out.append(gpa, '`');
    for (name) |c| {
        if (c == '`') try out.append(gpa, '`');
        try out.append(gpa, c);
    }
    try out.append(gpa, '`');
}

pub fn local(gpa: Allocator, id: u32) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(gpa, "local {d}", .{id});
}

pub fn isLocal(symbol: []const u8) bool {
    return std.mem.startsWith(u8, symbol, "local ");
}
