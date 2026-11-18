//! The few Windows declarations the helper uses, written for this project so that no third-party
//! binding set is needed to build it (the Zig standard library's Windows bindings are not used
//! either). Names, values, structure layouts and COM method orders follow Microsoft's
//! documentation and Microsoft's own bindings (windows-rs 0.62.2, generated from win32metadata);
//! they describe the Windows interfaces and contain no implementation.
//!
//! x64 only: Windows has a single calling convention there (`.winapi` is the same as `.c`).
//! The functions are declared without a library name; the linker finds them in the import
//! libraries generated from imports/*.def, which list exactly the system DLL functions used.

pub const BOOL = i32;
pub const BYTE = u8;
pub const WORD = u16;
pub const DWORD = u32; // 32-bit on Windows (LLP64)
pub const UINT = u32;
pub const LONG = i32;
pub const HRESULT = i32;
pub const LONGLONG = i64;
pub const ULONGLONG = u64;
pub const LPARAM = isize;
pub const WPARAM = usize;
pub const LRESULT = isize;
pub const UINT_PTR = usize;
pub const WCHAR = u16;
pub const HANDLE = *anyopaque;
pub const HMODULE = *anyopaque;
pub const HHOOK = *anyopaque;
pub const HWND = *anyopaque;

pub const TRUE: BOOL = 1;
pub const FALSE: BOOL = 0;

pub inline fn succeeded(hr: HRESULT) bool {
    return hr >= 0;
}
pub inline fn failed(hr: HRESULT) bool {
    return hr < 0;
}
/// The high 16 bits of the low 32 (HIWORD).
pub inline fn hiword(v: u64) WORD {
    return @truncate(v >> 16);
}

/// The HRESULT for an unsigned 32-bit code as Microsoft prints it (E_FAIL is 0x80004005).
pub inline fn hresult(comptime code: u32) HRESULT {
    return @bitCast(code);
}
pub const E_FAIL = hresult(0x80004005);
pub const E_INVALIDARG = hresult(0x80070057);

pub const GUID = extern struct {
    Data1: u32,
    Data2: u16,
    Data3: u16,
    Data4: [8]u8,

    pub fn eql(a: *const GUID, b: *const GUID) bool {
        const x: *const [16]u8 = @ptrCast(a);
        const y: *const [16]u8 = @ptrCast(b);
        for (x, y) |p, q| if (p != q) return false;
        return true;
    }
};

// ─── kernel32 ────────────────────────────────────────────────────────────────

pub const STD_INPUT_HANDLE: DWORD = @bitCast(@as(i32, -10));
pub const STD_OUTPUT_HANDLE: DWORD = @bitCast(@as(i32, -11));
pub const GENERIC_WRITE: DWORD = 0x40000000;
pub const CREATE_ALWAYS: DWORD = 2;
pub const FILE_ATTRIBUTE_NORMAL: DWORD = 0x80;
pub const FILE_BEGIN: DWORD = 0;
pub const INVALID_HANDLE_VALUE: HANDLE = @ptrFromInt(~@as(usize, 0));

pub const LPTHREAD_START_ROUTINE = *const fn (?*anyopaque) callconv(.winapi) DWORD;
pub const FARPROC = *const fn () callconv(.winapi) isize;

