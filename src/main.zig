const std = @import("std");
const api = @import("api.zig");
const stream = @import("stream.zig");
const player = @import("player.zig");
const ui = @import("ui.zig");
const history = @import("history.zig");
const playlist = @import("playlist.zig");
const theme_mod = @import("theme.zig");
const config = @import("config.zig");
const log = @import("log.zig");

const c = @cImport({
    @cDefine("_FORTIFY_SOURCE", "0");
    @cInclude("unistd.h");
});

fn putStdout(bytes: []const u8) !void {
    var i: usize = 0;
    while (i < bytes.len) {
        const n = c.write(1, bytes[i..].ptr, bytes.len - i);
        if (n <= 0) return error.WriteFailed;
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
        try putStdout("ytcli " ++ VERSION ++ "\n");
        return;
    }
    if (eq(first, "history")) {
        try cmdHistory(arena, init.environ_map);
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
    if (env.get("YTCLI_THEME")) |e| {
        if (theme_mod.byName(e) != null) name = e;
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
        \\ytcli — terminal YouTube Music client
        \\
        \\usage:
        \\  ytcli                    launch TUI
        \\  ytcli <query>            play first hit for <query>
        \\  ytcli -s <query>         print top results, no playback
        \\  ytcli history            print recent queries (newest first)
        \\  ytcli playlists [name]   list saved playlists, or one playlist's tracks
        \\  ytcli -h, --help         this message
        \\  ytcli -v, --version      print version
        \\
        \\options:
        \\  --theme <name>           color theme ({s})
        \\  --themes                 list available themes
        \\  YTCLI_THEME env          same as --theme
        \\  Ctrl+Y inside the TUI    cycle through themes live
        \\
    , .{theme_mod.names}) catch return error.WriteFailed;
    try putStdout(text);
}

fn cmdPlay(gpa: std.mem.Allocator, arena: std.mem.Allocator, io: std.Io, words: []const [:0]const u8) !void {
    const query = try joinArgs(arena, words);
    const tracks = try api.search(arena, gpa, io, query, 1);
    const t = tracks[0];
    std.debug.print("▶ {s} — {s}\n", .{ t.title, t.artist });

    const audio_url = try stream.resolveAudioUrl(gpa, io, t.video_id);
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

fn cmdSearch(gpa: std.mem.Allocator, arena: std.mem.Allocator, io: std.Io, words: []const [:0]const u8) !void {
    const query = try joinArgs(arena, words);
    const tracks = try api.search(arena, gpa, io, query, 12);

    var buf: [4096]u8 = undefined;
    for (tracks, 0..) |t, i| {
        const line = try std.fmt.bufPrint(&buf, "{d:2}. {s} — {s}  [{s}]\n", .{ i + 1, t.title, t.artist, t.video_id });
        try putStdout(line);
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
