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
            mod.addIncludePath(.{ .cwd_relative = b.fmt("{s}/include", .{if (mpv_prefix.len > 0) mpv_prefix else "/usr/local"}) });
            mod.addOptions("build_options", options);
            const obj = b.addObject(.{
                .name = b.fmt("check-{s}-{s}", .{ triple, @tagName(mode) }),
                .root_module = mod,
            });
            check.dependOn(&obj.step);
        }
    }
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
