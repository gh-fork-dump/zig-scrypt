// SPDX-License-Identifier: MIT
// Copyright (c) 2015-2021 Zig Contributors
// This file is part of [zig](https://ziglang.org/), which is MIT licensed.
// The MIT license requires this copyright notice to be included in all copies
// and substantial portions of the software.

// https://github.com/P-H-C/phc-string-format/blob/master/phc-sf-spec.md
// https://github.com/P-H-C/phc-string-format/pull/4

const std = @import("std");
const base64 = std.base64;
const fmt = std.fmt;
const mem = std.mem;

const b64enc = base64.standard_encoder;
const b64dec = base64.standard_decoder;

const fields_delimiter = "$";
const version_prefix = "v=";
pub const params_delimiter = ",";
pub const kv_delimiter = "=";

const PhcEncodingError = error{
    ParseError,
    InvalidAlgorithm,
};

// TODO add base64 error to Error
pub const Error = PhcEncodingError || mem.Allocator.Error || fmt.ParseIntError;

pub fn PhcEncoding(comptime T: type) type {
    return struct {
        const Self = @This();

        allocator: *mem.Allocator,
        alg_id: []const u8,
        version: ?u32 = null,
        params: ?T = null,
        salt: ?[]u8 = null,
        derived_key: ?[]u8 = null,

        pub fn fromString(allocator: *mem.Allocator, s: []const u8) !Self {
            var it = mem.split(s, fields_delimiter);
            _ = it.next();
            const alg_id = it.next() orelse return error.ParseError;
            if (alg_id.len == 0 or alg_id.len > 32) {
                return error.ParseError;
            }
            var res = Self{ .allocator = allocator, .alg_id = alg_id };
            var s1 = it.next() orelse return res;
            if (mem.startsWith(u8, s1, version_prefix) and
                mem.indexOf(u8, s1, params_delimiter) == null)
            {
                res.version = try fmt.parseInt(u32, s1[version_prefix.len..], 10);
                s1 = it.next() orelse return res;
            }
            if (mem.indexOf(u8, s1, kv_delimiter) != null) {
                res.params = try T.fromPhcString(s1);
            }
            const salt = try b64decode(
                allocator,
                it.next() orelse return res,
            );
            errdefer allocator.free(salt);
            const derived_key = try b64decode(
                allocator,
                it.next() orelse {
                    res.salt = salt;
                    return res;
                },
            );
            errdefer allocator.free(derived_key);
            if (it.next() != null) {
                return error.ParseError;
            }
            res.salt = salt;
            res.derived_key = derived_key;
            return res;
        }

        pub fn check_id(self: *Self, alg_id: []const u8) Error!void {
            if (!mem.eql(u8, self.alg_id, alg_id)) {
                return error.InvalidAlgorithm;
            }
        }

        pub fn deinit(self: *Self) void {
            if (self.salt) |v| {
                self.allocator.free(v);
                self.salt = null;
            }
            if (self.derived_key) |v| {
                self.allocator.free(v);
                self.derived_key = null;
            }
        }

        pub fn toString(self: *Self) ![]const u8 {
            var i: usize = self.alg_id.len + fields_delimiter.len;
            var versionLen: usize = 0;
            if (self.version) |v| {
                versionLen = fmt.count("{s}{s}{d}", .{ fields_delimiter, version_prefix, v });
                i += versionLen;
            }
            var params: []const u8 = undefined;
            if (self.params) |v| {
                params = try v.toPhcString(self.allocator);
                i += params.len + fields_delimiter.len;
            }
            errdefer self.allocator.free(params);
            var salt: []u8 = undefined;
            if (self.salt) |v| {
                salt = try b64encode(self.allocator, v);
                i += salt.len + fields_delimiter.len;
            }
            errdefer self.allocator.free(salt);
            var derived_key: []u8 = undefined;
            if (self.derived_key) |v| {
                derived_key = try b64encode(self.allocator, v);
                i += derived_key.len + fields_delimiter.len;
            }
            errdefer self.allocator.free(derived_key);
            var buf = try self.allocator.alloc(u8, i);
            var w = Writer{ .allocator = self.allocator, .buf = buf };
            w.write(self.alg_id, false);
            if (self.version) |v| {
                _ = fmt.bufPrint(
                    buf[w.pos..],
                    "{s}{s}{d}",
                    .{ fields_delimiter, version_prefix, v },
                ) catch unreachable;
                w.pos += versionLen;
            }
            w.write(params, true);
            w.write(salt, true);
            w.write(derived_key, true);
            return buf;
        }
    };
}

