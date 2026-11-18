//! One line of JSON output, built in a fixed buffer without any allocation or formatting library.
//! Calls chain: `l.put("{\"now\":").fixed3(t).put("}")`. Text past the buffer is dropped, so a
//! line always fits and always ends in a newline.

const std = @import("std");

pub const Line = struct {
    buf: [512]u8 = undefined,
    len: usize = 0,

    pub fn put(l: *Line, s: []const u8) *Line {
        for (s) |c| {
            if (l.len >= l.buf.len - 2) break; // room for the newline
            l.buf[l.len] = c;
            l.len += 1;
        }
        return l;
    }

    pub fn boolean(l: *Line, v: bool) *Line {
        return l.put(if (v) "true" else "false");
    }

    pub fn int(l: *Line, v: i64) *Line {
        var tmp: [20]u8 = undefined;
        var n: usize = 0;
        var u: u64 = @abs(v);
        while (true) {
            tmp[n] = @intCast('0' + u % 10);
            n += 1;
            u /= 10;
            if (u == 0) break;
        }
        if (v < 0) _ = l.put("-");
        while (n > 0) {
            n -= 1;
            _ = l.put(tmp[n .. n + 1]);
        }
        return l;
    }

    /// Fixed-point with three decimals (enough for millisecond times and wheel notches).
    pub fn fixed3(l: *Line, v: f64) *Line {
        var m: i64 = @intFromFloat(v * 1000.0 + (if (v >= 0) @as(f64, 0.5) else -0.5));
        if (m < 0) {
            _ = l.put("-");
            m = -m;
        }
        _ = l.int(@divTrunc(m, 1000)).put(".");
        const f: u64 = @intCast(@mod(m, 1000));
        const d = [3]u8{ @intCast('0' + f / 100), @intCast('0' + f / 10 % 10), @intCast('0' + f % 10) };
        return l.put(&d);
    }

    /// "0x" and eight lowercase hex digits, the way HRESULTs are printed.
    pub fn hex(l: *Line, v: u32) *Line {
        const digits = "0123456789abcdef";
        var t = "0x00000000".*;
        for (0..8) |i| t[9 - i] = digits[(v >> @intCast(i * 4)) & 0xf];
        return l.put(&t);
    }

    /// The finished line with its newline.
    pub fn bytes(l: *Line) []const u8 {
        l.buf[l.len] = '\n';
        return l.buf[0 .. l.len + 1];
    }
};

fn expectLine(expected: []const u8, l: *Line) !void {
    try std.testing.expectEqualStrings(expected, l.bytes());
}

test "integers" {
    var l: Line = .{};
    try expectLine("0 -1 1234567890 -9223372036854775808\n", l.int(0).put(" ").int(-1).put(" ").int(1234567890).put(" ").int(std.math.minInt(i64)));
}

test "fixed3 rounds to milliseconds" {
    var l: Line = .{};
    try expectLine("422622.437 -0.500 1.000 0.001 -2.346\n", l.fixed3(422622.4374).put(" ").fixed3(-0.5).put(" ").fixed3(0.9996).put(" ").fixed3(0.0006).put(" ").fixed3(-2.3456));
}

test "hex" {
    var l: Line = .{};
    try expectLine("0x80070057 0x00000000\n", l.hex(0x80070057).put(" ").hex(0));
}

test "overlong text is cut and still ends in a newline" {
    var l: Line = .{};
    for (0..100) |_| _ = l.put("0123456789");
    const out = l.bytes();
    try std.testing.expectEqual(@as(usize, 511), out.len);
    try std.testing.expectEqual(@as(u8, '\n'), out[out.len - 1]);
}
