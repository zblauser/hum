const std = @import("std");
const api = @import("api.zig");
const fsutil = @import("fsutil.zig");
const txt = @import("text.zig");

const c = fsutil.c;

pub const Entry = struct {
    name: []const u8,
    tracks: []api.Track = &.{},
};

pub fn path(arena: std.mem.Allocator, env: *std.process.Environ.Map) ![]const u8 {
    return fsutil.xdgPath(arena, env, "XDG_DATA_HOME", ".local/share", "playlists");
}

pub fn cleanName(name: []const u8) []const u8 {
    var out = std.mem.trim(u8, name, " \t\r\n");
    if (out.len > 0 and out[0] == '[') out = out[1..];
    if (out.len > 64) {
        var end: usize = 64;
        while (end > 0 and (out[end] & 0xC0) == 0x80) end -= 1;
        out = out[0..end];
    }
    return out;
}

pub fn load(arena: std.mem.Allocator, file_path: []const u8) ![]Entry {
    const bytes = fsutil.readFileAlloc(arena, file_path) orelse return &.{};

    var out: std.ArrayList(Entry) = .empty;
    var tracks: std.ArrayList(api.Track) = .empty;
    var name: ?[]const u8 = null;

    var it = std.mem.splitScalar(u8, bytes, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, "\r");
        if (line.len == 0) continue;
        if (line[0] == '[' and line[line.len - 1] == ']') {
            if (name) |n| try out.append(arena, .{ .name = n, .tracks = try tracks.toOwnedSlice(arena) });
            name = line[1 .. line.len - 1];
            continue;
        }
        if (name == null) continue;
        var f = std.mem.splitScalar(u8, line, '\t');
        const id = f.next() orelse continue;
        const title = f.next() orelse continue;
        const artist = f.next() orelse "";
        const kind = f.next() orelse "Song";
        try tracks.append(arena, .{ .video_id = id, .title = title, .artist = artist, .kind = kind });
    }
    if (name) |n| try out.append(arena, .{ .name = n, .tracks = try tracks.toOwnedSlice(arena) });
    return out.toOwnedSlice(arena);
}

pub fn save(arena: std.mem.Allocator, file_path: []const u8, entries: []const Entry) !void {
    // sanitize on the way out: a tab or newline inside a title would forge rows in
    // this file, whatever put the entry in memory
    var buf: std.ArrayList(u8) = .empty;
    for (entries) |e| {
        try buf.print(arena, "[{s}]\n", .{try txt.sanitize(arena, e.name)});
        for (e.tracks) |t| {
            try buf.print(arena, "{s}\t{s}\t{s}\t{s}\n", .{
                try txt.sanitize(arena, t.video_id),
                try txt.sanitize(arena, t.title),
                try txt.sanitize(arena, t.artist),
                try txt.sanitize(arena, t.kind),
            });
        }
    }
    return fsutil.writeFile(arena, file_path, buf.items);
}

pub fn addTrack(arena: std.mem.Allocator, file_path: []const u8, name: []const u8, t: api.Track) !void {
    const clean = cleanName(name);
    if (clean.len == 0 or t.video_id.len == 0) return error.InvalidEntry;

    var entries: std.ArrayList(Entry) = .empty;
    try entries.appendSlice(arena, try load(arena, file_path));

    for (entries.items) |*e| {
        if (!std.mem.eql(u8, e.name, clean)) continue;
        for (e.tracks) |have| {
            if (std.mem.eql(u8, have.video_id, t.video_id)) return error.AlreadyPresent;
        }
        var list: std.ArrayList(api.Track) = .empty;
        try list.appendSlice(arena, e.tracks);
        try list.append(arena, t);
        e.tracks = try list.toOwnedSlice(arena);
        return save(arena, file_path, entries.items);
    }

    const one = try arena.dupe(api.Track, &[_]api.Track{t});
    try entries.append(arena, .{ .name = clean, .tracks = one });
    return save(arena, file_path, entries.items);
}

pub fn removeTrack(arena: std.mem.Allocator, file_path: []const u8, name: []const u8, idx: usize) !void {
    var entries: std.ArrayList(Entry) = .empty;
    try entries.appendSlice(arena, try load(arena, file_path));

    for (entries.items) |*e| {
        if (!std.mem.eql(u8, e.name, name)) continue;
        if (idx >= e.tracks.len) return error.NotFound;
        var list: std.ArrayList(api.Track) = .empty;
        for (e.tracks, 0..) |t, i| {
            if (i != idx) try list.append(arena, t);
        }
        e.tracks = try list.toOwnedSlice(arena);
        return save(arena, file_path, entries.items);
    }
    return error.NotFound;
}