const Writer = struct {
    const Self = @This();

    allocator: *mem.Allocator,
    buf: []u8,
    pos: usize = 0,

    fn write(self: *Self, v: []const u8, free: bool) void {
        if (v.len == 0) {
            return;
        }
        mem.copy(u8, self.buf[self.pos..], fields_delimiter);
        mem.copy(u8, self.buf[self.pos + fields_delimiter.len ..], v);
        self.pos += fields_delimiter.len + v.len;
        if (free) {
            self.allocator.free(v);
        }
    }
};

fn b64encode(allocator: *mem.Allocator, v: []u8) ![]u8 {
    // TODO use base64 encoding without padding
    var buf = try allocator.alloc(u8, base64.Base64Encoder.calcSize(v.len));
    _ = b64enc.encode(buf, v);
    var i: usize = buf.len;
    while (i > 0) : (i -= 1) {
        if (buf[i - 1] != '=') {
            break;
        }
    }
    if (i != buf.len) {
        errdefer allocator.free(buf);
        return allocator.realloc(buf, i);
    }
    return buf;
}

fn b64decode(allocator: *mem.Allocator, s: []const u8) ![]u8 {
    if (s.len == 0) {
        return error.ParseError;
    }
    var buf: []u8 = undefined;
    // TODO use base64 decoding without padding
    if (s.len % 4 != 0) {
        var s1 = try allocator.alloc(u8, s.len + (4 - (s.len % 4)));
        defer allocator.free(s1);
        mem.copy(u8, s1, s);
        mem.set(u8, s1[s.len..], '=');
        buf = try allocator.alloc(u8, try b64dec.calcSize(s1));
        errdefer allocator.free(buf);
        try b64dec.decode(buf, s1);
    } else {
        buf = try allocator.alloc(u8, try b64dec.calcSize(s));
        errdefer allocator.free(buf);
        try b64dec.decode(buf, s);
    }
    return buf;
}

pub const Param = struct {
    const Self = @This();

    key: []const u8,
    value: []const u8,

    pub fn decimal(self: Self, comptime T: type) fmt.ParseIntError!T {
        return fmt.parseInt(T, self.value, 10);
    }
};

pub const ParamsIterator = struct {
    const Self = @This();

    it: mem.SplitIterator,
    limit: usize,
    pos: usize = 0,

    pub fn new(s: []const u8, limit: usize) Self {
        return Self{ .it = mem.split(s, params_delimiter), .limit = limit };
    }

    pub fn next(self: *Self) Error!?Param {
        const s = self.it.next() orelse return null;
        if (self.pos == self.limit) {
            return error.ParseError;
        }
        var it = mem.split(s, kv_delimiter);
        const key = it.next() orelse return error.ParseError;
        if (key.len == 0 or key.len > 32) {
            return error.ParseError;
        }
        const value = it.next() orelse return error.ParseError;
        if (value.len == 0) {
            return error.ParseError;
        }
        if (it.next() != null) {
            return error.ParseError;
        }
        self.pos += 1;
        return Param{ .key = key, .value = value };
    }
};

test "password hashing (phc format)" {
    const scrypt = @import("scrypt.zig");
    const phc = PhcEncoding(scrypt.Params);
    const alloc = std.testing.allocator;
    const s = "$scrypt$v=1$ln=15,r=8,p=1$c2FsdHNhbHQ$dGVzdHBhc3M";
    var v = try phc.fromString(alloc, s);
    defer v.deinit();
    const s1 = try v.toString();
    defer alloc.free(s1);
    std.testing.expectEqualSlices(u8, s, s1);
}
