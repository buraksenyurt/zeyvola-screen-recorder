//! Runs one program and reports what it cost, as one JSON line on stderr (benchmark tool for
//! tools/bench/c-vs-zig.mjs; never shipped):
//!
//!   measure.exe <program> [args…]
//!   → {"wallUs":…,"userUs":…,"kernelUs":…,"cycles":…,"peakWorkingSetKb":…,"peakPrivateKb":…,"exit":…}
//!
//! The program inherits stdin and stdout, so a caller can stream data through it. Times come from
//! the process object itself: GetProcessTimes (counted in scheduler ticks, ~15.6 ms) and
//! QueryProcessCycleTime (CPU cycles of all its threads, precise for short runs); memory from K32GetProcessMemoryInfo, wall time
//! from QueryPerformanceCounter around CreateProcessW … WaitForSingleObject.

const std = @import("std");

const BOOL = i32;
const DWORD = u32;
const HANDLE = *anyopaque;

const STARTUPINFOW = extern struct {
    cb: DWORD,
    lpReserved: ?[*:0]u16 = null,
    lpDesktop: ?[*:0]u16 = null,
    lpTitle: ?[*:0]u16 = null,
    dwX: DWORD = 0,
    dwY: DWORD = 0,
    dwXSize: DWORD = 0,
    dwYSize: DWORD = 0,
    dwXCountChars: DWORD = 0,
    dwYCountChars: DWORD = 0,
    dwFillAttribute: DWORD = 0,
    dwFlags: DWORD = 0,
    wShowWindow: u16 = 0,
    cbReserved2: u16 = 0,
    lpReserved2: ?*u8 = null,
    hStdInput: ?HANDLE = null,
    hStdOutput: ?HANDLE = null,
    hStdError: ?HANDLE = null,
};
const PROCESS_INFORMATION = extern struct { hProcess: HANDLE, hThread: HANDLE, dwProcessId: DWORD, dwThreadId: DWORD };
const FILETIME = extern struct { low: DWORD, high: DWORD };
const PROCESS_MEMORY_COUNTERS = extern struct {
    cb: DWORD,
    PageFaultCount: DWORD = 0,
    PeakWorkingSetSize: usize = 0,
    WorkingSetSize: usize = 0,
    QuotaPeakPagedPoolUsage: usize = 0,
    QuotaPagedPoolUsage: usize = 0,
    QuotaPeakNonPagedPoolUsage: usize = 0,
    QuotaNonPagedPoolUsage: usize = 0,
    PagefileUsage: usize = 0,
    PeakPagefileUsage: usize = 0,
};

const STARTF_USESTDHANDLES: DWORD = 0x100;
const INFINITE: DWORD = 0xFFFF_FFFF;

extern "kernel32" fn GetCommandLineW() callconv(.winapi) [*:0]u16;
extern "kernel32" fn GetStdHandle(which: DWORD) callconv(.winapi) ?HANDLE;
extern "kernel32" fn CreateProcessW(app: ?[*:0]const u16, cmd: [*:0]u16, pa: ?*anyopaque, ta: ?*anyopaque, inherit: BOOL, flags: DWORD, env: ?*anyopaque, cwd: ?[*:0]const u16, si: *STARTUPINFOW, pi: *PROCESS_INFORMATION) callconv(.winapi) BOOL;
extern "kernel32" fn WaitForSingleObject(h: HANDLE, ms: DWORD) callconv(.winapi) DWORD;
extern "kernel32" fn GetExitCodeProcess(h: HANDLE, code: *DWORD) callconv(.winapi) BOOL;
extern "kernel32" fn GetProcessTimes(h: HANDLE, creation: *FILETIME, exit: *FILETIME, kernel: *FILETIME, user: *FILETIME) callconv(.winapi) BOOL;
extern "kernel32" fn QueryProcessCycleTime(h: HANDLE, cycles: *u64) callconv(.winapi) BOOL;
extern "kernel32" fn K32GetProcessMemoryInfo(h: HANDLE, counters: *PROCESS_MEMORY_COUNTERS, cb: DWORD) callconv(.winapi) BOOL;
extern "kernel32" fn QueryPerformanceCounter(v: *i64) callconv(.winapi) BOOL;
extern "kernel32" fn QueryPerformanceFrequency(v: *i64) callconv(.winapi) BOOL;
extern "kernel32" fn WriteFile(h: ?HANDLE, buf: [*]const u8, n: DWORD, written: ?*DWORD, ov: ?*anyopaque) callconv(.winapi) BOOL;
extern "kernel32" fn ExitProcess(code: u32) callconv(.winapi) noreturn;