pub extern fn CloseHandle(h: HANDLE) callconv(.winapi) BOOL;
pub extern fn CreateFileW(name: [*:0]const WCHAR, access: DWORD, share: DWORD, security: ?*anyopaque, disposition: DWORD, flags: DWORD, templ: ?HANDLE) callconv(.winapi) HANDLE;
pub extern fn CreateThread(security: ?*anyopaque, stack: usize, start: LPTHREAD_START_ROUTINE, param: ?*anyopaque, flags: DWORD, id: ?*DWORD) callconv(.winapi) ?HANDLE;
pub extern fn DeleteFileW(name: [*:0]const WCHAR) callconv(.winapi) BOOL;
pub extern fn ExitProcess(code: UINT) callconv(.winapi) noreturn;
pub extern fn GetCommandLineW() callconv(.winapi) [*:0]WCHAR;
pub extern fn GetCurrentThreadId() callconv(.winapi) DWORD;
pub extern fn GetLastError() callconv(.winapi) DWORD;
pub extern fn GetModuleHandleW(name: ?[*:0]const WCHAR) callconv(.winapi) ?HMODULE;
pub extern fn GetProcAddress(module: HMODULE, name: [*:0]const u8) callconv(.winapi) ?FARPROC;
pub extern fn GetStdHandle(which: DWORD) callconv(.winapi) ?HANDLE;
pub extern fn GetTickCount64() callconv(.winapi) ULONGLONG;
pub extern fn ReadFile(h: ?HANDLE, buf: [*]u8, n: DWORD, read: ?*DWORD, overlapped: ?*anyopaque) callconv(.winapi) BOOL;
pub extern fn SetFilePointer(h: HANDLE, distance: LONG, high: ?*LONG, method: DWORD) callconv(.winapi) DWORD;
pub extern fn WriteFile(h: ?HANDLE, buf: [*]const u8, n: DWORD, written: ?*DWORD, overlapped: ?*anyopaque) callconv(.winapi) BOOL;

// ─── user32 ──────────────────────────────────────────────────────────────────

pub const HC_ACTION = 0;
pub const WH_MOUSE_LL = 14;
pub const WM_QUIT: UINT = 0x0012;
pub const WM_USER: UINT = 0x0400;
pub const WM_TIMER: UINT = 0x0113;
pub const WM_LBUTTONDOWN: UINT = 0x0201;
pub const WM_LBUTTONUP: UINT = 0x0202;
pub const WM_RBUTTONDOWN: UINT = 0x0204;
pub const WM_RBUTTONUP: UINT = 0x0205;
pub const WM_MBUTTONDOWN: UINT = 0x0207;
pub const WM_MBUTTONUP: UINT = 0x0208;
pub const WM_MOUSEWHEEL: UINT = 0x020A;
pub const WM_XBUTTONDOWN: UINT = 0x020B;
pub const WM_XBUTTONUP: UINT = 0x020C;
pub const WHEEL_DELTA = 120;
pub const PM_NOREMOVE: UINT = 0;
/// DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2, a pseudo handle.
pub const DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2: HANDLE = @ptrFromInt(~@as(usize, 3));

pub const POINT = extern struct { x: LONG, y: LONG };
pub const RECT = extern struct { left: LONG, top: LONG, right: LONG, bottom: LONG };
pub const MSG = extern struct { hwnd: ?HWND, message: UINT, wParam: WPARAM, lParam: LPARAM, time: DWORD, pt: POINT };
pub const MSLLHOOKSTRUCT = extern struct { pt: POINT, mouseData: DWORD, flags: DWORD, time: DWORD, dwExtraInfo: UINT_PTR };
pub const HOOKPROC = *const fn (code: i32, w: WPARAM, l: LPARAM) callconv(.winapi) LRESULT;
pub const TIMERPROC = *const fn (hwnd: ?HWND, msg: UINT, id: UINT_PTR, time: DWORD) callconv(.winapi) void;

pub extern fn CallNextHookEx(hook: ?HHOOK, code: i32, w: WPARAM, l: LPARAM) callconv(.winapi) LRESULT;
pub extern fn DispatchMessageW(msg: *const MSG) callconv(.winapi) LRESULT;
pub extern fn GetMessageW(msg: *MSG, hwnd: ?HWND, min: UINT, max: UINT) callconv(.winapi) BOOL;
pub extern fn GetWindowRect(hwnd: HWND, rect: *RECT) callconv(.winapi) BOOL;
pub extern fn IsIconic(hwnd: HWND) callconv(.winapi) BOOL;
pub extern fn IsWindow(hwnd: HWND) callconv(.winapi) BOOL;
pub extern fn KillTimer(hwnd: ?HWND, id: UINT_PTR) callconv(.winapi) BOOL;
pub extern fn PeekMessageW(msg: *MSG, hwnd: ?HWND, min: UINT, max: UINT, remove: UINT) callconv(.winapi) BOOL;
pub extern fn PostThreadMessageW(thread: DWORD, msg: UINT, w: WPARAM, l: LPARAM) callconv(.winapi) BOOL;
pub extern fn SetTimer(hwnd: ?HWND, id: UINT_PTR, elapse: UINT, proc: ?TIMERPROC) callconv(.winapi) UINT_PTR;
pub extern fn SetWindowsHookExW(id: i32, proc: HOOKPROC, module: ?HMODULE, thread: DWORD) callconv(.winapi) ?HHOOK;
pub extern fn TranslateMessage(msg: *const MSG) callconv(.winapi) BOOL;
pub extern fn UnhookWindowsHookEx(hook: HHOOK) callconv(.winapi) BOOL;

