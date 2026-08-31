const std = @import("std");
const api = @import("api.zig");
const stream = @import("stream.zig");
const player = @import("player.zig");
const ui = @import("ui.zig");
const history = @import("history.zig");
const playlist = @import("playlist.zig");
const theme_mod = @import("theme.zig");
const config = @import("config.zig");
const track_mod = @import("track.zig");
const tags_mod = @import("tags.zig");
const library = @import("library.zig");
const feed = @import("feed.zig");
const log = @import("log.zig");

// the one libc @cImport for the program lives in fsutil; don't add another
const c = @import("fsutil.zig").c;

fn putStdout(bytes: []const u8) !void {
    var i: usize = 0;
    while (i < bytes.len) {
        const n = c.write(1, bytes[i..].ptr, bytes.len - i);
        if (n < 0) {
            // a closed pipe is the reader saying enough, not an error
            if (std.c._errno().* == c.EPIPE) std.process.exit(0);
            return error.WriteFailed;
        }
        if (n == 0) return error.WriteFailed;
        i += @intCast(n);
    }
}

pub const VERSION = @import("build_options").version;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();

    log.init(arena, init.environ_map);

    const raw_args = try init.minimal.args.toSlice(arena);

    var theme_name: []const u8 = resolveThemeName(arena, init.environ_map);
    var args: std.ArrayList([:0]const u8) = .empty;
    try args.append(arena, raw_args[0]);
    var i: usize = 1;
    while (i < raw_args.len) : (i += 1) {
        const a = raw_args[i];
        if (std.mem.eql(u8, a, "--theme")) {
            if (i + 1 < raw_args.len) {
                if (theme_mod.byName(raw_args[i + 1]) != null) theme_name = raw_args[i + 1];
                i += 1;
            }
            continue;
        }
        if (std.mem.startsWith(u8, a, "--theme=")) {
            const v = a["--theme=".len..];
            if (theme_mod.byName(v) != null) theme_name = v;
            continue;
        }
        if (std.mem.eql(u8, a, "--themes")) {
            try putStdout("themes: " ++ theme_mod.names ++ "\n");
            return;
        }
        try args.append(arena, a);
    }

    const theme = theme_mod.byName(theme_name) orelse theme_mod.default;
    const theme_idx = theme_mod.indexOf(theme_name) orelse 0;

    if (args.items.len < 2) {
        try ui.run(gpa, arena, io, init.environ_map, theme, theme_idx);
        return;
    }

    const first = args.items[1];

    if (eq(first, "-h") or eq(first, "--help")) {
        try printHelp();
        return;
    }
    if (eq(first, "-v") or eq(first, "--version")) {
        try putStdout("hum " ++ VERSION ++ "\n");
        return;
    }
    if (eq(first, "history")) {
        try cmdHistory(arena, init.environ_map);
        return;
    }
    if (eq(first, "feeds")) {
        try cmdFeeds(gpa, arena, io, init.environ_map, args.items[2..]);
        return;
    }
    if (eq(first, "doctor")) {
        try cmdDoctor(arena, io, init.environ_map);
        return;
    }
    if (eq(first, "library")) {
        try cmdLibrary(gpa, arena, io, init.environ_map, args.items[2..]);
        return;
    }
    if (eq(first, "playlists")) {
        try cmdPlaylists(arena, init.environ_map, if (args.items.len > 2) args.items[2] else null);
        return;
    }
    if (eq(first, "-s") or eq(first, "--search")) {
        if (args.items.len < 3) {
            try printHelp();
            return;
        }
        try cmdSearch(gpa, arena, io, args.items[2..]);
        return;
    }

    try cmdPlay(gpa, arena, io, args.items[1..]);
}

