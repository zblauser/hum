const std = @import("std");
const fsutil = @import("fsutil.zig");
const tags_mod = @import("tags.zig");
const track_mod = @import("track.zig");
const txt = @import("text.zig");
const log = @import("log.zig");

/// One indexed file. Strings live in the index arena and outlive the rows built from them.
pub const Entry = struct {
    path: []const u8,
    title: []const u8 = "",
    artist: []const u8 = "",
    album: []const u8 = "",
    track_no: u16 = 0,
    duration_s: u32 = 0,
    /// mtime + size are the cache key: if neither changed, the tags did not.
    mtime: i64 = 0,
    size: u64 = 0,
};

/// Which files to open at all; the tag parser still dispatches on magic bytes.
const EXTS = [_][]const u8{
    ".mp3",  ".flac", ".m4a", ".aac",  ".alac", ".ogg",
    ".opus", ".wav",  ".aif", ".aiff", ".wma",  ".mp4",
    ".m4b",  ".oga",  ".ape", ".wv",
};

/// A symlinked directory can point at its own parent, so the walk needs these ends.
const MAX_FILES: usize = 50_000;
const MAX_DEPTH: usize = 12;

pub fn isAudio(name: []const u8) bool {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return false;
    const ext = name[dot..];
    if (ext.len > 8) return false;
    var buf: [8]u8 = undefined;
    const lower = std.ascii.lowerString(buf[0..ext.len], ext);
    for (EXTS) |e| {
        if (std.mem.eql(u8, lower, e)) return true;
    }
    return false;
}

/// A rebuildable index belongs in the cache, not beside the playlists.
pub fn cachePath(arena: std.mem.Allocator, env: *std.process.Environ.Map) ![:0]const u8 {
    return fsutil.xdgPath(arena, env, "XDG_CACHE_HOME", ".cache", "library");
}

/// Several roots, $PATH-style. A leading `~/` is expanded so the config stays portable.
pub fn roots(arena: std.mem.Allocator, env: *std.process.Environ.Map, configured: []const u8) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, configured, ':');
    while (it.next()) |raw| {
        const dir = std.mem.trim(u8, raw, " \t\r\n");
        if (dir.len == 0) continue;
        if (std.mem.startsWith(u8, dir, "~/")) {
            const home = env.get("HOME") orelse continue;
            try out.append(arena, try std.fmt.allocPrint(arena, "{s}/{s}", .{ home, dir[2..] }));
        } else {
            try out.append(arena, try arena.dupe(u8, dir));
        }
    }
    return out.toOwnedSlice(arena);
}

/// Returning false aborts: a scan of a network mount must be escapable.
pub const Progress = struct {
    ctx: *anyopaque,
    on: *const fn (ctx: *anyopaque, scanned: usize) bool,
};

/// `complete` tells the caller not to cache a partial index as if it were whole.
pub const Result = struct {
    entries: []Entry,
    complete: bool = true,
};

