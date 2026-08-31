const std = @import("std");

const version = @import("build.zig.zon").version;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mpv_prefix = b.option([]const u8, "mpv-prefix", "libmpv install prefix (default /usr/local)") orelse "/usr/local";

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    linkMpv(b, mod, mpv_prefix);

    const options = b.addOptions();
    options.addOption([]const u8, "version", version);
    mod.addOptions("build_options", options);

    const exe = b.addExecutable(.{
        .name = "hum",
        .root_module = mod,
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run hum");
    run_step.dependOn(&run_cmd.step);

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    linkMpv(b, test_mod, mpv_prefix);
    test_mod.addOptions("build_options", options);

    const unit_tests = b.addTest(.{ .root_module = test_mod });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    addCheckStep(b, mpv_prefix, options);
}

/// `zig build check` type-checks every release target without linking, so a
/// platform-specific break (FreeBSD translate-c, most often) surfaces in seconds
/// on any machine instead of at tag time in a VM.
fn addCheckStep(b: *std.Build, mpv_prefix: []const u8, options: *std.Build.Step.Options) void {
    const check = b.step("check", "Type-check all release targets (no link)");

    // Zig ships libc headers for every target below, so the ONLY header this
    // needs from the host is mpv/client.h. Copy that one file into a generated
    // directory rather than putting a system include path on the command line:
    // -I /usr/include would feed the host's glibc headers to a macOS or FreeBSD
    // cross-compile, which fails on glibc internals.
    const header = findMpvHeader(b, mpv_prefix) orelse {
        std.log.warn("check: mpv/client.h not found; skipping (pass -Dmpv-prefix)", .{});
        return;
    };
    const shim = b.addWriteFiles();
    _ = shim.addCopyFile(.{ .cwd_relative = header }, "mpv/client.h");
    const include_dir = shim.getDirectory();

    const targets = [_][]const u8{
        "x86_64-freebsd",
        "x86_64-linux-gnu",
        "aarch64-linux-gnu",
        "x86_64-macos",
        "aarch64-macos",
    };
    // ReleaseSafe as well as Debug: FreeBSD's __ssp fortify wrappers only appear
    // in optimized builds.
    const modes = [_]std.builtin.OptimizeMode{ .Debug, .ReleaseSafe };

    for (targets) |triple| {
        for (modes) |mode| {
            const query = std.Build.parseTargetQuery(.{ .arch_os_abi = triple }) catch continue;
            const mod = b.createModule(.{
                .root_source_file = b.path("src/main.zig"),
                .target = b.resolveTargetQuery(query),
                .optimize = mode,
                .link_libc = true,
            });
            mod.addIncludePath(include_dir);
            mod.addOptions("build_options", options);
            const obj = b.addObject(.{
                .name = b.fmt("check-{s}-{s}", .{ triple, @tagName(mode) }),
                .root_module = mod,
            });
            check.dependOn(&obj.step);
        }
    }
}

/// Locate mpv/client.h: the configured prefix, then the usual system locations.
fn findMpvHeader(b: *std.Build, prefix: []const u8) ?[]const u8 {
    const dirs = [_][]const u8{
        if (prefix.len > 0) b.fmt("{s}/include", .{prefix}) else "",
        "/usr/include",
        "/usr/local/include",
        "/opt/homebrew/include",
    };
    for (dirs) |dir| {
        if (dir.len == 0) continue;
        const path = b.fmt("{s}/mpv/client.h", .{dir});
        std.Io.Dir.cwd().access(b.graph.io, path, .{}) catch continue;
        return path;
    }
    return null;
}

fn linkMpv(b: *std.Build, mod: *std.Build.Module, prefix: []const u8) void {
    if (prefix.len > 0) {
        // Explicit prefix wins: skip pkg-config, which resolves to the HOST
        // arch's mpv and breaks cross-compiles (e.g. the x86_64 slice of the
        // universal macOS build linking the arm libmpv). Empty prefix (Linux)
        // still uses pkg-config to find the system libmpv.
        mod.addIncludePath(.{ .cwd_relative = b.fmt("{s}/include", .{prefix}) });
        mod.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/lib", .{prefix}) });
        mod.linkSystemLibrary("mpv", .{ .use_pkg_config = .no });
    } else {
        mod.linkSystemLibrary("mpv", .{});
    }
}
