//! Parsing that needs no Windows call: command-line numbers, the "stop" line on stdin and the
//! export packet header. Command-line arguments are UTF-16 (CommandLineToArgvW).

const std = @import("std");

/// A UTF-16, NUL-terminated copy of an ASCII literal, made at compile time (like L"..." in C).
pub fn wide(comptime s: []const u8) *const [s.len:0]u16 {
    return comptime blk: {
        var w: [s.len:0]u16 = undefined;
        for (s, 0..) |c, i| {
            if (c >= 0x80) @compileError("ASCII only");
            w[i] = c;
        }
        const final = w;
        break :blk &final;
    };
}

/// Whether a NUL-terminated UTF-16 argument equals `b` exactly.
pub fn eqlWide(a: [*:0]const u16, b: []const u16) bool {
    var i: usize = 0;
    while (a[i] != 0) : (i += 1) {
        if (i >= b.len or a[i] != b[i]) return false;
    }
    return i == b.len;
}

/// A decimal number from 0 to 1 000 000 000; -1 for anything else (empty, a sign, other characters).
pub fn int(s: [*:0]const u16) i64 {
    if (s[0] == 0) return -1;
    var v: i64 = 0;
    var i: usize = 0;
    while (s[i] != 0) : (i += 1) {
        const c = s[i];
        if (c < '0' or c > '9') return -1;
        v = v * 10 + (c - '0');
        if (v > 1_000_000_000) return -1;
    }
    return v;
}

/// A window handle written in decimal, as in the app's capture source id ("window:<HWND>:0").
/// null for an empty, malformed, overlong or zero value.
pub fn hwnd(s: [*:0]const u16) ?usize {
    var v: u64 = 0;
    var i: usize = 0;
    while (s[i] != 0) : (i += 1) {
        const c = s[i];
        if (c < '0' or c > '9' or v > 0x0FFF_FFFF_FFFF_FFFF) return null;
        v = v * 10 + (c - '0');
    }
    return if (v == 0) null else @intCast(v);
}

/// Watches stdin bytes for a line that is exactly "stop" (LF or CR ends a line).
pub const StopWatch = struct {
    last: [7]u8 = undefined,
    len: usize = 0,

    /// true once a "stop" line has ended.
    pub fn feed(w: *StopWatch, bytes: []const u8) bool {
        for (bytes) |c| {
            if (c == '\n' or c == '\r') {
                if (w.len == 4 and w.last[0] == 's' and w.last[1] == 't' and w.last[2] == 'o' and w.last[3] == 'p') return true;
                w.len = 0;
            } else if (w.len < w.last.len) {
                w.last[w.len] = c;
                w.len += 1;
            }
        }
        return false;
    }
};

/// An export packet header: 24 little-endian bytes before the packet's data.
pub const Packet = struct {
    pub const size = 24;
    pub const Kind = enum(u32) { video = 1, audio = 2, end = 3, _ };

    kind: Kind,
    len: u32,
    /// 100 ns units.
    time: i64,
    duration: i64,

    pub fn decode(h: *const [size]u8) Packet {
        return .{
            .kind = @enumFromInt(le(u32, h[0..4])),
            .len = le(u32, h[4..8]),
            .time = @bitCast(le(u64, h[8..16])),
            .duration = @bitCast(le(u64, h[16..24])),
        };
    }
};

fn le(comptime T: type, b: *const [@sizeOf(T)]u8) T {
    var v: T = 0;
    for (b, 0..) |byte, i| v |= @as(T, byte) << @intCast(i * 8);
    return v;
}

test "wide and eqlWide" {
    try std.testing.expect(eqlWide(wide("--input"), wide("--input")));
    try std.testing.expect(!eqlWide(wide("--input"), wide("--inpu")));
    try std.testing.expect(!eqlWide(wide("--inpu"), wide("--input")));
    try std.testing.expect(eqlWide(wide(""), wide("")));
}

test "int" {
    try std.testing.expectEqual(@as(i64, 1920), int(wide("1920")));
    try std.testing.expectEqual(@as(i64, 0), int(wide("0")));
    try std.testing.expectEqual(@as(i64, 1_000_000_000), int(wide("1000000000")));
    try std.testing.expectEqual(@as(i64, -1), int(wide("1000000001")));
    try std.testing.expectEqual(@as(i64, -1), int(wide("")));
    try std.testing.expectEqual(@as(i64, -1), int(wide("-5")));
    try std.testing.expectEqual(@as(i64, -1), int(wide("12a")));
}

test "hwnd" {
    try std.testing.expectEqual(@as(?usize, 132456), hwnd(wide("132456")));
    try std.testing.expectEqual(@as(?usize, null), hwnd(wide("")));
    try std.testing.expectEqual(@as(?usize, null), hwnd(wide("0")));
    try std.testing.expectEqual(@as(?usize, null), hwnd(wide("0x10")));
    try std.testing.expectEqual(@as(?usize, null), hwnd(wide("99999999999999999999")));
}

test "StopWatch" {
    var w: StopWatch = .{};
    try std.testing.expect(!w.feed("hello\nsto"));
    try std.testing.expect(w.feed("p\n"));
    var x: StopWatch = .{};
    try std.testing.expect(!x.feed("stopped\nxstop\n stop\n"));
    try std.testing.expect(x.feed("stop\r\n"));
}

test "Packet.decode" {
    const h = [_]u8{ 1, 0, 0, 0, 0x00, 0x76, 0x2f, 0x00, 0x15, 0xcd, 0x5b, 0x07, 0, 0, 0, 0, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff };
    const p = Packet.decode(&h);
    try std.testing.expectEqual(Packet.Kind.video, p.kind);
    try std.testing.expectEqual(@as(u32, 1920 * 1080 * 3 / 2), p.len);
    try std.testing.expectEqual(@as(i64, 123456789), p.time);
    try std.testing.expectEqual(@as(i64, -1), p.duration);
}