/// Reuses cached rows whose mtime and size are unchanged; tag-reads only what is new.
pub fn scan(
    arena: std.mem.Allocator,
    io: std.Io,
    dirs: []const []const u8,
    cached: []const Entry,
    progress: ?Progress,
) !Result {
    var known: std.StringHashMapUnmanaged(Entry) = .empty;
    for (cached) |e| try known.put(arena, e.path, e);

    var out: std.ArrayList(Entry) = .empty;
    var seen: usize = 0;

    for (dirs) |root| {
        var dir = std.Io.Dir.openDirAbsolute(io, root, .{ .iterate = true }) catch |err| {
            log.write("library: cannot open {s}: {s}", .{ root, @errorName(err) });
            continue;
        };
        defer dir.close(io);

        var walker = dir.walk(arena) catch continue;
        defer walker.deinit();

        while (walker.next(io) catch null) |entry| {
            if (out.items.len >= MAX_FILES) {
                log.write("library: stopping at the {d}-file ceiling", .{MAX_FILES});
                break;
            }
            if (entry.kind != .file) continue;
            if (entry.depth() > MAX_DEPTH) continue;
            if (!isAudio(entry.basename)) continue;
            // skip dotted paths: .Trash, .git, resource forks
            if (std.mem.indexOf(u8, entry.path, "/.") != null or entry.path[0] == '.') continue;

            const full = try std.fmt.allocPrint(arena, "{s}/{s}", .{ root, entry.path });
            const st = entry.dir.statFile(io, entry.basename, .{}) catch continue;
            const mtime: i64 = @intCast(@divFloor(st.mtime.nanoseconds, std.time.ns_per_s));

            seen += 1;
            if (progress) |p| {
                if (seen % 32 == 0 and !p.on(p.ctx, seen)) {
                    return .{ .entries = try out.toOwnedSlice(arena), .complete = false };
                }
            }

            if (known.get(full)) |hit| {
                if (hit.mtime == mtime and hit.size == st.size) {
                    try out.append(arena, hit);
                    continue;
                }
            }

            // path below the root, never the absolute path: a flat library would take its artist from wherever the root is nested
            var meta = tags_mod.read(arena, full) orelse tags_mod.Tags{};
            if (meta.title.len == 0 or meta.artist.len == 0 or meta.album.len == 0) {
                const from_path = tags_mod.fromPath(arena, entry.path);
                if (meta.title.len == 0) meta.title = from_path.title;
                if (meta.artist.len == 0) meta.artist = from_path.artist;
                if (meta.album.len == 0) meta.album = from_path.album;
                if (meta.track_no == 0) meta.track_no = from_path.track_no;
            }
            // grouping drops empty names, so an untagged file needs a bucket to be reachable
            if (meta.artist.len == 0) meta.artist = "unknown";
            if (meta.album.len == 0) meta.album = "unknown";

            try out.append(arena, .{
                .path = full,
                .title = meta.title,
                .artist = meta.artist,
                .album = meta.album,
                .track_no = meta.track_no,
                .duration_s = meta.duration_s,
                .mtime = mtime,
                .size = st.size,
            });
        }
    }
    return .{ .entries = try out.toOwnedSlice(arena), .complete = true };
}

// ------------------------------------------------------------------- cache

/// Rows plus the music_dir they were built from: without it, changing music_dir keeps serving the old library.
pub const Cached = struct {
    roots: []const u8 = "",
    entries: []Entry = &.{},

    /// Usable only if it was built from the roots we are asking about now.
    pub fn matches(self: Cached, music_dir: []const u8) bool {
        return self.entries.len > 0 and std.mem.eql(u8, self.roots, music_dir);
    }
};

/// #roots header, then one sanitized tab-separated row per track.
pub fn saveCache(
    arena: std.mem.Allocator,
    file_path: []const u8,
    music_dir: []const u8,
    entries: []const Entry,
) !void {
    var buf: std.ArrayList(u8) = .empty;
    try buf.print(arena, "#roots\t{s}\n", .{try txt.sanitize(arena, music_dir)});
    for (entries) |e| {
        try buf.print(arena, "{s}\t{d}\t{d}\t{s}\t{s}\t{s}\t{d}\t{d}\n", .{
            try txt.sanitize(arena, e.path),
            e.mtime,
            e.size,
            try txt.sanitize(arena, e.title),
            try txt.sanitize(arena, e.artist),
            try txt.sanitize(arena, e.album),
            e.track_no,
            e.duration_s,
        });
    }
    return fsutil.writeFile(arena, file_path, buf.items);
}

pub fn loadCache(arena: std.mem.Allocator, file_path: []const u8) Cached {
    const bytes = fsutil.readFileAlloc(arena, file_path) orelse return .{};
    var out: std.ArrayList(Entry) = .empty;
    var from_roots: []const u8 = "";

    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, "\r");
        if (line.len == 0) continue;
        if (std.mem.startsWith(u8, line, "#roots\t")) {
            from_roots = line["#roots\t".len..];
            continue;
        }
        // a headerless cache predates the roots header and never matches
        if (line[0] == '#') continue;
        var f = std.mem.splitScalar(u8, line, '\t');
        const path = f.next() orelse continue;
        const mtime = f.next() orelse continue;
        const size = f.next() orelse continue;
        const title = f.next() orelse continue;
        const artist = f.next() orelse "";
        const album = f.next() orelse "";
        const track_no = f.next() orelse "0";
        const duration = f.next() orelse "0";
        if (path.len == 0) continue;

        out.append(arena, .{
            .path = path,
            .title = title,
            .artist = artist,
            .album = album,
            .track_no = std.fmt.parseInt(u16, track_no, 10) catch 0,
            .duration_s = std.fmt.parseInt(u32, duration, 10) catch 0,
            .mtime = std.fmt.parseInt(i64, mtime, 10) catch 0,
            .size = std.fmt.parseInt(u64, size, 10) catch 0,
        }) catch return .{ .roots = from_roots, .entries = out.items };
    }
    return .{ .roots = from_roots, .entries = out.items };
}