pub fn removeList(arena: std.mem.Allocator, file_path: []const u8, name: []const u8) !void {
    const entries = try load(arena, file_path);
    var keep: std.ArrayList(Entry) = .empty;
    for (entries) |e| {
        if (!std.mem.eql(u8, e.name, name)) try keep.append(arena, e);
    }
    if (keep.items.len == entries.len) return error.NotFound;
    return save(arena, file_path, keep.items);
}

const testing = std.testing;

fn tmpPath(a: std.mem.Allocator) ![:0]const u8 {
    const p = try a.dupeZ(u8, "/tmp/ytcli_pl_XXXXXX");
    const fd = c.mkstemp(p.ptr);
    if (fd < 0) return error.TempFailed;
    _ = c.close(fd);
    return p;
}

test "playlists round-trip through the file" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = try tmpPath(a);
    defer _ = c.unlink(p.ptr);

    try addTrack(a, p, "night drive", .{ .video_id = "aaa", .title = "うっせぇわ", .artist = "Ado", .kind = "Song" });
    try addTrack(a, p, "night drive", .{ .video_id = "bbb", .title = "Second", .artist = "Someone", .kind = "Video" });
    try addTrack(a, p, "focus", .{ .video_id = "ccc", .title = "Third", .artist = "Other", .kind = "Song" });

    const got = try load(a, p);
    try testing.expectEqual(@as(usize, 2), got.len);
    try testing.expectEqualStrings("night drive", got[0].name);
    try testing.expectEqual(@as(usize, 2), got[0].tracks.len);
    try testing.expectEqualStrings("うっせぇわ", got[0].tracks[0].title);
    try testing.expectEqualStrings("Video", got[0].tracks[1].kind);
    try testing.expectEqualStrings("focus", got[1].name);
}

test "addTrack rejects duplicates, removeTrack and removeList prune" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = try tmpPath(a);
    defer _ = c.unlink(p.ptr);

    const t: api.Track = .{ .video_id = "aaa", .title = "One", .artist = "A", .kind = "Song" };
    try addTrack(a, p, "mix", t);
    try testing.expectError(error.AlreadyPresent, addTrack(a, p, "mix", t));
    try addTrack(a, p, "mix", .{ .video_id = "bbb", .title = "Two", .artist = "B", .kind = "Song" });

    try removeTrack(a, p, "mix", 0);
    const after = try load(a, p);
    try testing.expectEqual(@as(usize, 1), after[0].tracks.len);
    try testing.expectEqualStrings("bbb", after[0].tracks[0].video_id);

    try testing.expectError(error.NotFound, removeList(a, p, "nope"));
    try removeList(a, p, "mix");
    try testing.expectEqual(@as(usize, 0), (try load(a, p)).len);
}

test "cleanName trims and strips a leading bracket" {
    try testing.expectEqualStrings("chill", cleanName("  chill \n"));
    try testing.expectEqualStrings("chill]", cleanName("[chill]"));
    try testing.expectEqualStrings("", cleanName("   "));

    const long = "あ" ** 40; // 120 bytes, 3 per codepoint
    const cut = cleanName(long);
    try testing.expectEqual(@as(usize, 63), cut.len);
    try testing.expect(std.unicode.utf8ValidateSlice(cut));
}

test "load ignores malformed lines and a missing file" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqual(@as(usize, 0), (try load(a, "/tmp/ytcli_pl_missing_zzz")).len);
}

test "save neutralizes tabs and newlines that would forge rows" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const p = try tmpPath(a);
    defer _ = c.unlink(p.ptr);

    var nasty = [_]api.Track{.{
        .video_id = "abc",
        .title = "evil\ttitle\n[injected]\nxyz\tfake\tartist\tSong",
        .artist = "who",
        .kind = "Song",
    }};
    try save(a, p, &[_]Entry{.{ .name = "list", .tracks = nasty[0..] }});

    const back = try load(a, p);
    try testing.expectEqual(@as(usize, 1), back.len);
    try testing.expectEqual(@as(usize, 1), back[0].tracks.len);
    try testing.expectEqualStrings("evil title [injected] xyz fake artist Song", back[0].tracks[0].title);
}