// ─── dwmapi ──────────────────────────────────────────────────────────────────

pub const DWMWA_EXTENDED_FRAME_BOUNDS: DWORD = 9;
pub extern fn DwmGetWindowAttribute(hwnd: HWND, attribute: DWORD, value: *anyopaque, size: DWORD) callconv(.winapi) HRESULT;

// ─── shell32, ole32 ──────────────────────────────────────────────────────────

pub extern fn CommandLineToArgvW(cmd: [*:0]const WCHAR, argc: *i32) callconv(.winapi) ?[*][*:0]WCHAR;
pub const COINIT_MULTITHREADED: DWORD = 0;
pub extern fn CoInitializeEx(reserved: ?*anyopaque, flags: DWORD) callconv(.winapi) HRESULT;

// ─── Media Foundation (mfplat, mfreadwrite) ──────────────────────────────────

pub const MF_VERSION: DWORD = 0x00020070; // MF_SDK_VERSION 2 << 16 | MF_API_VERSION 0x70
pub const MFSTARTUP_LITE: DWORD = 1;
pub const MF_SOURCE_READER_FIRST_AUDIO_STREAM: DWORD = @bitCast(@as(i32, -3));
pub const MF_SOURCE_READER_ALL_STREAMS: DWORD = @bitCast(@as(i32, -2));
pub const MF_SOURCE_READERF_ENDOFSTREAM: DWORD = 0x2;

fn guid(d1: u32, d2: u16, d3: u16, d4: [8]u8) GUID {
    return .{ .Data1 = d1, .Data2 = d2, .Data3 = d3, .Data4 = d4 };
}