// ---------------------------------------------------------------- grouping

fn lessCaseless(_: void, a: []const u8, b: []const u8) bool {
    const n = @min(a.len, b.len);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const x = std.ascii.toLower(a[i]);
        const y = std.ascii.toLower(b[i]);
        if (x != y) return x < y;
    }
    return a.len < b.len;
}

fn appendUnique(arena: std.mem.Allocator, list: *std.ArrayList([]const u8), v: []const u8) !void {
    if (v.len == 0) return;
    for (list.items) |have| {
        if (std.ascii.eqlIgnoreCase(have, v)) return;
    }
    try list.append(arena, v);
}

pub fn artistsOf(arena: std.mem.Allocator, entries: []const Entry) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (entries) |e| try appendUnique(arena, &out, e.artist);
    std.mem.sort([]const u8, out.items, {}, lessCaseless);
    return out.items;
}

pub fn albumsOf(arena: std.mem.Allocator, entries: []const Entry, artist: []const u8) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (entries) |e| {
        if (!std.ascii.eqlIgnoreCase(e.artist, artist)) continue;
        try appendUnique(arena, &out, e.album);
    }
    std.mem.sort([]const u8, out.items, {}, lessCaseless);
    return out.items;
}

fn beforeInAlbum(_: void, a: Entry, b: Entry) bool {
    if (a.track_no != b.track_no) {
        // untracked files sort after numbered ones rather than jumping to the top
        if (a.track_no == 0) return false;
        if (b.track_no == 0) return true;
        return a.track_no < b.track_no;
    }
    return lessCaseless({}, a.title, b.title);
}

pub fn tracksOf(
    arena: std.mem.Allocator,
    entries: []const Entry,
    artist: []const u8,
    album: []const u8,
) ![]Entry {
    var out: std.ArrayList(Entry) = .empty;
    for (entries) |e| {
        if (artist.len > 0 and !std.ascii.eqlIgnoreCase(e.artist, artist)) continue;
        if (album.len > 0 and !std.ascii.eqlIgnoreCase(e.album, album)) continue;
        try out.append(arena, e);
    }
    std.mem.sort(Entry, out.items, {}, beforeInAlbum);
    return out.items;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return false;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

/// Substring match: title hits first, then artist and album.
pub fn search(arena: std.mem.Allocator, entries: []const Entry, query: []const u8, max: usize) ![]Entry {
    var out: std.ArrayList(Entry) = .empty;
    if (query.len == 0) return out.items;

    for (entries) |e| {
        if (out.items.len >= max) return out.items;
        if (containsIgnoreCase(e.title, query)) try out.append(arena, e);
    }
    for (entries) |e| {
        if (out.items.len >= max) return out.items;
        if (containsIgnoreCase(e.title, query)) continue;
        if (containsIgnoreCase(e.artist, query) or containsIgnoreCase(e.album, query)) {
            try out.append(arena, e);
        }
    }
    return out.items;
}

/// Completions from the index, artists first. Prefix match: the ghost can only extend what is typed.
pub fn namesMatching(
    arena: std.mem.Allocator,
    entries: []const Entry,
    query: []const u8,
    max: usize,
) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    if (query.len == 0) return out.items;

    inline for (.{ "artist", "album", "title" }) |field| {
        for (entries) |e| {
            if (out.items.len >= max) return out.items;
            const v = @field(e, field);
            if (v.len > query.len and std.ascii.startsWithIgnoreCase(v, query)) {
                try appendUnique(arena, &out, v);
            }
        }
    }
    return out.items;
}

/// Album plus its artist, so a row can drill in without guessing.
pub const AlbumRef = struct { album: []const u8, artist: []const u8 };

