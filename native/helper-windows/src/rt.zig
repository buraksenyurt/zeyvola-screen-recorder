//! The memory functions the compiler may call for copies and fills, since neither a C runtime nor
//! compiler-rt is linked. Plain byte loops: the helper never copies much (packet data is read
//! straight into Media Foundation's buffers). The module is built with no_builtin, so these loops
//! are not turned back into calls to themselves.

export fn memset(dest: ?[*]u8, c: c_int, n: usize) callconv(.c) ?[*]u8 {
    const d = dest orelse return dest;
    const byte: u8 = @truncate(@as(c_uint, @bitCast(c)));
    var i: usize = 0;
    while (i < n) : (i += 1) d[i] = byte;
    return dest;
}

export fn memcpy(noalias dest: ?[*]u8, noalias src: ?[*]const u8, n: usize) callconv(.c) ?[*]u8 {
    const d = dest orelse return dest;
    const s = src orelse return dest;
    var i: usize = 0;
    while (i < n) : (i += 1) d[i] = s[i];
    return dest;
}

export fn memmove(dest: ?[*]u8, src: ?[*]const u8, n: usize) callconv(.c) ?[*]u8 {
    const d = dest orelse return dest;
    const s = src orelse return dest;
    if (@intFromPtr(d) < @intFromPtr(s)) {
        var i: usize = 0;
        while (i < n) : (i += 1) d[i] = s[i];
    } else {
        var i: usize = n;
        while (i > 0) {
            i -= 1;
            d[i] = s[i];
        }
    }
    return dest;
}