fn resolveThemeName(arena: std.mem.Allocator, env: *std.process.Environ.Map) []const u8 {
    var name: []const u8 = "red";
    if (config.path(arena, env)) |p| {
        if (config.loadTheme(arena, p)) |saved| {
            if (theme_mod.byName(saved) != null) name = saved;
        }
    } else |_| {}
    // YTCLI_THEME still works so existing shell profiles keep going
    inline for (.{ "YTCLI_THEME", "HUM_THEME" }) |key| {
        if (env.get(key)) |e| {
            if (theme_mod.byName(e) != null) name = e;
        }
    }
    return name;
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn joinArgs(arena: std.mem.Allocator, words: []const [:0]const u8) ![]u8 {
    var qb: std.ArrayList(u8) = .empty;
    for (words, 0..) |w, i| {
        if (i > 0) try qb.append(arena, ' ');
        try qb.appendSlice(arena, w);
    }
    return qb.toOwnedSlice(arena);
}

fn printHelp() !void {
    var buf: [1024]u8 = undefined;
    const text = std.fmt.bufPrint(&buf,
        \\hum — terminal media player (local files + YouTube Music)
        \\
        \\usage:
        \\  hum                    launch TUI
        \\  hum <query>            play first hit for <query>
        \\  hum <file|url>         play a local file or a stream URL
        \\  hum -s <query>         print top results, no playback
        \\  hum history            print recent queries (newest first)
        \\  hum playlists [name]   list saved playlists, or one playlist's tracks
        \\  hum library [scan]     list the local library (scan re-reads tags)
        \\  hum library dir <path> set the music folder (colon-separated for several)
        \\  hum feeds [name]         podcast subscriptions (add <url> / remove <url>)
        \\  hum doctor               paths, settings and dependencies at a glance
        \\  hum -h, --help         this message
        \\  hum -v, --version      print version
        \\
        \\options:
        \\  --theme <name>           color theme ({s})
        \\  --themes                 list available themes
        \\  HUM_THEME env            same as --theme
        \\  Ctrl+Y inside the TUI    cycle through themes live
        \\
    , .{theme_mod.names}) catch return error.WriteFailed;
    try putStdout(text);
}

fn cmdPlay(gpa: std.mem.Allocator, arena: std.mem.Allocator, io: std.Io, words: []const [:0]const u8) !void {
    const t = if (directTarget(arena, io, words)) |direct| direct else blk: {
        const query = try joinArgs(arena, words);
        const tracks = try api.search(arena, gpa, io, query, 1);
        break :blk tracks[0];
    };
    std.debug.print("▶ {s} — {s}\n", .{ t.title, t.artist });

    const audio_url = try stream.resolve(gpa, io, t);
    defer gpa.free(audio_url);

    var p = try player.Player.init();
    defer p.deinit();
    try p.loadUrl(arena, audio_url);
    while (true) {
        const ev = p.pollEvent();
        switch (ev) {
            .end_file, .shutdown => return,
            else => _ = c.usleep(50_000),
        }
    }
}

/// A lone URL or existing file is played rather than searched.
fn directTarget(arena: std.mem.Allocator, io: std.Io, words: []const [:0]const u8) ?api.Track {
    if (words.len != 1) return null;
    const arg = words[0];
    if (arg.len == 0) return null;

    const source: track_mod.Source = if (track_mod.isUrl(arg))
        .url
    else if (std.Io.Dir.cwd().statFile(io, arg, .{})) |st|
        if (st.kind == .directory) return null else .local
    else |_|
        return null;

    if (source == .url) {
        return .{ .source = .url, .uri = arg, .title = arg, .artist = "stream" };
    }

    const meta = tags_mod.readOrPath(arena, arg);
    return .{
        .source = .local,
        .uri = arg,
        .title = if (meta.title.len > 0) meta.title else std.fs.path.basename(arg),
        .artist = if (meta.artist.len > 0) meta.artist else "local file",
        .album = meta.album,
        .duration_s = meta.duration_s,
    };
}

fn cmdSearch(gpa: std.mem.Allocator, arena: std.mem.Allocator, io: std.Io, words: []const [:0]const u8) !void {
    const query = try joinArgs(arena, words);
    const tracks = try api.search(arena, gpa, io, query, 12);

    var buf: [4096]u8 = undefined;
    for (tracks, 0..) |t, i| {
        const line = try std.fmt.bufPrint(&buf, "{d:2}. {s} — {s}  [{s}]\n", .{ i + 1, t.title, t.artist, t.video_id });
        try putStdout(line);
    }
}

/// Paths in use, settings, library state and required binaries — written for pasting into a bug report.
/// Podcast subscriptions: subscribe, list, unsubscribe, print episodes.
fn cmdFeeds(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    io: std.Io,
    env: *std.process.Environ.Map,
    args: []const [:0]const u8,
) !void {
    var buf: [4096]u8 = undefined;
    const fpath = feed.path(arena, env) catch {
        std.debug.print("no data path (HOME unset)\n", .{});
        return;
    };
    var subs: std.ArrayList(feed.Sub) = .empty;
    try subs.appendSlice(arena, feed.loadSubs(arena, fpath));

    if (args.len == 0) {
        if (subs.items.len == 0) {
            try putStdout("no subscriptions — try: hum feeds add <url>\n");
            return;
        }
        for (subs.items) |sub| {
            try putStdout(try std.fmt.bufPrint(&buf, "{s}\n  {s}\n", .{
                if (sub.title.len > 0) sub.title else "(untitled)",
                sub.url,
            }));
        }
        return;
    }

    if (eq(args[0], "add")) {
        if (args.len < 2) {
            try putStdout("usage: hum feeds add <url>\n");
            return;
        }
        const url = args[1];
        if (!feed.validUrl(url)) {
            try putStdout("that is not an http(s) feed url\n");
            return;
        }
        for (subs.items) |sub| {
            if (std.mem.eql(u8, sub.url, url)) {
                try putStdout("already subscribed\n");
                return;
            }
        }
        const body = feed.fetch(gpa, io, url) catch {
            try putStdout("could not fetch that feed (see log)\n");
            return;
        };
        defer gpa.free(body);
        const parsed = feed.parse(arena, body) orelse {
            try putStdout("that url did not look like an RSS or Atom feed\n");
            return;
        };
        try subs.append(arena, .{ .url = url, .title = parsed.title });
        try feed.saveSubs(arena, fpath, subs.items);
        try putStdout(try std.fmt.bufPrint(&buf, "subscribed: {s}  ({d} episodes)\n", .{
            if (parsed.title.len > 0) parsed.title else url,
            parsed.episodes.len,
        }));
        return;
    }

    if (eq(args[0], "remove") or eq(args[0], "rm")) {
        if (args.len < 2) {
            try putStdout("usage: hum feeds remove <url>\n");
            return;
        }
        var keep: std.ArrayList(feed.Sub) = .empty;
        var dropped = false;
        for (subs.items) |sub| {
            if (std.mem.eql(u8, sub.url, args[1])) {
                dropped = true;
                continue;
            }
            try keep.append(arena, sub);
        }
        if (!dropped) {
            try putStdout("not subscribed to that url\n");
            return;
        }
        try feed.saveSubs(arena, fpath, keep.items);
        try putStdout("unsubscribed\n");
        return;
    }

    // `hum feeds <substring>` prints that feed's episodes
    for (subs.items) |sub| {
        const hay = if (sub.title.len > 0) sub.title else sub.url;
        if (!containsIgnoreCase(hay, args[0]) and !containsIgnoreCase(sub.url, args[0])) continue;
        const body = feed.fetch(gpa, io, sub.url) catch {
            try putStdout("could not fetch that feed (see log)\n");
            return;
        };
        defer gpa.free(body);
        const parsed = feed.parse(arena, body) orelse {
            try putStdout("feed did not parse\n");
            return;
        };
        for (parsed.episodes, 0..) |ep, i| {
            var dur: [16]u8 = undefined;
            const when = if (ep.duration_s > 0)
                std.fmt.bufPrint(&dur, "{d}:{d:0>2}", .{ ep.duration_s / 60, ep.duration_s % 60 }) catch ""
            else
                "";
            try putStdout(try std.fmt.bufPrint(&buf, "{d:2}. {s}  {s}\n    {s}\n", .{ i + 1, ep.title, when, ep.url }));
        }
        return;
    }
    try putStdout("no subscription matches that\n");
}

fn containsIgnoreCase(hay: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or needle.len > hay.len) return false;
    var i: usize = 0;
    while (i + needle.len <= hay.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(hay[i .. i + needle.len], needle)) return true;
    }
    return false;
}