/// Albums whose name, or whose artist, matches. An empty query means "all".
pub fn albumsMatching(
    arena: std.mem.Allocator,
    entries: []const Entry,
    query: []const u8,
    max: usize,
) ![]AlbumRef {
    var out: std.ArrayList(AlbumRef) = .empty;
    for (entries) |e| {
        if (out.items.len >= max) break;
        if (e.album.len == 0) continue;
        if (query.len > 0 and !containsIgnoreCase(e.album, query) and !containsIgnoreCase(e.artist, query)) continue;
        var dupe = false;
        for (out.items) |have| {
            if (std.ascii.eqlIgnoreCase(have.album, e.album) and std.ascii.eqlIgnoreCase(have.artist, e.artist)) {
                dupe = true;
                break;
            }
        }
        if (!dupe) try out.append(arena, .{ .album = e.album, .artist = e.artist });
    }
    return out.items;
}

/// Artists whose name matches. An empty query means "all".
pub fn artistsMatching(
    arena: std.mem.Allocator,
    entries: []const Entry,
    query: []const u8,
    max: usize,
) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (entries) |e| {
        if (out.items.len >= max) break;
        if (query.len > 0 and !containsIgnoreCase(e.artist, query)) continue;
        try appendUnique(arena, &out, e.artist);
    }
    std.mem.sort([]const u8, out.items, {}, lessCaseless);
    return out.items;
}

/// Index entry to queue row.
pub fn toTrack(e: Entry) track_mod.Track {
    return .{
        .source = .local,
        .uri = e.path,
        .title = if (e.title.len > 0) e.title else e.path,
        .artist = if (e.artist.len > 0) e.artist else "unknown",
        .album = e.album,
        .duration_s = e.duration_s,
        .kind = "Song",
    };
}

const testing = std.testing;

fn tmpPath(a: std.mem.Allocator) ![:0]const u8 {
    const p = try a.dupeZ(u8, "/tmp/hum_lib_XXXXXX");
    const fd = fsutil.c.mkstemp(p.ptr);
    if (fd < 0) return error.TempFailed;
    _ = fsutil.c.close(fd);
    return p;
}

test "isAudio matches by extension, case-insensitively, and rejects the rest" {
    try testing.expect(isAudio("a.mp3"));
    try testing.expect(isAudio("A.FLAC"));
    try testing.expect(isAudio("x.M4a"));
    try testing.expect(!isAudio("cover.jpg"));
    try testing.expect(!isAudio("notes.txt"));
    try testing.expect(!isAudio("noextension"));
    try testing.expect(!isAudio(".hidden"));
    try testing.expect(!isAudio("a.verylongextension"));
}

test "roots splits on colons and expands a leading tilde" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var env: std.process.Environ.Map = .init(a);
    try env.put("HOME", "/home/u");

    const got = try roots(a, &env, "~/Music: /mnt/media ::/x");
    try testing.expectEqual(@as(usize, 3), got.len);
    try testing.expectEqualStrings("/home/u/Music", got[0]);
    try testing.expectEqualStrings("/mnt/media", got[1]);
    try testing.expectEqualStrings("/x", got[2]);
}

test "cache round-trips and tolerates a mangled line" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const p = try tmpPath(a);
    defer _ = fsutil.c.unlink(p.ptr);

    const entries = [_]Entry{
        .{ .path = "/m/a.flac", .title = "A", .artist = "Ar", .album = "Al", .track_no = 2, .duration_s = 222, .mtime = 99, .size = 4096 },
        .{ .path = "/m/b.mp3", .title = "B", .artist = "Ar", .album = "Al", .track_no = 1, .duration_s = 100, .mtime = 5, .size = 10 },
    };
    try saveCache(a, p, "/m", &entries);

    const back = loadCache(a, p).entries;
    try testing.expectEqual(@as(usize, 2), back.len);
    try testing.expectEqualStrings("/m/a.flac", back[0].path);
    try testing.expectEqual(@as(u16, 2), back[0].track_no);
    try testing.expectEqual(@as(i64, 99), back[0].mtime);
    try testing.expectEqual(@as(u64, 4096), back[0].size);
    try testing.expectEqual(@as(u32, 100), back[1].duration_s);
}

test "cache writing neutralizes a tab or newline in a path or title" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const p = try tmpPath(a);
    defer _ = fsutil.c.unlink(p.ptr);

    const entries = [_]Entry{.{
        .path = "/m/evil\tname.flac",
        .title = "row\nforge\t/x.mp3\t0\t0\tfake",
        .artist = "A",
    }};
    try saveCache(a, p, "/m", &entries);

    const back = loadCache(a, p).entries;
    try testing.expectEqual(@as(usize, 1), back.len); // one row, not two
    try testing.expectEqualStrings("/m/evil name.flac", back[0].path);
    try testing.expectEqualStrings("row forge /x.mp3 0 0 fake", back[0].title);
}

