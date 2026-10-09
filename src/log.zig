const std = @import("std");
const fsutil = @import("fsutil.zig");

const c = fsutil.c;

const time_t = std.c.time_t;
const Tm = opaque {};
extern "c" fn time(?*time_t) time_t;
extern "c" fn localtime(*const time_t) ?*Tm;
extern "c" fn strftime(noalias [*]u8, usize, noalias [*:0]const u8, noalias *const Tm) usize;

var path_z: ?[:0]const u8 = null;

pub fn path(arena: std.mem.Allocator, env: *std.process.Environ.Map) ![:0]const u8 {
    return fsutil.xdgPath(arena, env, "XDG_DATA_HOME", ".local/share", "log");
}

pub fn init(arena: std.mem.Allocator, env: *std.process.Environ.Map) void {
    const p = path(arena, env) catch return;
    if (std.fs.path.dirname(p)) |dir| {
        fsutil.makePathZ(arena, dir) catch return;
    }
    path_z = p;
}

pub fn write(comptime fmt: []const u8, args: anytype) void {
    const p = path_z orelse return;

    var buf: [1024]u8 = undefined;
    var ts: [20]u8 = undefined;
    const head = std.fmt.bufPrint(&buf, "{s} ", .{stamp(&ts)}) catch return;
    const tail = std.fmt.bufPrint(buf[head.len..], fmt ++ "\n", args) catch return;
    const line = buf[0 .. head.len + tail.len];

    const f = c.fopen(p.ptr, "ab") orelse return;
    defer _ = c.fclose(f);
    _ = c.fwrite(line.ptr, 1, line.len, f);
}

fn stamp(out: *[20]u8) []const u8 {
    const t = time(null);
    const tm = localtime(&t) orelse return "";
    const n = strftime(out, out.len, "%Y-%m-%d %H:%M:%S", tm);
    return out[0..n];
}

const testing = std.testing;

test "path honors XDG_DATA_HOME and falls back to HOME" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var xdg: std.process.Environ.Map = .init(a);
    try xdg.put("XDG_DATA_HOME", "/data");
    try testing.expectEqualStrings("/data/hum/log", try path(a, &xdg));

    var home: std.process.Environ.Map = .init(a);
    try home.put("HOME", "/home/u");
    try testing.expectEqualStrings("/home/u/.local/share/hum/log", try path(a, &home));

    var empty: std.process.Environ.Map = .init(a);
    try testing.expectError(error.NoHome, path(a, &empty));
}
