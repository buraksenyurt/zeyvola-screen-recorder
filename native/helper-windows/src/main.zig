//! Zeyvola Windows helper. Four modes, all started by the Zeyvola app:
//!
//!   zeyvola-win.exe --input [--window <HWND>]
//!     Reports mouse buttons and the wheel while a screen recording runs (automatic zoom), through
//!     Windows' low-level mouse hook (WH_MOUSE_LL). The keyboard is never hooked or read. Nothing
//!     is written to disk and nothing is sent over the network. With --window (a window recording,
//!     the handle in decimal) it also reports where that window is, so the app can make positions
//!     relative to it: its visible frame (DwmGetWindowAttribute, DWMWA_EXTENDED_FRAME_BOUNDS;
//!     GetWindowRect if that fails), read about 30 times a second and written when it changes.
//!     Nothing else about the window is read. stdout, one JSON object per line:
//!       {"type":"window","at":<s>,"now":<s>,"gx":<px>,"gy":<px>,"w":<px>,"h":<px>}   (--window)
//!       {"type":"ready","now":<s>}
//!       {"e":"d"|"u","b":"l"|"r"|"o","at":<s>,"now":<s>,"gx":<px>,"gy":<px>}   button down / up
//!       {"e":"s","dy":<notches>,"at":<s>,"now":<s>,"gx":<px>,"gy":<px>}       wheel
//!     at = event time, now = time of writing; both in seconds since Windows started
//!     (GetTickCount64 clock, ~16 ms steps). gx/gy are physical pixels in virtual-screen
//!     coordinates (the process is per-monitor DPI aware); the app converts them to its own
//!     coordinates. Exits when stdin closes or a "stop" line arrives.
//!
//!   zeyvola-win.exe --extract-audio <video> <out.wav>
//!     Decodes the first audio track with Windows' own Media Foundation decoders (for example AAC,
//!     which the app's media library does not include) and writes 16-bit PCM WAV. Answers one line:
//!       {"type":"audio","audio":true|false,"converted":true|false,"codec":"aac",...,"error":"..."}
//!
//!   zeyvola-win.exe --encode-mp4 <out.mp4> <width> <height> <fps> <bitrate> <audio 0|1>
//!     Writes an MP4 with Windows' own Media Foundation encoders through the Sink Writer: H.264 video
//!     and, with audio 1, AAC sound (48 kHz stereo). The Sink Writer is created without
//!     MF_READWRITE_ENABLE_HARDWARE_TRANSFORMS, so it uses Windows' software encoders ("H264 Encoder
//!     MFT", "Microsoft AAC Audio Encoder MFT"); the app only comes here when no hardware H.264
//!     encoder is available to it. The file name must end in .mp4 (the Sink Writer picks the
//!     container from it). H.264 High profile, or Baseline if the encoder refuses High; AAC at
//!     192 kbit/s. Answers {"type":"ready","profile":"high"|"baseline"} once the encoders are set up,
//!     then reads packets from stdin, each a 24-byte little-endian header and its data:
//!       u32 kind (1 video, 2 audio, 3 end) · u32 length · i64 time · i64 duration (100 ns units)
//!       video: one NV12 frame (width × height × 3 / 2 bytes) · audio: 16-bit stereo PCM, interleaved
//!     After "end" it finishes the file and answers {"type":"done","frames":<n>,"profile":…}. Any failure:
//!       {"type":"error","stage":"<step>","hr":"0x…"} and exit code 1; the app deletes the file.
//!     stdin closing without "end" (export cancelled) leaves the file unfinished and exits with 2.
//!
//!   zeyvola-win.exe --encode-probe <out.mp4>
//!     The same set-up at 320×180, two frames and 0.1 s of sound, finished and deleted: tells the
//!     app before an export whether this Windows can write MP4 this way ({"type":"done"} or error).
//!
//! Built without any C runtime, compiler-rt or third-party bindings: win.zig declares the Windows
//! functions used, and only Windows system DLLs are linked (import definitions in imports/*.def).
//! The Zig standard library is used for nothing but the panic handler (a trap); see build.zig.

const std = @import("std");
const w = @import("win.zig");
const Line = @import("line.zig").Line;
const parse = @import("parse.zig");
const wav = @import("wav.zig");
const L = parse.wide;

comptime {
    _ = @import("rt.zig");
}

/// A panic (only possible from a bug: release builds carry no safety checks) ends the process.
pub const panic = std.debug.no_panic;