test "grouping lists artists and albums once, and orders tracks by number" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const entries = [_]Entry{
        .{ .path = "/m/3.flac", .title = "Third", .artist = "bohren", .album = "Black Earth", .track_no = 3 },
        .{ .path = "/m/1.flac", .title = "First", .artist = "Bohren", .album = "Black Earth", .track_no = 1 },
        .{ .path = "/m/x.flac", .title = "Untracked", .artist = "Bohren", .album = "Black Earth" },
        .{ .path = "/m/2.flac", .title = "Second", .artist = "Bohren", .album = "Sunset Mission", .track_no = 2 },
        .{ .path = "/m/a.flac", .title = "Other", .artist = "Aphex Twin", .album = "SAW" },
    };

    const artists = try artistsOf(a, &entries);
    try testing.expectEqual(@as(usize, 2), artists.len); // "bohren" and "Bohren" are one
    try testing.expectEqualStrings("Aphex Twin", artists[0]);

    const albums = try albumsOf(a, &entries, "BOHREN");
    try testing.expectEqual(@as(usize, 2), albums.len);
    try testing.expectEqualStrings("Black Earth", albums[0]);

    const tracks = try tracksOf(a, &entries, "Bohren", "Black Earth");
    try testing.expectEqual(@as(usize, 3), tracks.len);
    try testing.expectEqualStrings("First", tracks[0].title);
    try testing.expectEqualStrings("Third", tracks[1].title);
    try testing.expectEqualStrings("Untracked", tracks[2].title); // no number sorts last
}

test "toTrack produces a playable local row with sane fallbacks" {
    const t = toTrack(.{ .path = "/m/a.flac", .title = "T", .artist = "A", .album = "Al", .duration_s = 12 });
    try testing.expectEqual(track_mod.Source.local, t.source);
    try testing.expect(t.isPlayable());
    try testing.expectEqualStrings("/m/a.flac", t.uri);

    const bare = toTrack(.{ .path = "/m/b.flac" });
    try testing.expectEqualStrings("/m/b.flac", bare.title);
    try testing.expectEqualStrings("unknown", bare.artist);
}

test "search matches title first, then artist and album, and caps results" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const entries = [_]Entry{
        .{ .path = "/1", .title = "Prowler", .artist = "Bohren", .album = "Sunset Mission" },
        .{ .path = "/2", .title = "Midnight", .artist = "Bohren", .album = "Black Earth" },
        .{ .path = "/3", .title = "Xtal", .artist = "Aphex Twin", .album = "SAW" },
    };

    const by_title = try search(a, &entries, "prow", 10);
    try testing.expectEqual(@as(usize, 1), by_title.len);
    try testing.expectEqualStrings("Prowler", by_title[0].title);

    const by_artist = try search(a, &entries, "BOHREN", 10);
    try testing.expectEqual(@as(usize, 2), by_artist.len);

    const by_album = try search(a, &entries, "sunset", 10);
    try testing.expectEqualStrings("Prowler", by_album[0].title);

    // a title hit outranks an artist hit for the same query
    const mixed = try search(a, &entries, "midnight", 10);
    try testing.expectEqualStrings("Midnight", mixed[0].title);

    try testing.expectEqual(@as(usize, 1), (try search(a, &entries, "bohren", 1)).len);
    try testing.expectEqual(@as(usize, 0), (try search(a, &entries, "", 10)).len);
    try testing.expectEqual(@as(usize, 0), (try search(a, &entries, "zzzz", 10)).len);
}

test "namesMatching completes artists before albums before titles" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const entries = [_]Entry{
        .{ .path = "/1", .title = "Bohren Theme", .artist = "Bohren & der Club of Gore", .album = "Black Earth" },
        .{ .path = "/2", .title = "Midnight", .artist = "Bohren & der Club of Gore", .album = "Bohren Rarities" },
    };

    const got = try namesMatching(a, &entries, "bohr", 10);
    try testing.expectEqual(@as(usize, 3), got.len);
    try testing.expectEqualStrings("Bohren & der Club of Gore", got[0]); // artist first
    try testing.expectEqualStrings("Bohren Rarities", got[1]); // then album
    try testing.expectEqualStrings("Bohren Theme", got[2]); // then title

    // prefix only — the ghost can only extend what is typed
    try testing.expectEqual(@as(usize, 0), (try namesMatching(a, &entries, "earth", 10)).len);
    // an exact match adds nothing to complete
    try testing.expectEqual(@as(usize, 0), (try namesMatching(a, &entries, "Midnight", 10)).len);
    try testing.expectEqual(@as(usize, 0), (try namesMatching(a, &entries, "", 10)).len);
    try testing.expectEqual(@as(usize, 1), (try namesMatching(a, &entries, "bohr", 1)).len);
}

