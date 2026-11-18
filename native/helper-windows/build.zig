//! Builds the Zeyvola Windows helper (x64) with Zig, on Windows, macOS or Linux:
//!
//!   zig build                 → zig-out/bin/zeyvola-win.exe (unsigned)
//!   zig build --prefix .      → bin/zeyvola-win.exe (what build.sh and package.mjs run)
//!   zig build test            → unit tests of the parts that need no Windows call (host target)
//!
//! Nothing third-party goes into the program: no C runtime (no mingw-w64 CRT), no compiler-rt
//! (src/rt.zig has the three memory functions the compiler may call), no Windows bindings but our
//! own (src/win.zig) and no prebuilt import libraries: they are generated here from imports/*.def,
//! which list only the system DLL functions the helper calls. The entry point is ours too
//! (wWinMainCRTStartup in src/main.zig), so the standard library's start-up code is left out.

const std = @import("std");

/// The import definitions, one per system DLL (imports/<name>.def).
const dlls = [_][]const u8{ "KERNEL32", "USER32", "SHELL32", "ole32", "dwmapi", "MFPlat", "MFReadWrite" };

pub fn build(b: *std.Build) void {
    const optimize = b.option(std.builtin.Optimize, "optimize", "Optimization mode (default: fast)") orelse .fast;
    const target = b.resolveTargetQuery(.{ .cpu_arch = .x86_64, .os_tag = .windows, .abi = .gnu });

    const root = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = false,
        .single_threaded = false,
        .strip = true,
        .stack_check = false,
        .stack_protector = false,
        .no_builtin = true,
        .error_tracing = false,
        .unwind_tables = .none,
    });
    root.addWin32ResourceFile(.{ .file = b.path("zeyvola-win.rc") });
    for (dlls) |name| {
        const dlltool = b.addSystemCommand(&.{ b.graph.zig_exe, "dlltool", "-m", "i386:x86-64", "-d" });
        dlltool.addFileArg(b.path(b.fmt("imports/{s}.def", .{name})));
        dlltool.addArg("-l");
        root.addObjectFile(dlltool.addOutputFileArg(b.fmt("{s}.lib", .{name})));
    }

    const exe = b.addExecutable(.{ .name = "zeyvola-win", .root_module = root });
    exe.bundle_compiler_rt = false;
    exe.bundle_ubsan_rt = false;
    exe.rc_includes = .none; // the .rc needs no SDK header
    exe.subsystem = .console;
    exe.entry = .{ .symbol_name = "wWinMainCRTStartup" };
    // Only the .exe is shipped: no import library or debug file next to it.
    b.getInstallStep().dependOn(&b.addInstallArtifact(exe, .{ .pdb_dir = .disabled, .implib_dir = .disabled }).step);

    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = b.graph.host,
    }) });
    b.step("test", "Run the unit tests").dependOn(&b.addRunArtifact(tests).step);
}