fn cmdDoctor(arena: std.mem.Allocator, io: std.Io, env: *std.process.Environ.Map) !void {
    _ = io;
    var buf: [4096]u8 = undefined;
    try putStdout("hum " ++ VERSION ++ "\n\n");

    try putStdout("paths\n");
    const known = [_]struct { label: []const u8, path: ?[]const u8 }{
        .{ .label = "config", .path = config.path(arena, env) catch null },
        .{ .label = "history", .path = history.path(arena, env) catch null },
        .{ .label = "playlists", .path = playlist.path(arena, env) catch null },
        .{ .label = "log", .path = log.path(arena, env) catch null },
        .{ .label = "library cache", .path = library.cachePath(arena, env) catch null },
    };
    var legacy_seen = false;
    for (known) |k| {
        const path = k.path orelse {
            try putStdout(try std.fmt.bufPrint(&buf, "  {s: <14} (unavailable — HOME unset?)\n", .{k.label}));
            continue;
        };
        const legacy = std.mem.indexOf(u8, path, "/ytcli/") != null;
        if (legacy) legacy_seen = true;
        try putStdout(try std.fmt.bufPrint(&buf, "  {s: <14} {s}{s}{s}\n", .{
            k.label,
            path,
            if (exists(arena, path)) "" else "   (not created yet)",
            if (legacy) "   [pre-rename dir, still read]" else "",
        }));
    }
    if (legacy_seen) {
        try putStdout("  note: reading directories from before the ytcli→hum rename. Nothing was moved;\n" ++
            "        delete or rename them yourself if you want the new locations.\n");
    }

    try putStdout("\nsettings\n");
    const cfg = config.path(arena, env) catch "";
    inline for (.{ "theme", "volume", "scope", "splash", "music_dir" }) |key| {
        const val = if (cfg.len > 0) config.loadKey(arena, cfg, key) else null;
        try putStdout(try std.fmt.bufPrint(&buf, "  {s: <14} {s}\n", .{ key, val orelse "(unset)" }));
    }

    try putStdout("\nlibrary\n");
    const music_dir = if (cfg.len > 0) config.loadKey(arena, cfg, "music_dir") else null;
    if (music_dir) |dir| {
        const dirs = library.roots(arena, env, dir) catch &.{};
        for (dirs) |root| {
            try putStdout(try std.fmt.bufPrint(&buf, "  root           {s}{s}\n", .{
                root,
                if (exists(arena, root)) "" else "   MISSING",
            }));
        }
        const cache_path = library.cachePath(arena, env) catch "";
        const cached: library.Cached = if (cache_path.len > 0) library.loadCache(arena, cache_path) else .{};
        if (cached.entries.len == 0) {
            try putStdout("  index          empty — run: hum library scan\n");
        } else if (!cached.matches(dir)) {
            try putStdout(try std.fmt.bufPrint(&buf, "  index          {d} tracks, but built from a different music_dir — rescan\n", .{cached.entries.len}));
        } else {
            try putStdout(try std.fmt.bufPrint(&buf, "  index          {d} tracks\n", .{cached.entries.len}));
        }
    } else {
        try putStdout("  music_dir unset — run: hum library dir ~/Music\n");
    }

    try putStdout("\ndependencies\n");
    inline for (.{ "curl", "yt-dlp" }) |exe| {
        if (onPath(arena, env, exe)) |full| {
            try putStdout(try std.fmt.bufPrint(&buf, "  {s: <14} {s}\n", .{ exe, full }));
        } else {
            try putStdout("  " ++ exe ++ (" " ** (14 - exe.len)) ++ " MISSING — youtube search and playback will fail\n");
        }
    }
    try putStdout("  libmpv         linked at build time (local files need nothing else)\n");
}

