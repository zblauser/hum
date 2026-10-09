const std = @import("std");
const fsutil = @import("fsutil.zig");

pub fn path(arena: std.mem.Allocator, env: *std.process.Environ.Map) ![]const u8 {
    return fsutil.xdgPath(arena, env, "XDG_CONFIG_HOME", ".config", "config");
}

pub const Key = enum { theme, volume, scope, splash, music_dir, visualizer, mouse };

pub fn loadKey(arena: std.mem.Allocator, file_path: []const u8, key: Key) ?[]const u8 {
    const bytes = fsutil.readFileAlloc(arena, file_path) orelse return null;

    var it = std.mem.splitScalar(u8, bytes, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        const eq = std.mem.indexOfScalar(u8, trimmed, '=') orelse continue;
        if (std.mem.eql(u8, trimmed[0..eq], @tagName(key))) {
            const val = std.mem.trim(u8, trimmed[eq + 1 ..], " \t\r");
            if (val.len == 0) return null;
            return arena.dupe(u8, val) catch null;
        }
    }
    return null;
}

pub fn saveKey(arena: std.mem.Allocator, file_path: []const u8, key: Key, value: []const u8) !void {
    var keys: std.ArrayList([]const u8) = .empty;
    var vals: std.ArrayList([]const u8) = .empty;

    if (fsutil.readFileAlloc(arena, file_path)) |bytes| {
        var it = std.mem.splitScalar(u8, bytes, '\n');
        while (it.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            const eq = std.mem.indexOfScalar(u8, trimmed, '=') orelse continue;
            const k = trimmed[0..eq];
            if (std.mem.eql(u8, k, @tagName(key))) continue;
            try keys.append(arena, k);
            try vals.append(arena, std.mem.trim(u8, trimmed[eq + 1 ..], " \t\r"));
        }
    }
    try keys.append(arena, @tagName(key));
    try vals.append(arena, value);

    var buf: std.ArrayList(u8) = .empty;
    for (keys.items, vals.items) |k, v| try buf.print(arena, "{s}={s}\n", .{ k, v });
    return fsutil.writeFile(arena, file_path, buf.items);
}