test "a flat library takes no artist or album from the folder above the root" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // what scan() passes for a file sitting directly in the root
    const flat = tags_mod.fromPath(a, "song.mp3");
    try testing.expectEqualStrings("song", flat.title);
    try testing.expectEqualStrings("", flat.artist);
    try testing.expectEqualStrings("", flat.album);

    // a nested one still derives both
    const nested = tags_mod.fromPath(a, "Bohren/Black Earth/01 Midnight.flac");
    try testing.expectEqualStrings("Midnight", nested.title);
    try testing.expectEqualStrings("Black Earth", nested.album);
    try testing.expectEqualStrings("Bohren", nested.artist);
}

test "untagged files land in an 'unknown' bucket instead of vanishing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // what scan() produces for a tagless file in a flat root
    const entries = [_]Entry{
        .{ .path = "/m/x.flac", .title = "x", .artist = "unknown", .album = "unknown" },
        .{ .path = "/m/y.flac", .title = "y", .artist = "Real", .album = "Album" },
    };
    const artists = try artistsOf(a, &entries);
    try testing.expectEqual(@as(usize, 2), artists.len);

    const tracks = try tracksOf(a, &entries, "unknown", "unknown");
    try testing.expectEqual(@as(usize, 1), tracks.len);
    try testing.expectEqualStrings("x", tracks[0].title);
}

test "a cache built from other roots is not reused" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const p = try tmpPath(a);
    defer _ = fsutil.c.unlink(p.ptr);

    const entries = [_]Entry{.{ .path = "/old/a.flac", .title = "A", .artist = "Ar", .album = "Al" }};
    try saveCache(a, p, "/old", &entries);

    const back = loadCache(a, p);
    try testing.expectEqualStrings("/old", back.roots);
    try testing.expect(back.matches("/old"));
    try testing.expect(!back.matches("/new")); // music_dir changed → do not serve it
    try testing.expect(!back.matches("/old:/second"));

    // several roots round-trip verbatim
    try saveCache(a, p, "/one:/two", &entries);
    try testing.expect(loadCache(a, p).matches("/one:/two"));
}

test "a headerless pre-v0.1.7 cache never matches" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const p = try tmpPath(a);
    defer _ = fsutil.c.unlink(p.ptr);
    try fsutil.writeFile(a, p, "/m/a.flac\t0\t0\tA\tAr\tAl\t0\t0\n");

    const back = loadCache(a, p);
    try testing.expectEqual(@as(usize, 1), back.entries.len);
    try testing.expect(!back.matches("/m"));
}

test "albumsMatching and artistsMatching dedupe and honour an empty query" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const entries = [_]Entry{
        .{ .path = "/1", .title = "One", .artist = "Bohren", .album = "Black Earth" },
        .{ .path = "/2", .title = "Two", .artist = "Bohren", .album = "Black Earth" },
        .{ .path = "/3", .title = "Xtal", .artist = "Aphex Twin", .album = "SAW" },
    };

    const all_albums = try albumsMatching(a, &entries, "", 10);
    try testing.expectEqual(@as(usize, 2), all_albums.len); // deduped

    const by_artist = try albumsMatching(a, &entries, "bohren", 10);
    try testing.expectEqual(@as(usize, 1), by_artist.len);
    try testing.expectEqualStrings("Black Earth", by_artist[0].album);
    try testing.expectEqualStrings("Bohren", by_artist[0].artist);

    const artists = try artistsMatching(a, &entries, "", 10);
    try testing.expectEqual(@as(usize, 2), artists.len);
    try testing.expectEqualStrings("Aphex Twin", artists[0]);
    try testing.expectEqual(@as(usize, 1), (try artistsMatching(a, &entries, "aphex", 10)).len);
    try testing.expectEqual(@as(usize, 0), (try artistsMatching(a, &entries, "zzz", 10)).len);
}