fn exists(arena: std.mem.Allocator, path: []const u8) bool {
    const z = arena.dupeZ(u8, path) catch return false;
    return c.access(z.ptr, 0) == 0; // F_OK
}

/// First hit in $PATH — the same lookup the subprocess spawn will do.
fn onPath(arena: std.mem.Allocator, env: *std.process.Environ.Map, name: []const u8) ?[]const u8 {
    const path_env = env.get("PATH") orelse return null;
    var it = std.mem.splitScalar(u8, path_env, ':');
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        const full = std.fmt.allocPrint(arena, "{s}/{s}", .{ dir, name }) catch continue;
        const z = arena.dupeZ(u8, full) catch continue;
        if (c.access(z.ptr, 1) == 0) return full; // X_OK
    }
    return null;
}

fn cmdLibrary(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    io: std.Io,
    env: *std.process.Environ.Map,
    args: []const [:0]const u8,
) !void {
    _ = gpa;
    var buf: [4096]u8 = undefined;
    const cfg = config.path(arena, env) catch {
        std.debug.print("no config path (HOME unset)\n", .{});
        return;
    };

    if (args.len > 0 and eq(args[0], "dir")) {
        if (args.len < 2) {
            try putStdout("usage: hum library dir <path>\n");
            return;
        }
        try config.saveKey(arena, cfg, "music_dir", args[1]);
        try putStdout(try std.fmt.bufPrint(&buf, "music_dir = {s}\n", .{args[1]}));
        return;
    }

    const music_dir = config.loadKey(arena, cfg, "music_dir") orelse {
        try putStdout("no music_dir set — try: hum library dir ~/Music\n");
        return;
    };
    const cache = library.cachePath(arena, env) catch "";
    const from_disk: library.Cached = if (cache.len > 0) library.loadCache(arena, cache) else .{};
    // a cache from other roots describes another library
    var entries: []library.Entry = if (from_disk.matches(music_dir)) from_disk.entries else &.{};

    const rescan = args.len > 0 and eq(args[0], "scan");
    if (rescan or entries.len == 0) {
        const dirs = try library.roots(arena, env, music_dir);
        const res = try library.scan(arena, io, dirs, entries, null);
        entries = res.entries;
        if (res.complete and cache.len > 0) library.saveCache(arena, cache, music_dir, entries) catch {};
    }

    const artists = try library.artistsOf(arena, entries);
    try putStdout(try std.fmt.bufPrint(&buf, "{d} tracks · {d} artists · {s}\n", .{ entries.len, artists.len, music_dir }));
    for (artists) |name| {
        var count: usize = 0;
        for (entries) |e| {
            if (std.ascii.eqlIgnoreCase(e.artist, name)) count += 1;
        }
        try putStdout(try std.fmt.bufPrint(&buf, "  {s}  [{d}]\n", .{ name, count }));
    }
}