// Attribute keys and media types.
pub const MF_MT_MAJOR_TYPE = guid(0x48eba18e, 0xf8c9, 0x4687, .{ 0xbf, 0x11, 0x0a, 0x74, 0xc9, 0xf9, 0x6a, 0x8f });
pub const MF_MT_SUBTYPE = guid(0xf7e34c9a, 0x42e8, 0x4714, .{ 0xb7, 0x4b, 0xcb, 0x29, 0xd7, 0x2c, 0x35, 0xe5 });
pub const MF_MT_AUDIO_BITS_PER_SAMPLE = guid(0xf2deb57f, 0x40fa, 0x4764, .{ 0xaa, 0x33, 0xed, 0x4f, 0x2d, 0x1f, 0xf6, 0x69 });
pub const MF_MT_AUDIO_SAMPLES_PER_SECOND = guid(0x5faeeae7, 0x0290, 0x4c31, .{ 0x9e, 0x8a, 0xc5, 0x34, 0xf6, 0x8d, 0x9d, 0xba });
pub const MF_MT_AUDIO_NUM_CHANNELS = guid(0x37e48bf5, 0x645e, 0x4c5b, .{ 0x89, 0xde, 0xad, 0xa9, 0xe2, 0x9b, 0x69, 0x6a });
// Video keys and types for the MP4 export (the same values tests/media-check/mf-check.ps1 uses on Windows).
pub const MF_MT_FRAME_SIZE = guid(0x1652c33d, 0xd6b2, 0x4012, .{ 0xb8, 0x34, 0x72, 0x03, 0x08, 0x49, 0xa3, 0x7d });
pub const MF_MT_FRAME_RATE = guid(0xc459a2e8, 0x3d2c, 0x4e44, .{ 0xb1, 0x32, 0xfe, 0xe5, 0x15, 0x6c, 0x7b, 0xb0 });
pub const MF_MT_PIXEL_ASPECT_RATIO = guid(0xc6376a1e, 0x8d0a, 0x4027, .{ 0xbe, 0x45, 0x6d, 0x9a, 0x0a, 0xd3, 0x9b, 0xb6 });
pub const MF_MT_INTERLACE_MODE = guid(0xe2724bb8, 0xe676, 0x4806, .{ 0xb4, 0xb2, 0xa8, 0xd6, 0xef, 0xb4, 0x4c, 0xcd });
pub const MF_MT_AVG_BITRATE = guid(0x20332624, 0xfb0d, 0x4d9e, .{ 0xbd, 0x0d, 0xcb, 0xf6, 0x78, 0x6c, 0x10, 0x2e });
pub const MFMediaType_Video = guid(0x73646976, 0x0000, 0x0010, .{ 0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71 });
pub const MFVideoFormat_NV12 = guid(0x3231564e, 0x0000, 0x0010, .{ 0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71 });
pub const MFVideoFormat_H264 = guid(0x34363248, 0x0000, 0x0010, .{ 0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71 });
pub const MFVideoInterlace_Progressive: u32 = 2;
// From Microsoft's win32metadata (github.com/microsoft/win32metadata, commit 15fc870a, files
// generation/WinSDK/RecompiledIdlHeaders/um/mfapi.h and codecapi.h), read 2026-11-13. Only these
// values were taken; Microsoft Learn names them but does not print them.
pub const MF_MT_AUDIO_AVG_BYTES_PER_SECOND = guid(0x1aab75c8, 0xcfef, 0x451c, .{ 0xab, 0x95, 0xac, 0x03, 0x4b, 0x8e, 0x17, 0x31 });
pub const MF_MT_MPEG2_PROFILE = guid(0xad76a80b, 0x2d5c, 0x4e0b, .{ 0xb3, 0x75, 0x64, 0xe5, 0x20, 0x13, 0x70, 0x36 });
pub const eAVEncH264VProfile_High: u32 = 100;
pub const MFMediaType_Audio = guid(0x73647561, 0x0000, 0x0010, .{ 0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71 });
pub const MFAudioFormat_Dolby_AC3 = guid(0xe06d802c, 0xdb46, 0x11cf, .{ 0xb4, 0xd1, 0x00, 0x80, 0x5f, 0x6c, 0xbb, 0xea });

/// Audio subtypes built from a WAVE format tag: {tag-0000-0010-8000-00AA00389B71}.
fn audioTag(tag: u32) GUID {
    return guid(tag, 0x0000, 0x0010, .{ 0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71 });
}
pub const MFAudioFormat_PCM = audioTag(0x0001);
pub const MFAudioFormat_Float = audioTag(0x0003);
pub const MFAudioFormat_MP3 = audioTag(0x0055);
pub const MFAudioFormat_WMAudioV8 = audioTag(0x0161);
pub const MFAudioFormat_WMAudioV9 = audioTag(0x0162);
pub const MFAudioFormat_AAC = audioTag(0x1610);
pub const MFAudioFormat_ALAC = audioTag(0x6c61);
pub const MFAudioFormat_Opus = audioTag(0x704f);
pub const MFAudioFormat_FLAC = audioTag(0xf1ac);

// ─── COM interfaces ──────────────────────────────────────────────────────────
// Only the methods used are typed; the others keep their slot in the table. Each interface is an
// object whose first field points at its method table; the tables nest the way the interfaces
// inherit (IUnknown → IMFAttributes → IMFMediaType / IMFSample), which keeps the slot order.

const Slot = ?*const anyopaque;

fn Unknown(comptime Self: type) type {
    return extern struct {
        QueryInterface: Slot,
        AddRef: Slot,
        Release: *const fn (*Self) callconv(.winapi) u32,
    };
}