/// The command line after our own program name (CommandLineToArgvW's rules for argument 0).
fn rest(cmd: [*:0]u16) [*:0]u16 {
    var i: usize = 0;
    if (cmd[0] == '"') {
        i = 1;
        while (cmd[i] != 0 and cmd[i] != '"') i += 1;
        if (cmd[i] == '"') i += 1;
    } else {
        while (cmd[i] != 0 and cmd[i] != ' ' and cmd[i] != '\t') i += 1;
    }
    while (cmd[i] == ' ' or cmd[i] == '\t') i += 1;
    return cmd + i;
}

fn us(t: FILETIME) u64 {
    return ((@as(u64, t.high) << 32) | t.low) / 10; // 100 ns → µs
}

pub fn main() void {
    const child_cmd = rest(GetCommandLineW());
    if (child_cmd[0] == 0) ExitProcess(64);
    var si: STARTUPINFOW = .{
        .cb = @sizeOf(STARTUPINFOW),
        .dwFlags = STARTF_USESTDHANDLES,
        .hStdInput = GetStdHandle(@bitCast(@as(i32, -10))),
        .hStdOutput = GetStdHandle(@bitCast(@as(i32, -11))),
        .hStdError = GetStdHandle(@bitCast(@as(i32, -12))),
    };
    var pi: PROCESS_INFORMATION = undefined;
    var freq: i64 = 0;
    var t0: i64 = 0;
    var t1: i64 = 0;
    _ = QueryPerformanceFrequency(&freq);
    _ = QueryPerformanceCounter(&t0);
    if (CreateProcessW(null, child_cmd, null, null, 1, 0, null, null, &si, &pi) == 0) ExitProcess(127);
    _ = WaitForSingleObject(pi.hProcess, INFINITE);
    _ = QueryPerformanceCounter(&t1);

    var code: DWORD = 0;
    _ = GetExitCodeProcess(pi.hProcess, &code);
    var c: FILETIME = undefined;
    var e: FILETIME = undefined;
    var k: FILETIME = undefined;
    var u: FILETIME = undefined;
    _ = GetProcessTimes(pi.hProcess, &c, &e, &k, &u);
    var cycles: u64 = 0;
    _ = QueryProcessCycleTime(pi.hProcess, &cycles);
    var mem: PROCESS_MEMORY_COUNTERS = .{ .cb = @sizeOf(PROCESS_MEMORY_COUNTERS) };
    _ = K32GetProcessMemoryInfo(pi.hProcess, &mem, mem.cb);

    const wall_us: u64 = @intCast(@divTrunc((t1 - t0) * 1_000_000, freq));
    var buf: [256]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "{{\"wallUs\":{d},\"userUs\":{d},\"kernelUs\":{d},\"cycles\":{d},\"peakWorkingSetKb\":{d},\"peakPrivateKb\":{d},\"exit\":{d}}}\n", .{
        wall_us, us(u), us(k), cycles, mem.PeakWorkingSetSize / 1024, mem.PeakPagefileUsage / 1024, code,
    }) catch unreachable;
    _ = WriteFile(GetStdHandle(@bitCast(@as(i32, -12))), line.ptr, @intCast(line.len), null, null);
    ExitProcess(code);
}
