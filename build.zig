const std = @import("std");

const version = @import("build.zig.zon").version;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mpv_prefix = b.option([]const u8, "mpv-prefix", "libmpv prefix searched first at runtime") orelse "";

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const options = b.addOptions();
    options.addOption([]const u8, "version", version);
    options.addOption([]const u8, "mpv_prefix", mpv_prefix);
    mod.addOptions("build_options", options);

    const exe = b.addExecutable(.{
        .name = "hum",
        .root_module = mod,
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    const run_step = b.step("run", "Run hum");
    run_step.dependOn(&run_cmd.step);

    const clean_cmd = b.addSystemCommand(&.{ "rm", "-rf", "zig-out", ".zig-cache" });
    const clean_step = b.step("clean", "Remove zig-out and the local build cache");
    clean_step.dependOn(&clean_cmd.step);

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    test_mod.addOptions("build_options", options);

    const unit_tests = b.addTest(.{ .root_module = test_mod });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    addCheckStep(b, options);
}

fn addCheckStep(b: *std.Build, options: *std.Build.Step.Options) void {
    const check = b.step("check", "Type-check all release targets (no link)");

    const targets = [_][]const u8{
        "x86_64-freebsd",
        "x86_64-linux-gnu",
        "aarch64-linux-gnu",
        "x86_64-macos",
        "aarch64-macos",
    };
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
            mod.addOptions("build_options", options);
            const obj = b.addObject(.{
                .name = b.fmt("check-{s}-{s}", .{ triple, @tagName(mode) }),
                .root_module = mod,
            });
            check.dependOn(&obj.step);
        }
    }
}