fn cmdPlaylists(arena: std.mem.Allocator, env: *std.process.Environ.Map, want: ?[]const u8) !void {
    const ppath = playlist.path(arena, env) catch {
        std.debug.print("no playlists (HOME unset)\n", .{});
        return;
    };
    const lists = try playlist.load(arena, ppath);
    if (lists.len == 0) {
        std.debug.print("(no playlists — press P on a result in the TUI)\n", .{});
        return;
    }
    var buf: [4096]u8 = undefined;
    for (lists) |e| {
        if (want) |name| {
            if (!std.mem.eql(u8, e.name, name)) continue;
            for (e.tracks, 0..) |t, i| {
                try putStdout(try std.fmt.bufPrint(&buf, "{d:2}. {s} — {s}  [{s}]\n", .{ i + 1, t.title, t.artist, t.video_id }));
            }
            return;
        }
        try putStdout(try std.fmt.bufPrint(&buf, "{s}  [{d}]\n", .{ e.name, e.tracks.len }));
    }
    if (want) |name| std.debug.print("no playlist named {s}\n", .{name});
}

fn cmdHistory(arena: std.mem.Allocator, env: *std.process.Environ.Map) !void {
    const hpath = history.path(arena, env) catch {
        std.debug.print("no history (HOME unset)\n", .{});
        return;
    };
    const items = try history.load(arena, hpath);
    if (items.len == 0) {
        std.debug.print("(history empty)\n", .{});
        return;
    }
    var buf: [1024]u8 = undefined;
    for (items) |s| {
        const line = try std.fmt.bufPrint(&buf, "{s}\n", .{s});
        try putStdout(line);
    }
}
