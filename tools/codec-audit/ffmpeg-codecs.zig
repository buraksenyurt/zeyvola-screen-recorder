//! Lists the codecs and demuxers compiled into a libffmpeg build, through FFmpeg's public API
//! (av_codec_iterate, av_demuxer_iterate, av_codec_is_encoder; https://ffmpeg.org/doxygen/).
//! Only the first fields of AVCodec / AVInputFormat are read; they lead both structs in the
//! public headers. Used by tools/codec-audit.mjs (macOS; built per architecture with
//! `zig build-exe -target <arch>-macos -lc`). Output: one JSON object.
//!
//!   ffmpeg-codecs <libffmpeg>

/// The leading fields of AVCodec.
const Codec = extern struct { name: [*:0]const u8, long_name: ?[*:0]const u8, type: c_int, id: c_int };
/// The leading field of AVInputFormat.
const InputFormat = extern struct { name: [*:0]const u8 };

const builtin = @import("builtin");

/// <dlfcn.h> flags: RTLD_NOW is 2 on macOS and Linux; RTLD_LOCAL is 4 on macOS, 0 on Linux.
const RTLD_NOW = 0x2;
const RTLD_LOCAL = if (builtin.os.tag.isDarwin()) 0x4 else 0;

extern "c" fn dlopen(path: [*:0]const u8, mode: c_int) ?*anyopaque;
extern "c" fn dlsym(handle: *anyopaque, name: [*:0]const u8) ?*anyopaque;
extern "c" fn dlerror() ?[*:0]const u8;
extern "c" fn write(fd: c_int, buf: [*]const u8, n: usize) isize;

fn out(fd: c_int, s: []const u8) void {
    var rest = s;
    while (rest.len > 0) {
        const n = write(fd, rest.ptr, rest.len);
        if (n <= 0) return;
        rest = rest[@intCast(n)..];
    }
}

fn cstr(s: [*:0]const u8) []const u8 {
    var n: usize = 0;
    while (s[n] != 0) n += 1;
    return s[0..n];
}

/// A function of the loaded library, typed; null when it is missing.
fn symbol(comptime T: type, handle: *anyopaque, name: [*:0]const u8) ?T {
    return @ptrCast(@alignCast(dlsym(handle, name) orelse return null));
}

/// Writes `"a","b",…` for every name the iterator yields that `keep` accepts.
fn list(comptime T: type, iterate: *const fn (*?*anyopaque) callconv(.c) ?*const T, keep: anytype) void {
    var it: ?*anyopaque = null;
    var n: usize = 0;
    while (iterate(&it)) |item| {
        if (!keep.accept(item)) continue;
        if (n > 0) out(1, ",");
        out(1, "\"");
        out(1, cstr(item.name));
        out(1, "\"");
        n += 1;
    }
}

const IsEncoder = *const fn (*const Codec) callconv(.c) c_int;

const Encoders = struct {
    is_encoder: IsEncoder,
    want: bool,
    fn accept(self: Encoders, c: *const Codec) bool {
        return (self.is_encoder(c) != 0) == self.want;
    }
};

const All = struct {
    fn accept(_: All, _: *const InputFormat) bool {
        return true;
    }
};

pub export fn main(argc: c_int, argv: [*]const [*:0]const u8) callconv(.c) c_int {
    if (argc < 2) {
        out(2, "usage: ffmpeg-codecs <libffmpeg>\n");
        return 2;
    }
    const h = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL) orelse {
        if (dlerror()) |e| out(2, cstr(e));
        out(2, "\n");
        return 1;
    };
    const codec_iterate = symbol(*const fn (*?*anyopaque) callconv(.c) ?*const Codec, h, "av_codec_iterate");
    const is_encoder = symbol(IsEncoder, h, "av_codec_is_encoder");
    const demuxer_iterate = symbol(*const fn (*?*anyopaque) callconv(.c) ?*const InputFormat, h, "av_demuxer_iterate");
    const version = symbol(*const fn () callconv(.c) [*:0]const u8, h, "av_version_info");
    const license = symbol(*const fn () callconv(.c) [*:0]const u8, h, "avcodec_license");
    if (codec_iterate == null or is_encoder == null or demuxer_iterate == null or version == null or license == null) {
        out(2, "missing FFmpeg API\n");
        return 1;
    }
    out(1, "{\"version\":\"");
    out(1, cstr(version.?()));
    out(1, "\",\"license\":\"");
    out(1, cstr(license.?()));
    out(1, "\",\"decoders\":[");
    list(Codec, codec_iterate.?, Encoders{ .is_encoder = is_encoder.?, .want = false });
    out(1, "],\"encoders\":[");
    list(Codec, codec_iterate.?, Encoders{ .is_encoder = is_encoder.?, .want = true });
    out(1, "],\"demuxers\":[");
    list(InputFormat, demuxer_iterate.?, All{});
    out(1, "]}\n");
    return 0;
}