/// IMFAttributes: 30 methods after IUnknown.
fn Attributes(comptime Self: type) type {
    return extern struct {
        unknown: Unknown(Self),
        GetItem: Slot,
        GetItemType: Slot,
        CompareItem: Slot,
        Compare: Slot,
        GetUINT32: *const fn (*Self, *const GUID, *u32) callconv(.winapi) HRESULT,
        GetUINT64: Slot,
        GetDouble: Slot,
        GetGUID: *const fn (*Self, *const GUID, *GUID) callconv(.winapi) HRESULT,
        GetStringLength: Slot,
        GetString: Slot,
        GetAllocatedString: Slot,
        GetBlobSize: Slot,
        GetBlob: Slot,
        GetAllocatedBlob: Slot,
        GetUnknown: Slot,
        SetItem: Slot,
        DeleteItem: Slot,
        DeleteAllItems: Slot,
        SetUINT32: *const fn (*Self, *const GUID, u32) callconv(.winapi) HRESULT,
        SetUINT64: *const fn (*Self, *const GUID, u64) callconv(.winapi) HRESULT,
        SetDouble: Slot,
        SetGUID: *const fn (*Self, *const GUID, *const GUID) callconv(.winapi) HRESULT,
        SetString: Slot,
        SetBlob: Slot,
        SetUnknown: Slot,
        LockStore: Slot,
        UnlockStore: Slot,
        GetCount: Slot,
        GetItemByIndex: Slot,
        CopyAllItems: Slot,
    };
}

pub const IMFMediaType = extern struct {
    v: *const extern struct {
        attributes: Attributes(IMFMediaType),
        GetMajorType: Slot,
        IsCompressedFormat: Slot,
        IsEqual: Slot,
        GetRepresentation: Slot,
        FreeRepresentation: Slot,
    },

    pub fn release(self: *IMFMediaType) void {
        _ = self.v.attributes.unknown.Release(self);
    }
    pub fn getUINT32(self: *IMFMediaType, key: *const GUID, value: *u32) HRESULT {
        return self.v.attributes.GetUINT32(self, key, value);
    }
    pub fn getGUID(self: *IMFMediaType, key: *const GUID, value: *GUID) HRESULT {
        return self.v.attributes.GetGUID(self, key, value);
    }
    pub fn setUINT32(self: *IMFMediaType, key: *const GUID, value: u32) void {
        _ = self.v.attributes.SetUINT32(self, key, value);
    }
    pub fn setUINT64(self: *IMFMediaType, key: *const GUID, value: u64) void {
        _ = self.v.attributes.SetUINT64(self, key, value);
    }
    pub fn setGUID(self: *IMFMediaType, key: *const GUID, value: *const GUID) void {
        _ = self.v.attributes.SetGUID(self, key, value);
    }
};

pub const IMFSample = extern struct {
    v: *const extern struct {
        attributes: Attributes(IMFSample),
        GetSampleFlags: Slot,
        SetSampleFlags: Slot,
        GetSampleTime: Slot,
        SetSampleTime: *const fn (*IMFSample, LONGLONG) callconv(.winapi) HRESULT,
        GetSampleDuration: Slot,
        SetSampleDuration: *const fn (*IMFSample, LONGLONG) callconv(.winapi) HRESULT,
        GetBufferCount: Slot,
        GetBufferByIndex: Slot,
        ConvertToContiguousBuffer: *const fn (*IMFSample, *?*IMFMediaBuffer) callconv(.winapi) HRESULT,
        AddBuffer: *const fn (*IMFSample, *IMFMediaBuffer) callconv(.winapi) HRESULT,
        RemoveBufferByIndex: Slot,
        RemoveAllBuffers: Slot,
        GetTotalLength: Slot,
        CopyToBuffer: Slot,
    },

    pub fn release(self: *IMFSample) void {
        _ = self.v.attributes.unknown.Release(self);
    }
    pub fn setSampleTime(self: *IMFSample, time: LONGLONG) void {
        _ = self.v.SetSampleTime(self, time);
    }
    pub fn setSampleDuration(self: *IMFSample, duration: LONGLONG) void {
        _ = self.v.SetSampleDuration(self, duration);
    }
    pub fn convertToContiguousBuffer(self: *IMFSample, out: *?*IMFMediaBuffer) HRESULT {
        return self.v.ConvertToContiguousBuffer(self, out);
    }
    pub fn addBuffer(self: *IMFSample, buffer: *IMFMediaBuffer) void {
        _ = self.v.AddBuffer(self, buffer);
    }
};

