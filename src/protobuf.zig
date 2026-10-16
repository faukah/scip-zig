// SPDX-License-Identifier: EUPL-1.2
//! minimal protobuf wire-format encoder, just enough for scip.proto

const std = @import("std");
const Allocator = std.mem.Allocator;

const WireType = enum(u3) {
    varint = 0,
    len = 2,
};

pub const Encoder = struct {
    gpa: Allocator,
    buf: std.ArrayList(u8) = .empty,

    pub fn init(gpa: Allocator) Encoder {
        return .{ .gpa = gpa };
    }

    pub fn deinit(e: *Encoder) void {
        e.buf.deinit(e.gpa);
    }

    fn varint(e: *Encoder, value: u64) Allocator.Error!void {
        var v = value;
        while (v >= 0x80) : (v >>= 7) {
            try e.buf.append(e.gpa, @as(u8, @truncate(v)) | 0x80);
        }
        try e.buf.append(e.gpa, @truncate(v));
    }

    fn key(e: *Encoder, field: u32, wire: WireType) Allocator.Error!void {
        try e.varint(@as(u64, field) << 3 | @backingInt(wire));
    }

    fn bytes(e: *Encoder, field: u32, data: []const u8) Allocator.Error!void {
        try e.key(field, .len);
        try e.varint(data.len);
        try e.buf.appendSlice(e.gpa, data);
    }

    /// proto3 scalars equal to their default are omitted from the wire
    pub fn uint(e: *Encoder, field: u32, value: u64) Allocator.Error!void {
        if (value == 0) return;
        try e.key(field, .varint);
        try e.varint(value);
    }

    pub fn int32(e: *Encoder, field: u32, value: i32) Allocator.Error!void {
        if (value == 0) return;
        try e.key(field, .varint);
        // negative int32 is sign extended to 64 bits on the wire
        try e.varint(@bitCast(@as(i64, value)));
    }

    pub fn boolean(e: *Encoder, field: u32, value: bool) Allocator.Error!void {
        try e.uint(field, @intFromBool(value));
    }

    pub fn string(e: *Encoder, field: u32, value: []const u8) Allocator.Error!void {
        if (value.len == 0) return;
        try e.bytes(field, value);
    }

    /// unlike singular strings, every element of a repeated field is kept
    pub fn repeatedString(e: *Encoder, field: u32, values: []const []const u8) Allocator.Error!void {
        for (values) |value| try e.bytes(field, value);
    }

    /// `value` must have `fn encode(self, *Encoder) !void`
    pub fn message(e: *Encoder, field: u32, value: anytype) Allocator.Error!void {
        var child: Encoder = .init(e.gpa);
        defer child.deinit();
        try value.encode(&child);
        try e.bytes(field, child.buf.items);
    }

    pub fn repeatedMessage(e: *Encoder, field: u32, values: anytype) Allocator.Error!void {
        for (values) |value| try e.message(field, value);
    }
};
