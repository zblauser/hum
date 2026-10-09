const std = @import("std");
const fsutil = @import("fsutil.zig");
const txt = @import("text.zig");
const c = fsutil.c;

pub fn path(arena: std.mem.Allocator, env: *std.process.Environ.Map) ![]const u8 {
    return fsutil.xdgPath(arena, env, "XDG_DATA_HOME", ".local/share", "history");
}

pub fn load(arena: std.mem.Allocator, file_path: []const u8) ![][]const u8 {
    const bytes = fsutil.readFileAlloc(arena, file_path) orelse return &.{};

    var all: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, bytes, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        try all.append(arena, trimmed);
    }

    var seen: std.StringHashMap(void) = .init(arena);
    var out: std.ArrayList([]const u8) = .empty;
    var i = all.items.len;
    while (i > 0) {
        i -= 1;
        const line = all.items[i];
        if (seen.contains(line)) continue;
        try seen.put(line, {});
        try out.append(arena, line);
    }
    return out.toOwnedSlice(arena);
}

pub fn append(arena: std.mem.Allocator, file_path: []const u8, query: []const u8) !void {
    const clean = std.mem.trim(u8, try txt.sanitize(arena, query), " \t\r");
    if (clean.len == 0) return;

    var buf: std.ArrayList(u8) = .empty;
    if (fsutil.readFileAlloc(arena, file_path)) |bytes| {
        var it = std.mem.splitScalar(u8, bytes, '\n');
        while (it.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0) continue;
            if (std.mem.eql(u8, trimmed, clean)) continue;
            try buf.print(arena, "{s}\n", .{trimmed});
        }
    }
    try buf.print(arena, "{s}\n", .{clean});
    return fsutil.writeFile(arena, file_path, buf.items);
}

pub fn remove(arena: std.mem.Allocator, file_path: []const u8, query: []const u8) !void {
    const bytes = fsutil.readFileAlloc(arena, file_path) orelse return error.NotFound;

    var kept: std.ArrayList([]const u8) = .empty;
    var dropped = false;
    var it = std.mem.splitScalar(u8, bytes, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        if (std.mem.eql(u8, trimmed, query)) {
            dropped = true;
            continue;
        }
        try kept.append(arena, trimmed);
    }
    if (!dropped) return error.NotFound;

    var buf: std.ArrayList(u8) = .empty;
    for (kept.items) |line| try buf.print(arena, "{s}\n", .{line});
    return fsutil.writeFile(arena, file_path, buf.items);
}

pub fn match(arena: std.mem.Allocator, items: []const []const u8, prefix: []const u8, max: usize) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (items) |s| {
        if (out.items.len >= max) break;
        if (prefix.len == 0 or std.ascii.startsWithIgnoreCase(s, prefix)) {
            try out.append(arena, s);
        }
    }
    return out.toOwnedSlice(arena);
}

const testing = std.testing;

test "match filters by case-insensitive prefix and honors max" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const items = [_][]const u8{ "Apple", "apricot", "banana", "AVOCADO" };

    const ap = try match(a, &items, "ap", 10);
    try testing.expectEqual(@as(usize, 2), ap.len);
    try testing.expectEqualStrings("Apple", ap[0]);
    try testing.expectEqualStrings("apricot", ap[1]);

    const all_items = try match(a, &items, "", 10);
    try testing.expectEqual(@as(usize, 4), all_items.len);

    const capped = try match(a, &items, "", 2);
    try testing.expectEqual(@as(usize, 2), capped.len);

    const none = try match(a, &items, "zz", 10);
    try testing.expectEqual(@as(usize, 0), none.len);
}

test "remove drops one entry and keeps the rest" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const p = try fsutil.makeTemp(a, "hum_hist_", "");
    defer _ = c.unlink(p.ptr);

    for ([_][]const u8{ "ado", "hong ting", "nina simone" }) |q| try append(a, p, q);
    try remove(a, p, "hong ting");

    const left = try load(a, p);
    try testing.expectEqual(@as(usize, 2), left.len);
    try testing.expectEqualStrings("nina simone", left[0]);
    try testing.expectEqualStrings("ado", left[1]);
    try testing.expectError(error.NotFound, remove(a, p, "hong ting"));
}

test "load returns empty for a missing file" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const got = try load(arena.allocator(), "/tmp/hum_does_not_exist_zzz");
    try testing.expectEqual(@as(usize, 0), got.len);
}

test "append keeps one line per query and moves a repeat to the end" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const p = try fsutil.makeTemp(a, "hum_hdup_", "");
    defer _ = c.unlink(p.ptr);

    for ([_][]const u8{ "tricot", "autechre", "tricot", "delta sleep", "tricot" }) |q| {
        try append(a, p, q);
    }

    const raw = fsutil.readFileAlloc(a, p) orelse return error.TestUnexpectedNull;
    try testing.expectEqualStrings("autechre\ndelta sleep\ntricot\n", raw);

    const shown = try load(a, p);
    try testing.expectEqual(@as(usize, 3), shown.len);
    try testing.expectEqualStrings("tricot", shown[0]);
}