pub const IMFMediaBuffer = extern struct {
    v: *const extern struct {
        unknown: Unknown(IMFMediaBuffer),
        Lock: *const fn (*IMFMediaBuffer, *?[*]BYTE, ?*DWORD, ?*DWORD) callconv(.winapi) HRESULT,
        Unlock: *const fn (*IMFMediaBuffer) callconv(.winapi) HRESULT,
        GetCurrentLength: Slot,
        SetCurrentLength: *const fn (*IMFMediaBuffer, DWORD) callconv(.winapi) HRESULT,
        GetMaxLength: Slot,
    },

    pub fn release(self: *IMFMediaBuffer) void {
        _ = self.v.unknown.Release(self);
    }
    pub fn lock(self: *IMFMediaBuffer, data: *?[*]BYTE, max: ?*DWORD, current: ?*DWORD) HRESULT {
        return self.v.Lock(self, data, max, current);
    }
    pub fn unlock(self: *IMFMediaBuffer) void {
        _ = self.v.Unlock(self);
    }
    pub fn setCurrentLength(self: *IMFMediaBuffer, length: DWORD) void {
        _ = self.v.SetCurrentLength(self, length);
    }
};

pub const IMFSourceReader = extern struct {
    v: *const extern struct {
        unknown: Unknown(IMFSourceReader),
        GetStreamSelection: Slot,
        SetStreamSelection: *const fn (*IMFSourceReader, DWORD, BOOL) callconv(.winapi) HRESULT,
        GetNativeMediaType: *const fn (*IMFSourceReader, DWORD, DWORD, *?*IMFMediaType) callconv(.winapi) HRESULT,
        GetCurrentMediaType: *const fn (*IMFSourceReader, DWORD, *?*IMFMediaType) callconv(.winapi) HRESULT,
        SetCurrentMediaType: *const fn (*IMFSourceReader, DWORD, ?*DWORD, *IMFMediaType) callconv(.winapi) HRESULT,
        SetCurrentPosition: Slot,
        ReadSample: *const fn (*IMFSourceReader, DWORD, DWORD, ?*DWORD, *DWORD, *LONGLONG, *?*IMFSample) callconv(.winapi) HRESULT,
        Flush: Slot,
        GetServiceForStream: Slot,
        GetPresentationAttribute: Slot,
    },

    pub fn release(self: *IMFSourceReader) void {
        _ = self.v.unknown.Release(self);
    }
    pub fn setStreamSelection(self: *IMFSourceReader, stream: DWORD, selected: bool) HRESULT {
        return self.v.SetStreamSelection(self, stream, if (selected) TRUE else FALSE);
    }
    pub fn getNativeMediaType(self: *IMFSourceReader, stream: DWORD, index: DWORD, out: *?*IMFMediaType) HRESULT {
        return self.v.GetNativeMediaType(self, stream, index, out);
    }
    pub fn getCurrentMediaType(self: *IMFSourceReader, stream: DWORD, out: *?*IMFMediaType) HRESULT {
        return self.v.GetCurrentMediaType(self, stream, out);
    }
    pub fn setCurrentMediaType(self: *IMFSourceReader, stream: DWORD, media_type: *IMFMediaType) HRESULT {
        return self.v.SetCurrentMediaType(self, stream, null, media_type);
    }
    pub fn readSample(self: *IMFSourceReader, stream: DWORD, control: DWORD, flags: *DWORD, timestamp: *LONGLONG, sample: *?*IMFSample) HRESULT {
        return self.v.ReadSample(self, stream, control, null, flags, timestamp, sample);
    }
};

