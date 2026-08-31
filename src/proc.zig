const std = @import("std");
const log = @import("log.zig");

pub const Error = error{ProcFailed} || std.process.RunError;

/// A remote endpoint decides how much these print, so cap what we buffer.
const STDOUT_LIMIT = 32 * 1024 * 1024;
const STDERR_LIMIT = 64 * 1024;

pub fn runCapture(gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8) Error![]u8 {
    const result = try std.process.run(gpa, io, .{
        .argv = argv,
        .stdout_limit = .limited(STDOUT_LIMIT),
        .stderr_limit = .limited(STDERR_LIMIT),
    });
    defer gpa.free(result.stderr);
    errdefer gpa.free(result.stdout);
    switch (result.term) {
        .exited => |code| if (code != 0) {
            const err = std.mem.trim(u8, result.stderr, " \r\n\t");
            log.write("{s} exit {d}: {s}", .{ argv[0], code, err[0..@min(err.len, 400)] });
            return error.ProcFailed;
        },
        else => {
            log.write("{s} terminated abnormally", .{argv[0]});
            return error.ProcFailed;
        },
    }
    return result.stdout;
}