// ─── output ──────────────────────────────────────────────────────────────────

var out_handle: ?w.HANDLE = null;

fn writeAll(h: ?w.HANDLE, bytes: []const u8) void {
    var rest = bytes;
    while (rest.len > 0) {
        var done: w.DWORD = 0;
        const n: w.DWORD = @intCast(@min(rest.len, 0x4000_0000));
        if (w.WriteFile(h, rest.ptr, n, &done, null) == 0 or done == 0) return;
        rest = rest[done..];
    }
}

fn emit(l: *Line) void {
    writeAll(out_handle, l.bytes());
}

fn nowS() f64 {
    return @as(f64, @floatFromInt(w.GetTickCount64())) / 1000.0;
}

// ─── --input ─────────────────────────────────────────────────────────────────

const Button = enum(u3) {
    left = 1,
    right = 2,
    other = 4,

    fn letter(b: Button) []const u8 {
        return switch (b) {
            .left => "l",
            .right => "r",
            .other => "o",
        };
    }
};

var main_thread: w.DWORD = 0;
var buttons: u8 = 0;
var window: ?w.HWND = null; // --window, or null
var last_window: w.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };

/// Hook message time is GetTickCount() (32-bit ms); widen it with the 64-bit clock.
fn eventS(t32: w.DWORD) f64 {
    const now = w.GetTickCount64();
    const back: u32 = @as(u32, @truncate(now)) -% t32; // wraps correctly
    return @as(f64, @floatFromInt(now -% back)) / 1000.0;
}

fn reportButton(b: Button, down: bool, m: *const w.MSLLHOOKSTRUCT) void {
    const bit: u8 = @intFromEnum(b);
    if (((buttons & bit) != 0) == down) return; // each change once
    buttons = if (down) buttons | bit else buttons & ~bit;
    var l: Line = .{};
    _ = l.put("{\"e\":\"").put(if (down) "d" else "u")
        .put("\",\"b\":\"").put(b.letter())
        .put("\",\"at\":").fixed3(eventS(m.time))
        .put(",\"now\":").fixed3(nowS())
        .put(",\"gx\":").int(m.pt.x)
        .put(",\"gy\":").int(m.pt.y)
        .put("}");
    emit(&l);
}

fn mouseProc(code: i32, wp: w.WPARAM, lp: w.LPARAM) callconv(.winapi) w.LRESULT {
    if (code == w.HC_ACTION) {
        const m: *const w.MSLLHOOKSTRUCT = @ptrFromInt(@as(usize, @bitCast(lp)));
        switch (wp) {
            w.WM_LBUTTONDOWN => reportButton(.left, true, m),
            w.WM_LBUTTONUP => reportButton(.left, false, m),
            w.WM_RBUTTONDOWN => reportButton(.right, true, m),
            w.WM_RBUTTONUP => reportButton(.right, false, m),
            w.WM_MBUTTONDOWN, w.WM_XBUTTONDOWN => reportButton(.other, true, m),
            w.WM_MBUTTONUP, w.WM_XBUTTONUP => reportButton(.other, false, m),
            w.WM_MOUSEWHEEL => {
                const notches = @as(f64, @floatFromInt(@as(i16, @bitCast(w.hiword(m.mouseData))))) / w.WHEEL_DELTA;
                var l: Line = .{};
                _ = l.put("{\"e\":\"s\",\"dy\":").fixed3(notches)
                    .put(",\"at\":").fixed3(eventS(m.time))
                    .put(",\"now\":").fixed3(nowS())
                    .put(",\"gx\":").int(m.pt.x)
                    .put(",\"gy\":").int(m.pt.y)
                    .put("}");
                emit(&l);
            },
            else => {},
        }
    }
    // Never swallow input: the event always goes on to the other applications.
    return w.CallNextHookEx(null, code, wp, lp);
}

/// Writes the window's bounds when they changed. Minimized or closed windows keep their last bounds.
fn reportWindow() void {
    const hwnd = window orelse return;
    if (w.IsWindow(hwnd) == 0 or w.IsIconic(hwnd) != 0) return;
    const at = nowS();
    var r: w.RECT = undefined;
    if (w.failed(w.DwmGetWindowAttribute(hwnd, w.DWMWA_EXTENDED_FRAME_BOUNDS, &r, @sizeOf(w.RECT))) and w.GetWindowRect(hwnd, &r) == 0) return;
    if (r.right <= r.left or r.bottom <= r.top) return;
    if (r.left == last_window.left and r.top == last_window.top and r.right == last_window.right and r.bottom == last_window.bottom) return;
    last_window = r;
    var l: Line = .{};
    _ = l.put("{\"type\":\"window\",\"at\":").fixed3(at)
        .put(",\"now\":").fixed3(nowS())
        .put(",\"gx\":").int(r.left)
        .put(",\"gy\":").int(r.top)
        .put(",\"w\":").int(@as(i64, r.right) - r.left)
        .put(",\"h\":").int(@as(i64, r.bottom) - r.top)
        .put("}");
    emit(&l);
}