/// IMFSinkWriter (MP4 export with Windows' own H.264 and AAC encoders). Slot order checked on a
/// real Windows machine by tests/media-check/mf-check.ps1 (AddStream 3 … Finalize 11).
pub const IMFSinkWriter = extern struct {
    v: *const extern struct {
        unknown: Unknown(IMFSinkWriter),
        AddStream: *const fn (*IMFSinkWriter, *IMFMediaType, *DWORD) callconv(.winapi) HRESULT,
        SetInputMediaType: *const fn (*IMFSinkWriter, DWORD, *IMFMediaType, ?*anyopaque) callconv(.winapi) HRESULT,
        BeginWriting: *const fn (*IMFSinkWriter) callconv(.winapi) HRESULT,
        WriteSample: *const fn (*IMFSinkWriter, DWORD, *IMFSample) callconv(.winapi) HRESULT,
        SendStreamTick: Slot,
        PlaceMarker: Slot,
        NotifyEndOfSegment: Slot,
        Flush: Slot,
        Finalize: *const fn (*IMFSinkWriter) callconv(.winapi) HRESULT,
        GetServiceForStream: Slot,
        GetStatistics: Slot,
    },

    pub fn release(self: *IMFSinkWriter) void {
        _ = self.v.unknown.Release(self);
    }
    pub fn addStream(self: *IMFSinkWriter, target: *IMFMediaType, stream: *DWORD) HRESULT {
        return self.v.AddStream(self, target, stream);
    }
    pub fn setInputMediaType(self: *IMFSinkWriter, stream: DWORD, input: *IMFMediaType) HRESULT {
        return self.v.SetInputMediaType(self, stream, input, null);
    }
    pub fn beginWriting(self: *IMFSinkWriter) HRESULT {
        return self.v.BeginWriting(self);
    }
    pub fn writeSample(self: *IMFSinkWriter, stream: DWORD, sample: *IMFSample) HRESULT {
        return self.v.WriteSample(self, stream, sample);
    }
    pub fn finalize(self: *IMFSinkWriter) HRESULT {
        return self.v.Finalize(self);
    }
};

pub extern fn MFStartup(version: DWORD, flags: DWORD) callconv(.winapi) HRESULT;
pub extern fn MFShutdown() callconv(.winapi) HRESULT;
pub extern fn MFCreateMediaType(out: *?*IMFMediaType) callconv(.winapi) HRESULT;
pub extern fn MFCreateSourceReaderFromURL(url: [*:0]const WCHAR, attributes: ?*anyopaque, out: *?*IMFSourceReader) callconv(.winapi) HRESULT;
pub extern fn MFCreateSinkWriterFromURL(url: [*:0]const WCHAR, byte_stream: ?*anyopaque, attributes: ?*anyopaque, out: *?*IMFSinkWriter) callconv(.winapi) HRESULT;
pub extern fn MFCreateMemoryBuffer(max_length: DWORD, out: *?*IMFMediaBuffer) callconv(.winapi) HRESULT;
pub extern fn MFCreateSample(out: *?*IMFSample) callconv(.winapi) HRESULT;

// Layout checks against the documented x64 sizes and slot positions.
comptime {
    if (@sizeOf(MSG) != 48 or @sizeOf(MSLLHOOKSTRUCT) != 32 or @sizeOf(GUID) != 16 or @sizeOf(RECT) != 16) @compileError("struct layout");
    const slot = @sizeOf(usize);
    if (@offsetOf(@typeInfo(@FieldType(IMFSinkWriter, "v")).pointer.child, "AddStream") != 3 * slot) @compileError("IMFSinkWriter.AddStream");
    if (@offsetOf(@typeInfo(@FieldType(IMFSinkWriter, "v")).pointer.child, "Finalize") != 11 * slot) @compileError("IMFSinkWriter.Finalize");
    if (@sizeOf(Attributes(IMFMediaType)) != 33 * slot) @compileError("IMFAttributes size");
    if (@offsetOf(@typeInfo(@FieldType(IMFSourceReader, "v")).pointer.child, "ReadSample") != 9 * slot) @compileError("IMFSourceReader.ReadSample");
    if (@offsetOf(@typeInfo(@FieldType(IMFSample, "v")).pointer.child, "AddBuffer") != 42 * slot) @compileError("IMFSample.AddBuffer");
}
