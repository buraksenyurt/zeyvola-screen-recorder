//! The 44-byte header of a 16-bit PCM WAV file (RIFF, one "fmt " and one "data" chunk).

const std = @import("std");

pub const header_size = 44;
/// The largest data size that keeps the RIFF size field in 32 bits (about 6 h of 48 kHz stereo).
pub const max_data: u64 = 0xFFFF_FFF0 - header_size;

pub fn header(rate: u32, channels: u32, data_bytes: u32) [header_size]u8 {
    var h: [header_size]u8 = undefined;
    @memcpy(h[0..4], "RIFF");
    put32(h[4..8], 36 + data_bytes);
    @memcpy(h[8..16], "WAVEfmt ");
    put32(h[16..20], 16); // fmt chunk size
    put16(h[20..22], 1); // PCM
    put16(h[22..24], @truncate(channels));
    put32(h[24..28], rate);
    put32(h[28..32], rate * channels * 2); // bytes per second
    put16(h[32..34], @truncate(channels * 2)); // block align
    put16(h[34..36], 16); // bits per sample
    @memcpy(h[36..40], "data");
    put32(h[40..44], data_bytes);
    return h;
}

fn put32(p: *[4]u8, v: u32) void {
    for (p, 0..) |*b, i| b.* = @truncate(v >> @intCast(i * 8));
}

fn put16(p: *[2]u8, v: u16) void {
    p[0] = @truncate(v);
    p[1] = @truncate(v >> 8);
}

test "header for 48 kHz stereo" {
    const h = header(48000, 2, 192000);
    const expected = "RIFF" ++ "\x24\xEE\x02\x00" ++ "WAVEfmt " ++ "\x10\x00\x00\x00" ++ "\x01\x00" ++ "\x02\x00" ++
        "\x80\xBB\x00\x00" ++ "\x00\xEE\x02\x00" ++ "\x04\x00" ++ "\x10\x00" ++ "data" ++ "\x00\xEE\x02\x00";
    try std.testing.expectEqualSlices(u8, expected, &h);
}