/// Waits for "stop" or the end of stdin, then ends the message loop.
fn stdinWatch(_: ?*anyopaque) callconv(.winapi) w.DWORD {
    const in = w.GetStdHandle(w.STD_INPUT_HANDLE);
    var buf: [64]u8 = undefined;
    var watch: parse.StopWatch = .{};
    while (true) {
        var n: w.DWORD = 0;
        if (w.ReadFile(in, &buf, buf.len, &n, null) == 0 or n == 0) break;
        if (watch.feed(buf[0..n])) break;
    }
    _ = w.PostThreadMessageW(main_thread, w.WM_QUIT, 0, 0);
    return 0;
}

fn runInput(target: ?w.HWND) u8 {
    // Physical pixels everywhere (Windows 10 1703+); older systems keep their default.
    if (w.GetModuleHandleW(L("user32.dll"))) |user32| {
        if (w.GetProcAddress(user32, "SetProcessDpiAwarenessContext")) |proc| {
            const setContext: *const fn (w.HANDLE) callconv(.winapi) w.BOOL = @ptrCast(proc);
            _ = setContext(w.DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
        }
    }

    main_thread = w.GetCurrentThreadId();
    var msg: w.MSG = undefined;
    _ = w.PeekMessageW(&msg, null, w.WM_USER, w.WM_USER, w.PM_NOREMOVE); // create the message queue
    const hook = w.SetWindowsHookExW(w.WH_MOUSE_LL, &mouseProc, w.GetModuleHandleW(null), 0) orelse {
        var l: Line = .{};
        _ = l.put("{\"type\":\"error\",\"code\":\"hook\",\"win32\":").int(w.GetLastError()).put("}");
        emit(&l);
        return 2;
    };
    // The window's bounds go out before "ready", so the app knows them when recording starts.
    window = target;
    reportWindow();
    const timer: w.UINT_PTR = if (window != null) w.SetTimer(null, 0, 33, null) else 0;
    var r: Line = .{};
    _ = r.put("{\"type\":\"ready\",\"now\":").fixed3(nowS()).put("}");
    emit(&r);
    if (w.CreateThread(null, 0, &stdinWatch, null, 0, null)) |t| _ = w.CloseHandle(t);
    while (w.GetMessageW(&msg, null, 0, 0) > 0) {
        if (msg.message == w.WM_TIMER and msg.hwnd == null) {
            reportWindow();
            continue;
        }
        _ = w.TranslateMessage(&msg);
        _ = w.DispatchMessageW(&msg);
    }
    if (timer != 0) _ = w.KillTimer(null, timer);
    _ = w.UnhookWindowsHookEx(hook);
    return 0;
}

// ─── --extract-audio ─────────────────────────────────────────────────────────

const Codec = enum {
    aac,
    mp3,
    pcm,
    @"pcm-float",
    ac3,
    wma,
    alac,
    flac,
    opus,
    other,

    fn of(g: *const w.GUID) Codec {
        const table = [_]struct { w.GUID, Codec }{
            .{ w.MFAudioFormat_AAC, .aac },
            .{ w.MFAudioFormat_MP3, .mp3 },
            .{ w.MFAudioFormat_PCM, .pcm },
            .{ w.MFAudioFormat_Float, .@"pcm-float" },
            .{ w.MFAudioFormat_Dolby_AC3, .ac3 },
            .{ w.MFAudioFormat_WMAudioV8, .wma },
            .{ w.MFAudioFormat_WMAudioV9, .wma },
            .{ w.MFAudioFormat_ALAC, .alac },
            .{ w.MFAudioFormat_FLAC, .flac },
            .{ w.MFAudioFormat_Opus, .opus },
        };
        for (&table) |*e| if (e[0].eql(g)) return e[1];
        return .other;
    }

    /// Formats the app's media library plays itself: nothing to convert.
    fn playsWithoutConversion(c: Codec) bool {
        return switch (c) {
            .opus, .flac, .mp3, .pcm => true,
            else => false,
        };
    }
};

const AudioAnswer = struct {
    audio: bool,
    converted: bool = false,
    codec: ?Codec = null,
    err: ?[]const u8 = null,
    rate: u32 = 0,
    channels: u32 = 0,
    ms: ?u64 = null,
};

fn answerAudio(a: AudioAnswer) void {
    var l: Line = .{};
    _ = l.put("{\"type\":\"audio\",\"audio\":").boolean(a.audio)
        .put(",\"converted\":").boolean(a.converted);
    if (a.codec) |c| _ = l.put(",\"codec\":\"").put(@tagName(c)).put("\",\"from\":\"").put(@tagName(c)).put("\"");
    if (a.rate != 0) _ = l.put(",\"sampleRate\":").int(a.rate).put(",\"channels\":").int(a.channels);
    if (a.ms) |ms| _ = l.put(",\"durationMs\":").int(@intCast(ms));
    if (a.err) |e| _ = l.put(",\"error\":\"").put(e).put("\"");
    _ = l.put("}");
    emit(&l);
}

/// Silence written for sound that starts after the video.
var zeros: [4096]u8 = @splat(0);

fn runExtract(in: [*:0]const u16, out_path: [*:0]const u16) u8 {
    if (w.failed(w.CoInitializeEx(null, w.COINIT_MULTITHREADED))) {
        answerAudio(.{ .audio = false, .err = "com" });
        return 1;
    }
    if (w.failed(w.MFStartup(w.MF_VERSION, w.MFSTARTUP_LITE))) {
        answerAudio(.{ .audio = false, .err = "mfstartup" });
        return 1;
    }
    var reader_opt: ?*w.IMFSourceReader = null;
    if (w.failed(w.MFCreateSourceReaderFromURL(in, null, &reader_opt))) {
        answerAudio(.{ .audio = false, .err = "open" });
        return 1;
    }
    const reader = reader_opt.?;
    const stream = w.MF_SOURCE_READER_FIRST_AUDIO_STREAM;
    _ = reader.setStreamSelection(w.MF_SOURCE_READER_ALL_STREAMS, false);
    if (w.failed(reader.setStreamSelection(stream, true))) {
        answerAudio(.{ .audio = false }); // no audio track
        return 0;
    }

    var codec: Codec = .other;
    var native: ?*w.IMFMediaType = null;
    if (w.succeeded(reader.getNativeMediaType(stream, 0, &native))) {
        var sub: w.GUID = undefined;
        if (w.succeeded(native.?.getGUID(&w.MF_MT_SUBTYPE, &sub))) codec = Codec.of(&sub);
        native.?.release();
    }

    if (codec.playsWithoutConversion()) {
        answerAudio(.{ .audio = true, .codec = codec });
        reader.release();
        _ = w.MFShutdown();
        return 0;
    }

    var want: ?*w.IMFMediaType = null;
    if (w.failed(w.MFCreateMediaType(&want))) {
        answerAudio(.{ .audio = true, .codec = codec, .err = "no-decoder" });
        return 0;
    }
    want.?.setGUID(&w.MF_MT_MAJOR_TYPE, &w.MFMediaType_Audio);
    want.?.setGUID(&w.MF_MT_SUBTYPE, &w.MFAudioFormat_PCM);
    want.?.setUINT32(&w.MF_MT_AUDIO_BITS_PER_SAMPLE, 16);
    const set = reader.setCurrentMediaType(stream, want.?);
    want.?.release();
    if (w.failed(set)) {
        answerAudio(.{ .audio = true, .codec = codec, .err = "no-decoder" });
        return 0;
    }
    var rate: u32 = 0;
    var channels: u32 = 0;
    var got: ?*w.IMFMediaType = null;
    if (w.succeeded(reader.getCurrentMediaType(stream, &got))) {
        _ = got.?.getUINT32(&w.MF_MT_AUDIO_SAMPLES_PER_SECOND, &rate);
        _ = got.?.getUINT32(&w.MF_MT_AUDIO_NUM_CHANNELS, &channels);
        got.?.release();
    }
    if (rate == 0 or channels == 0) {
        answerAudio(.{ .audio = true, .codec = codec, .err = "format" });
        return 0;
    }

    const f = w.CreateFileW(out_path, w.GENERIC_WRITE, 0, null, w.CREATE_ALWAYS, w.FILE_ATTRIBUTE_NORMAL, null);
    if (f == w.INVALID_HANDLE_VALUE) {
        answerAudio(.{ .audio = true, .codec = codec, .err = "write", .rate = rate, .channels = channels });
        return 1;
    }
    var header = wav.header(rate, channels, 0);
    writeAll(f, &header);

    var bytes: u64 = 0;
    const frame: u64 = @as(u64, channels) * 2;
    var first = true;
    const Failure = enum { none, decode, too_long };
    var failure: Failure = .none;
    while (true) {
        var flags: w.DWORD = 0;
        var ts: w.LONGLONG = 0;
        var sample_opt: ?*w.IMFSample = null;
        if (w.failed(reader.readSample(stream, 0, &flags, &ts, &sample_opt))) {
            failure = .decode;
            break;
        }
        if (flags & w.MF_SOURCE_READERF_ENDOFSTREAM != 0) {
            if (sample_opt) |s| s.release();
            break;
        }
        const sample = sample_opt orelse continue;
        if (first) {
            // Sound that starts after the video: keep the delay as silence so it stays in sync.
            first = false;
            if (ts > 0) {
                var pad: u64 = (@as(u64, @intCast(ts)) * rate / 10_000_000) * frame;
                bytes += pad;
                while (pad > 0) {
                    const n: usize = @intCast(@min(pad, zeros.len));
                    writeAll(f, zeros[0..n]);
                    pad -= n;
                }
            }
        }
        var buf_opt: ?*w.IMFMediaBuffer = null;
        if (w.succeeded(sample.convertToContiguousBuffer(&buf_opt))) {
            const buf = buf_opt.?;
            var data: ?[*]w.BYTE = null;
            var len: w.DWORD = 0;
            if (w.succeeded(buf.lock(&data, null, &len))) {
                if (data) |d| writeAll(f, d[0..len]);
                bytes += len;
                buf.unlock();
            }
            buf.release();
        }
        sample.release();
        if (bytes > wav.max_data) { // WAV size limit (about 6 h of 48 kHz stereo)
            failure = .too_long;
            break;
        }
    }
    // Patch the sizes into the header.
    header = wav.header(rate, channels, @intCast(@min(bytes, wav.max_data)));
    _ = w.SetFilePointer(f, 0, null, w.FILE_BEGIN);
    writeAll(f, &header);
    _ = w.CloseHandle(f);
    reader.release();
    _ = w.MFShutdown();
    switch (failure) {
        .none => {},
        .decode, .too_long => {
            _ = w.DeleteFileW(out_path);
            answerAudio(.{ .audio = true, .codec = codec, .err = if (failure == .too_long) "too-long" else "decode", .rate = rate, .channels = channels });
            return 1;
        },
    }
    answerAudio(.{ .audio = true, .converted = true, .codec = codec, .rate = rate, .channels = channels, .ms = bytes / frame * 1000 / rate });
    return 0;
}

// ─── --encode-mp4 / --encode-probe ───────────────────────────────────────────

const sample_rate: u32 = 48000;
const channel_count: u32 = 2;

/// The step that failed, as the app reads it from {"type":"error","stage":…}.
const Stage = enum { com, mfstartup, create, @"video-type", @"video-stream", @"video-encoder", @"audio-type", @"audio-stream", @"audio-encoder", begin, buffer, sample, @"audio-write", @"video-write", packet, finalize };

const EncodeError = error{
    /// Reported on stdout; exit code 1.
    Failed,
    /// stdin closed in the middle of the export; exit code 2.
    Cancelled,
};

fn encodeFail(stage: Stage, hr: w.HRESULT) EncodeError {
    var l: Line = .{};
    _ = l.put("{\"type\":\"error\",\"stage\":\"").put(@tagName(stage)).put("\",\"hr\":\"").hex(@bitCast(hr)).put("\"}");
    emit(&l);
    return error.Failed;
}

fn exitCode(e: EncodeError) u8 {
    return switch (e) {
        error.Failed => 1,
        error.Cancelled => 2,
    };
}

const Profile = enum { high, baseline };

const Encoder = struct {
    writer: *w.IMFSinkWriter = undefined,
    video: w.DWORD = 0,
    audio: w.DWORD = 0,
    profile: Profile = .high,

    fn videoType(subtype: *const w.GUID, width: u32, height: u32, fps: u32, bitrate: u32, profile: u32) ?*w.IMFMediaType {
        var t: ?*w.IMFMediaType = null;
        if (w.failed(w.MFCreateMediaType(&t))) return null;
        const mt = t.?;
        mt.setGUID(&w.MF_MT_MAJOR_TYPE, &w.MFMediaType_Video);
        mt.setGUID(&w.MF_MT_SUBTYPE, subtype);
        if (bitrate != 0) mt.setUINT32(&w.MF_MT_AVG_BITRATE, bitrate);
        if (profile != 0) mt.setUINT32(&w.MF_MT_MPEG2_PROFILE, profile);
        mt.setUINT32(&w.MF_MT_INTERLACE_MODE, w.MFVideoInterlace_Progressive);
        mt.setUINT64(&w.MF_MT_FRAME_SIZE, (@as(u64, width) << 32) | height);
        mt.setUINT64(&w.MF_MT_FRAME_RATE, (@as(u64, fps) << 32) | 1);
        mt.setUINT64(&w.MF_MT_PIXEL_ASPECT_RATIO, (1 << 32) | 1);
        return mt;
    }

    // AAC encoder (Microsoft Learn, "AAC Encoder"): input 16-bit PCM at 44.1 or 48 kHz, 1, 2 or 6
    // channels; output AAC with the same rate and channels, at 12000, 16000, 20000 or 24000 bytes/s.
    // 24000 bytes/s (192 kbit/s) matches the app's other AAC and Opus exports.
    fn audioType(subtype: *const w.GUID) ?*w.IMFMediaType {
        var t: ?*w.IMFMediaType = null;
        if (w.failed(w.MFCreateMediaType(&t))) return null;
        const mt = t.?;
        mt.setGUID(&w.MF_MT_MAJOR_TYPE, &w.MFMediaType_Audio);
        mt.setGUID(&w.MF_MT_SUBTYPE, subtype);
        mt.setUINT32(&w.MF_MT_AUDIO_BITS_PER_SAMPLE, 16);
        mt.setUINT32(&w.MF_MT_AUDIO_SAMPLES_PER_SECOND, sample_rate);
        mt.setUINT32(&w.MF_MT_AUDIO_NUM_CHANNELS, channel_count);
        if (subtype.eql(&w.MFAudioFormat_AAC)) mt.setUINT32(&w.MF_MT_AUDIO_AVG_BYTES_PER_SECOND, 24000);
        return mt;
    }

    const Failure = struct { stage: Stage, hr: w.HRESULT };

    /// Creates the Sink Writer with its H.264 stream; null, or the failing step.
    fn openVideo(e: *Encoder, writer_out: *?*w.IMFSinkWriter, path: [*:0]const u16, width: u32, height: u32, fps: u32, bitrate: u32, profile: u32) ?Failure {
        var hr = w.MFCreateSinkWriterFromURL(path, null, null, writer_out);
        if (w.failed(hr)) return .{ .stage = .create, .hr = hr };
        const writer = writer_out.*.?;
        const out = videoType(&w.MFVideoFormat_H264, width, height, fps, bitrate, profile) orelse return .{ .stage = .@"video-type", .hr = w.E_FAIL };
        hr = writer.addStream(out, &e.video);
        out.release();
        if (w.failed(hr)) return .{ .stage = .@"video-stream", .hr = hr };
        const in = videoType(&w.MFVideoFormat_NV12, width, height, fps, 0, 0) orelse return .{ .stage = .@"video-type", .hr = w.E_FAIL };
        hr = writer.setInputMediaType(e.video, in);
        in.release();
        if (w.failed(hr)) return .{ .stage = .@"video-encoder", .hr = hr };
        return null;
    }

    /// Sets up the Sink Writer. H.264 High profile first (better picture at the same bit rate); if
    /// the encoder refuses it, the documented default (Baseline).
    fn open(path: [*:0]const u16, width: u32, height: u32, fps: u32, bitrate: u32, audio: bool) EncodeError!Encoder {
        var hr = w.CoInitializeEx(null, w.COINIT_MULTITHREADED);
        if (w.failed(hr)) return encodeFail(.com, hr);
        hr = w.MFStartup(w.MF_VERSION, 0);
        if (w.failed(hr)) return encodeFail(.mfstartup, hr);
        var e: Encoder = .{};
        var writer: ?*w.IMFSinkWriter = null;
        var failure = e.openVideo(&writer, path, width, height, fps, bitrate, w.eAVEncH264VProfile_High);
        if (failure) |f| {
            if (f.stage != .create) {
                if (writer) |wr| wr.release();
                writer = null;
                _ = w.DeleteFileW(path);
                failure = e.openVideo(&writer, path, width, height, fps, bitrate, 0);
                e.profile = .baseline;
            }
        }
        if (failure) |f| return encodeFail(f.stage, f.hr);
        e.writer = writer.?;
        if (audio) {
            const aout = audioType(&w.MFAudioFormat_AAC) orelse return encodeFail(.@"audio-type", w.E_FAIL);
            hr = e.writer.addStream(aout, &e.audio);
            aout.release();
            if (w.failed(hr)) return encodeFail(.@"audio-stream", hr);
            const ain = audioType(&w.MFAudioFormat_PCM) orelse return encodeFail(.@"audio-type", w.E_FAIL);
            hr = e.writer.setInputMediaType(e.audio, ain);
            ain.release();
            if (w.failed(hr)) return encodeFail(.@"audio-encoder", hr);
        }
        hr = e.writer.beginWriting();
        if (w.failed(hr)) return encodeFail(.begin, hr);
        return e;
    }

    /// One sample of `len` bytes; `source.fill` copies them into the buffer (from stdin, or test
    /// data) and returns false when stdin ended in the middle of the packet.
    fn write(e: *Encoder, audio: bool, len: u32, time: i64, duration: i64, source: anytype) EncodeError!void {
        var buf_opt: ?*w.IMFMediaBuffer = null;
        var hr = w.MFCreateMemoryBuffer(len, &buf_opt);
        if (w.failed(hr)) return encodeFail(.buffer, hr);
        const buf = buf_opt.?;
        defer buf.release();
        var data: ?[*]w.BYTE = null;
        hr = buf.lock(&data, null, null);
        if (w.failed(hr)) return encodeFail(.buffer, hr);
        const ok = source.fill(data.?[0..len]);
        buf.unlock();
        if (!ok) return error.Cancelled;
        buf.setCurrentLength(len);
        var sample_opt: ?*w.IMFSample = null;
        hr = w.MFCreateSample(&sample_opt);
        if (w.failed(hr)) return encodeFail(.sample, hr);
        const sample = sample_opt.?;
        defer sample.release();
        sample.addBuffer(buf);
        sample.setSampleTime(time);
        sample.setSampleDuration(if (duration > 0) duration else 1); // never zero (AAC encoder note)
        hr = e.writer.writeSample(if (audio) e.audio else e.video, sample);
        if (w.failed(hr)) return encodeFail(if (audio) .@"audio-write" else .@"video-write", hr);
    }

    /// Finishes the file; the writer is released either way.
    fn finish(e: *Encoder) EncodeError!void {
        const hr = e.writer.finalize();
        e.writer.release();
        _ = w.MFShutdown();
        if (w.failed(hr)) return encodeFail(.finalize, hr);
    }
};

/// Packet data straight from stdin.
const Stdin = struct {
    handle: ?w.HANDLE,

    fn fill(s: Stdin, dst: []u8) bool {
        var rest = dst;
        while (rest.len > 0) {
            var got: w.DWORD = 0;
            if (w.ReadFile(s.handle, rest.ptr, @intCast(rest.len), &got, null) == 0 or got == 0) return false;
            rest = rest[got..];
        }
        return true;
    }
};

fn runEncode(path: [*:0]const u16, width: u32, height: u32, fps: u32, bitrate: u32, audio: bool) EncodeError!void {
    var e = try Encoder.open(path, width, height, fps, bitrate, audio);
    var ready: Line = .{};
    _ = ready.put("{\"type\":\"ready\",\"profile\":\"").put(@tagName(e.profile)).put("\"}");
    emit(&ready);
    const frames = encodePackets(&e, width * height * 3 / 2, audio) catch |err| {
        if (err == error.Cancelled) e.writer.release(); // the file stays unfinished
        return err;
    };
    try e.finish();
    var l: Line = .{};
    _ = l.put("{\"type\":\"done\",\"frames\":").int(frames).put(",\"profile\":\"").put(@tagName(e.profile)).put("\"}");
    emit(&l);
}

/// Packets from stdin up to "end"; the number of video frames written.
fn encodePackets(e: *Encoder, frame_bytes: u32, audio: bool) EncodeError!i64 {
    const stdin: Stdin = .{ .handle = w.GetStdHandle(w.STD_INPUT_HANDLE) };
    var frames: i64 = 0;
    while (true) {
        var head: [parse.Packet.size]u8 = undefined;
        if (!stdin.fill(&head)) return error.Cancelled;
        const p = parse.Packet.decode(&head);
        const valid = switch (p.kind) {
            .end => return frames,
            .video => p.len == frame_bytes,
            .audio => audio and p.len != 0 and p.len % 4 == 0 and p.len <= 4 * sample_rate,
            _ => false,
        };
        if (!valid) return encodeFail(.packet, w.E_INVALIDARG);
        try e.write(p.kind == .audio, p.len, p.time, p.duration, stdin);
        if (p.kind == .video) frames += 1;
    }
}

/// A moving grey ramp, the probe's video frames.
const ProbeVideo = struct {
    frame: u32,
    width: u32,
    height: u32,

    fn fill(p: ProbeVideo, dst: []u8) bool {
        const luma = p.width * p.height;
        for (dst, 0..) |*b, i| {
            const j: u32 = @intCast(i);
            b.* = if (j < luma) @truncate((j % p.width) + p.frame * 16) else 128;
        }
        return true;
    }
};

/// A square wave, the probe's sound.
const ProbeAudio = struct {
    fn fill(_: ProbeAudio, dst: []u8) bool {
        for (dst, 0..) |*b, i| b.* = if (i & 64 != 0) 0x10 else 0xf0;
        return true;
    }
};

fn runEncodeProbe(path: [*:0]const u16) EncodeError!void {
    defer _ = w.DeleteFileW(path);
    const width = 320;
    const height = 180;
    const fps = 30;
    var e = try Encoder.open(path, width, height, fps, 1_000_000, true);
    for (0..2) |i| {
        const n: i64 = @intCast(i);
        try e.write(false, width * height * 3 / 2, @divTrunc(n * 10_000_000, fps), 10_000_000 / fps, ProbeVideo{ .frame = @intCast(i), .width = width, .height = height });
    }
    const pcm = sample_rate / 10 * channel_count * 2; // 0.1 s
    try e.write(true, pcm, 0, 1_000_000, ProbeAudio{});
    try e.finish();
    var l: Line = .{};
    _ = l.put("{\"type\":\"done\",\"frames\":2,\"profile\":\"").put(@tagName(e.profile)).put("\"}");
    emit(&l);
}

// ─── entry ───────────────────────────────────────────────────────────────────

/// Exit code for a malformed command line (EX_USAGE).
const usage: u8 = 64;

fn run() u8 {
    out_handle = w.GetStdHandle(w.STD_OUTPUT_HANDLE);
    var argc: i32 = 0;
    const argv = w.CommandLineToArgvW(w.GetCommandLineW(), &argc) orelse return usage;
    if (argc < 2) return usage;
    const n: usize = @intCast(argc);
    const mode = argv[1];
    if (parse.eqlWide(mode, L("--input"))) {
        var target: ?w.HWND = null;
        if (n >= 4 and parse.eqlWide(argv[2], L("--window"))) {
            target = @ptrFromInt(parse.hwnd(argv[3]) orelse return usage);
        }
        return runInput(target);
    }
    if (parse.eqlWide(mode, L("--extract-audio")) and n >= 4) return runExtract(argv[2], argv[3]);
    if (parse.eqlWide(mode, L("--encode-mp4")) and n >= 8) {
        const width = parse.int(argv[3]);
        const height = parse.int(argv[4]);
        const fps = parse.int(argv[5]);
        const bitrate = parse.int(argv[6]);
        const audio = parse.int(argv[7]);
        if (width < 16 or height < 16 or width > 8192 or height > 8192 or @rem(width, 2) != 0 or @rem(height, 2) != 0 or
            fps < 1 or fps > 240 or bitrate < 1 or (audio != 0 and audio != 1)) return usage;
        runEncode(argv[2], @intCast(width), @intCast(height), @intCast(fps), @intCast(bitrate), audio == 1) catch |e| return exitCode(e);
        return 0;
    }
    if (parse.eqlWide(mode, L("--encode-probe")) and n >= 3) {
        runEncodeProbe(argv[2]) catch |e| return exitCode(e);
        return 0;
    }
    if (parse.eqlWide(mode, L("--version"))) {
        var l: Line = .{};
        _ = l.put("{\"type\":\"version\",\"version\":\"0.1.0\"}");
        emit(&l);
        return 0;
    }
    return usage;
}

/// The process entry point (the linker's /ENTRY). Declaring it here also keeps the standard
/// library's start-up code out of the program.
pub export fn wWinMainCRTStartup() callconv(.winapi) noreturn {
    w.ExitProcess(run());
}
