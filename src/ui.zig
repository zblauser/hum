const std = @import("std");
const posix = std.posix;

const c = @cImport({
    @cDefine("_FORTIFY_SOURCE", "0");
    @cInclude("unistd.h");
});

const api = @import("api.zig");
const stream = @import("stream.zig");
const player = @import("player.zig");
const suggest = @import("suggest.zig");
const history = @import("history.zig");
const playlist = @import("playlist.zig");
const theme_mod = @import("theme.zig");
const config = @import("config.zig");
const log = @import("log.zig");

const STDIN: posix.fd_t = 0;
const STDOUT: posix.fd_t = 1;

const SUGGEST_DEBOUNCE_MS: i32 = 250;
const MAX_SUGGESTIONS: usize = 24;
const MAX_RESULTS: usize = 50;
const VIS_BARS: usize = 28;
const TICK_MS_PLAYING: i32 = 100;
const TICK_MS_IDLE: i32 = 250;

const TYPING_STATUS = "type to search · ↑/↓ pick · ⏎ go · ^C quit";

const Phase = enum { typing, results, picker };
const Repeat = enum { off, track, queue };

const State = struct {
    phase: Phase = .typing,
    query: std.ArrayList(u8) = .empty,
    suggestions: [][]const u8 = &.{},
    sel_row: ?usize = null,
    scroll_row: usize = 0,
    last_fetched_query: []const u8 = "",
    filter: api.Filter = .all,

    tracks: []api.Track = &.{},
    sel_track: usize = 0,
    scroll_track: usize = 0,

    playlists: []playlist.Entry = &.{},
    pl_path: []const u8 = "",
    view_pl: ?usize = null,
    picker_sel: usize = 0,
    picker_name: std.ArrayList(u8) = .empty,
    picker_track: ?api.Track = null,
    picker_from: Phase = .typing,

    status: []const u8 = TYPING_STATUS,
    status_buf: [192]u8 = undefined,
    pl_del_pending: bool = false,
    hist: []const []const u8 = &.{},
    hist_path: []const u8 = "",
    config_path: []const u8 = "",
    theme: theme_mod.Theme = theme_mod.default,
    theme_idx: usize = 0,

    pl: ?*player.Player = null,
    queue: []api.Track = &.{},
    queue_idx: usize = 0,
    now_track: ?api.Track = null,
    connecting: bool = false,
    volume: f64 = 100,
    repeat: Repeat = .off,

    tick: u64 = 0,

    search_arena: std.heap.ArenaAllocator = undefined,

    sug_arena: std.heap.ArenaAllocator = undefined,

    play_arena: std.heap.ArenaAllocator = undefined,

    hist_arena: std.heap.ArenaAllocator = undefined,

    lib_arena: std.heap.ArenaAllocator = undefined,

    draw_buf: std.ArrayList(u8) = .empty,
};

pub fn run(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    io: std.Io,
    env: *std.process.Environ.Map,
    theme: theme_mod.Theme,
    theme_idx: usize,
) !void {
    const orig_termios = try enterRaw();
    defer restoreTty(orig_termios);

    saved_termios = orig_termios;
    installInterruptHandlers();

    try writeAll("\x1b[?1049h\x1b[?25l");
    defer writeAll("\x1b[?25h\x1b[?1049l") catch {};

    var state: State = .{ .theme = theme, .theme_idx = theme_idx };
    state.search_arena = std.heap.ArenaAllocator.init(gpa);
    state.sug_arena = std.heap.ArenaAllocator.init(gpa);
    state.play_arena = std.heap.ArenaAllocator.init(gpa);
    state.hist_arena = std.heap.ArenaAllocator.init(gpa);
    state.lib_arena = std.heap.ArenaAllocator.init(gpa);
    state.hist_path = history.path(arena, env) catch "";
    state.pl_path = playlist.path(arena, env) catch "";
    reloadPlaylists(&state);
    state.config_path = config.path(arena, env) catch "";
    if (state.config_path.len > 0) {
        if (config.loadKey(arena, state.config_path, "volume")) |v| {
            state.volume = std.math.clamp(std.fmt.parseFloat(f64, v) catch 100, 0, 100);
        }
    }
    if (state.hist_path.len > 0) {
        state.hist = history.load(state.hist_arena.allocator(), state.hist_path) catch &.{};
    }
    state.suggestions = try history.match(state.sug_arena.allocator(), state.hist, "", MAX_SUGGESTIONS);

    defer {
        state.query.deinit(gpa);
        state.picker_name.deinit(gpa);
        state.draw_buf.deinit(gpa);
        state.lib_arena.deinit();
        state.search_arena.deinit();
        state.sug_arena.deinit();
        state.play_arena.deinit();
        state.hist_arena.deinit();
        if (state.pl) |p| {
            p.deinit();
            gpa.destroy(p);
        }
    }

    while (true) {
        draw(gpa, &state) catch |err| survive(&state, "draw", err);

        const playing = state.pl != null and (state.pl.?.has_track);
        const timeout: i32 = if (playing) TICK_MS_PLAYING else TICK_MS_IDLE;

        if (state.pl) |p| {
            while (true) {
                const ev = p.pollEvent();
                if (ev == .none) break;
                handlePlayerEvent(gpa, arena, io, &state, ev) catch |err| survive(&state, "player event", err);
            }
        }

        if (try waitInput(timeout)) {
            const cont = handleKey(gpa, arena, io, &state) catch |err| blk: {
                survive(&state, "key", err);
                break :blk true;
            };
            if (!cont) return;
        } else {
            state.tick +%= 1;
            if (state.phase == .typing and !std.mem.eql(u8, state.query.items, state.last_fetched_query)) {
                refreshSuggestions(gpa, io, &state) catch |err| survive(&state, "suggest", err);
            }
        }
    }
}

/// Keep the TUI alive on a recoverable failure: log it, say so, don't unwind past the
/// alt-screen teardown (an escaping error prints a stack trace over the restored terminal).
fn survive(state: *State, what: []const u8, err: anyerror) void {
    log.write("{s} failed: {s} phase={s}", .{ what, @errorName(err), @tagName(state.phase) });
    setStatus(state, "{s} failed: {s} (see log)", .{ what, @errorName(err) });
}

fn waitInput(timeout_ms: i32) !bool {
    var fds = [_]posix.pollfd{.{ .fd = STDIN, .events = posix.POLL.IN, .revents = 0 }};
    const n = try posix.poll(&fds, timeout_ms);
    return n > 0 and (fds[0].revents & posix.POLL.IN) != 0;
}

const Key = union(enum) {
    text: []const u8,
    up,
    down,
    left,
    right,
    enter,
    backspace,
    escape,
    tab,
    page_up,
    page_down,
    home,
    end,
    ctrl_c,
    ctrl: u8,
    unknown,
};

fn readKey(buf: *[8]u8) !Key {
    var one: [1]u8 = undefined;
    if ((try posix.read(STDIN, &one)) == 0) return .unknown;
    const b = one[0];
    switch (b) {
        0x03, 0x04 => return .ctrl_c,
        0x09 => return .tab,
        0x0a, 0x0d => return .enter,
        0x7f, 0x08 => return .backspace,
        0x1b => return readEscape(buf),
        else => {
            if (b < 0x20) return Key{ .ctrl = b };
            const n_cont: usize = if (b < 0x80) 0 else if (b < 0xC0) 0 else if (b < 0xE0) 1 else if (b < 0xF0) 2 else 3;
            buf[0] = b;
            var i: usize = 1;
            while (i <= n_cont) : (i += 1) {
                var more: [1]u8 = undefined;
                if ((try posix.read(STDIN, &more)) == 0) break;
                buf[i] = more[0];
            }
            return Key{ .text = buf[0 .. n_cont + 1] };
        },
    }
}

fn readEscape(_: *[8]u8) !Key {
    if (!(try waitInput(20))) return .escape;
    var c1: [1]u8 = undefined;
    if ((try posix.read(STDIN, &c1)) == 0) return .escape;
    if (c1[0] != '[' and c1[0] != 'O') return .escape;
    if (!(try waitInput(20))) return .escape;
    var c2: [1]u8 = undefined;
    if ((try posix.read(STDIN, &c2)) == 0) return .escape;
    return switch (c2[0]) {
        'A' => .up,
        'B' => .down,
        'C' => .right,
        'D' => .left,
        'H' => .home,
        'F' => .end,
        '5' => blk: {
            var t: [1]u8 = undefined;
            _ = posix.read(STDIN, &t) catch 0;
            break :blk .page_up;
        },
        '6' => blk: {
            var t: [1]u8 = undefined;
            _ = posix.read(STDIN, &t) catch 0;
            break :blk .page_down;
        },
        else => .unknown,
    };
}

fn handleKey(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    io: std.Io,
    state: *State,
) !bool {
    var buf: [8]u8 = undefined;
    const key = readKey(&buf) catch return true;

    switch (key) {
        .ctrl => |b| switch (b) {
            0x10 => { // Ctrl+P
                if (state.pl) |p| _ = p.togglePause();
                return true;
            },
            0x0e => { // Ctrl+N
                try queueAdvance(gpa, arena, io, state, false);
                return true;
            },
            0x13 => { // Ctrl+S
                if (state.pl) |p| {
                    p.stop();
                    state.now_track = null;
                }
                return true;
            },
            0x01 => { // Ctrl+A — save the playing track from any screen
                if (state.now_track) |t| openPicker(state, t) else state.status = "nothing playing to save";
                return true;
            },
            0x12 => { // Ctrl+R
                state.repeat = switch (state.repeat) {
                    .off => .track,
                    .track => .queue,
                    .queue => .off,
                };
                state.status = switch (state.repeat) {
                    .off => "repeat: off",
                    .track => "repeat: track",
                    .queue => "repeat: queue",
                };
                return true;
            },
            0x19 => { // Ctrl+Y
                state.theme_idx = (state.theme_idx + 1) % theme_mod.all.len;
                state.theme = theme_mod.all[state.theme_idx].theme;
                state.status = theme_mod.all[state.theme_idx].name;
                if (state.config_path.len > 0) {
                    config.saveTheme(arena, state.config_path, theme_mod.all[state.theme_idx].name);
                }
                return true;
            },
            else => {},
        },
        else => {},
    }

    return switch (state.phase) {
        .typing => try handleTyping(gpa, arena, io, state, key),
        .results => try handleResults(gpa, arena, io, state, key),
        .picker => try handlePicker(gpa, state, key),
    };
}

fn handleTyping(
    gpa: std.mem.Allocator,
    _: std.mem.Allocator,
    io: std.Io,
    state: *State,
    key: Key,
) !bool {
    var pl_buf: [MAX_PL_ROWS]usize = undefined;
    const pls = matchedPlaylists(state, &pl_buf);
    const total = pls.len + state.suggestions.len;
    const on_playlist = if (state.sel_row) |r| r < pls.len else false;
    if (key != .ctrl) state.pl_del_pending = false;
    switch (key) {
        .ctrl_c => return false,
        .ctrl => |b| switch (b) {
            0x18 => if (state.sel_row) |row| { // Ctrl+X — delete the selected playlist or past search
                if (on_playlist) {
                    const idx = pls[row];
                    if (state.pl_del_pending) {
                        state.pl_del_pending = false;
                        deletePlaylist(gpa, state, idx);
                    } else {
                        state.pl_del_pending = true;
                        setStatus(state, "^X again to delete {s}", .{state.playlists[idx].name});
                    }
                } else if (selectedSuggestion(state)) |q| {
                    if (state.pl_del_pending) {
                        state.pl_del_pending = false;
                        forgetSearch(gpa, state, q);
                    } else {
                        state.pl_del_pending = true;
                        setStatus(state, "^X again to forget {s}", .{q});
                    }
                }
            },
            0x14 => { // Ctrl+T
                state.filter = switch (state.filter) {
                    .all => .songs,
                    .songs => .videos,
                    .videos => .albums,
                    .albums => .artists,
                    .artists => .all,
                };
                state.status = state.filter.label();
            },
            else => {},
        },
        .escape => {
            state.query.clearRetainingCapacity();
            state.sel_row = null;
            state.last_fetched_query = "";
            _ = state.sug_arena.reset(.retain_capacity);
            state.suggestions = try history.match(state.sug_arena.allocator(), state.hist, "", MAX_SUGGESTIONS);
            state.scroll_row = 0;
        },
        .up => if (total > 0) {
            state.sel_row = if (state.sel_row) |i| (if (i == 0) total - 1 else i - 1) else total - 1;
        },
        .down => if (total > 0) {
            state.sel_row = if (state.sel_row) |i| ((i + 1) % total) else 0;
        },
        .tab, .right => {
            if (on_playlist) {
                openPlaylist(state, pls[state.sel_row.?]);
                return true;
            }
            for (state.suggestions) |s| {
                if (s.len > state.query.items.len and std.ascii.startsWithIgnoreCase(s, state.query.items)) {
                    state.query.clearRetainingCapacity();
                    try state.query.appendSlice(gpa, s);
                    state.sel_row = null;
                    try refreshSuggestionsLocal(state);
                    break;
                }
            }
        },
        .enter => if (on_playlist) openPlaylist(state, pls[state.sel_row.?]) else try runSearch(gpa, io, state),
        .backspace => if (state.query.items.len > 0) {
            var n: usize = 1;
            while (n <= state.query.items.len) : (n += 1) {
                const b = state.query.items[state.query.items.len - n];
                if ((b & 0xC0) != 0x80) break;
            }
            state.query.shrinkRetainingCapacity(state.query.items.len - n);
            state.sel_row = null;
            try refreshSuggestionsLocal(state);
        },
        .text => |t| {
            try state.query.appendSlice(gpa, t);
            state.sel_row = null;
            try refreshSuggestionsLocal(state);
        },
        else => {},
    }
    return true;
}

fn handleResults(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    io: std.Io,
    state: *State,
    key: Key,
) !bool {
    const n = state.tracks.len;
    const max_idx = if (n == 0) 0 else n - 1;
    switch (key) {
        .ctrl_c => return false,
        .escape => backToTyping(state),
        .up => if (state.sel_track > 0) {
            state.sel_track -= 1;
        },
        .down => if (state.sel_track + 1 < n) {
            state.sel_track += 1;
        },
        .left => backToTyping(state),
        .right => try activateSelected(gpa, arena, io, state),
        .page_down => state.sel_track = @min(state.sel_track + 10, max_idx),
        .page_up => state.sel_track = if (state.sel_track > 10) state.sel_track - 10 else 0,
        .home => state.sel_track = 0,
        .end => state.sel_track = max_idx,
        .enter => try activateSelected(gpa, arena, io, state),
        .ctrl => |b| switch (b) {
            0x06 => state.sel_track = @min(state.sel_track + 10, max_idx), // Ctrl+F
            0x02 => state.sel_track = if (state.sel_track > 10) state.sel_track - 10 else 0, // Ctrl+B
            0x18 => if (state.view_pl != null) removeFromPlaylist(gpa, state), // Ctrl+X
            else => {},
        },
        .text => |t| {
            if (t.len == 1) {
                switch (t[0]) {
                    'j' => if (state.sel_track + 1 < n) {
                        state.sel_track += 1;
                    },
                    'k' => if (state.sel_track > 0) {
                        state.sel_track -= 1;
                    },
                    'h' => backToTyping(state),
                    'P' => openPicker(state, if (state.tracks.len > 0) state.tracks[state.sel_track] else null),
                    'd' => if (state.view_pl != null) removeFromPlaylist(gpa, state),
                    'l' => try activateSelected(gpa, arena, io, state),
                    'g' => state.sel_track = 0,
                    'G' => state.sel_track = max_idx,
                    ' ' => if (state.pl) |p| {
                        _ = p.togglePause();
                    },
                    '[' => if (state.pl) |p| {
                        p.seekRelative(-10);
                    },
                    ']' => if (state.pl) |p| {
                        p.seekRelative(10);
                    },
                    '{' => if (state.pl) |p| {
                        p.seekRelative(-60);
                    },
                    '}' => if (state.pl) |p| {
                        p.seekRelative(60);
                    },
                    '-', '_' => if (state.pl) |p| {
                        state.volume = p.nudgeVolume(-5);
                        persistVolume(arena, state);
                    },
                    '=', '+' => if (state.pl) |p| {
                        state.volume = p.nudgeVolume(5);
                        persistVolume(arena, state);
                    },
                    'm' => if (state.pl) |p| {
                        _ = p.toggleMute();
                    },
                    else => {},
                }
            }
        },
        else => {},
    }
    return true;
}

fn backToTyping(state: *State) void {
    state.phase = .typing;
    if (state.view_pl != null) {
        state.view_pl = null;
        state.tracks = &.{}; // tracks were borrowed from lib_arena
    }
    // suggestions point into hist_arena, which a search since then may have recycled
    refreshSuggestionsLocal(state) catch {
        state.suggestions = &.{};
    };
    state.status = TYPING_STATUS;
}

/// Reload the history file, then rebuild the suggestions that borrow from it.
fn reloadHistory(state: *State) void {
    if (state.hist_path.len == 0) return;
    _ = state.hist_arena.reset(.retain_capacity);
    state.hist = history.load(state.hist_arena.allocator(), state.hist_path) catch &.{};
    refreshSuggestionsLocal(state) catch {
        state.suggestions = &.{};
    };
}

fn forgetSearch(gpa: std.mem.Allocator, state: *State, query: []const u8) void {
    if (state.hist_path.len == 0) return;
    var name_buf: [256]u8 = undefined;
    const kept = name_buf[0..@min(query.len, name_buf.len)];
    @memcpy(kept, query[0..kept.len]);

    var tmp = std.heap.ArenaAllocator.init(gpa);
    defer tmp.deinit();
    history.remove(tmp.allocator(), state.hist_path, kept) catch |err| {
        if (err == error.NotFound) {
            state.status = "that one is not in your history";
        } else {
            log.write("history remove failed: {s} query=\"{s}\"", .{ @errorName(err), kept });
            state.status = "history write failed (see log)";
        }
        return;
    };
    reloadHistory(state);
    state.sel_row = null;
    setStatus(state, "forgot {s}", .{kept});
}

fn setStatus(state: *State, comptime fmt: []const u8, args: anytype) void {
    state.status = std.fmt.bufPrint(&state.status_buf, fmt, args) catch "ok";
}

const MAX_PL_ROWS = 64;

/// Playlists whose name matches the current query, newest section of the typing view.
fn matchedPlaylists(state: *State, buf: []usize) []usize {
    var n: usize = 0;
    for (state.playlists, 0..) |e, i| {
        if (n >= buf.len) break;
        if (state.query.items.len == 0 or std.ascii.startsWithIgnoreCase(e.name, state.query.items)) {
            buf[n] = i;
            n += 1;
        }
    }
    return buf[0..n];
}

fn selectedSuggestion(state: *State) ?[]const u8 {
    const row = state.sel_row orelse return null;
    var buf: [MAX_PL_ROWS]usize = undefined;
    const pls = matchedPlaylists(state, &buf);
    if (row < pls.len) return null;
    const i = row - pls.len;
    return if (i < state.suggestions.len) state.suggestions[i] else null;
}

fn reloadPlaylists(state: *State) void {
    if (state.pl_path.len == 0) return;
    _ = state.lib_arena.reset(.retain_capacity);
    state.playlists = playlist.load(state.lib_arena.allocator(), state.pl_path) catch &.{};
    state.sel_row = null;
    const viewed = state.view_pl orelse {
        if (state.phase != .results) state.tracks = &.{};
        return;
    };
    if (viewed < state.playlists.len) {
        state.tracks = state.playlists[viewed].tracks;
        if (state.sel_track >= state.tracks.len) state.sel_track = state.tracks.len -| 1;
    } else {
        state.view_pl = null;
        state.tracks = &.{};
        state.phase = .typing;
    }
}

fn openPlaylist(state: *State, idx: usize) void {
    const e = state.playlists[idx];
    if (e.tracks.len == 0) {
        setStatus(state, "{s} is empty", .{e.name});
        return;
    }
    state.view_pl = idx;
    state.tracks = e.tracks;
    state.sel_track = 0;
    state.scroll_track = 0;
    state.phase = .results;
    setStatus(state, "{s} · ⏎/l play · P add · d remove · h back", .{e.name});
}

fn addToPlaylist(gpa: std.mem.Allocator, state: *State, name: []const u8) void {
    const t = state.picker_track orelse return;
    const clean = playlist.cleanName(name);
    if (state.pl_path.len == 0 or clean.len == 0) {
        state.status = "name that playlist first";
        return;
    }
    var name_buf: [96]u8 = undefined;
    const kept = name_buf[0..@min(clean.len, name_buf.len)];
    @memcpy(kept, clean[0..kept.len]);

    var tmp = std.heap.ArenaAllocator.init(gpa);
    defer tmp.deinit();
    playlist.addTrack(tmp.allocator(), state.pl_path, kept, t) catch |err| {
        if (err == error.AlreadyPresent) {
            setStatus(state, "already in {s}", .{kept});
        } else {
            log.write("playlist add failed: {s} name=\"{s}\" video_id={s}", .{ @errorName(err), kept, t.video_id });
            state.status = "playlist save failed (see log)";
        }
        state.phase = state.picker_from;
        return;
    };
    const from = state.picker_from;
    reloadPlaylists(state);
    setStatus(state, "added to {s}", .{kept});
    state.phase = if (from == .results and state.tracks.len == 0) .typing else from;
}

fn removeFromPlaylist(gpa: std.mem.Allocator, state: *State) void {
    const viewed = state.view_pl orelse return;
    if (state.tracks.len == 0 or viewed >= state.playlists.len) return;
    var name_buf: [96]u8 = undefined;
    const src = state.playlists[viewed].name;
    const kept = name_buf[0..@min(src.len, name_buf.len)];
    @memcpy(kept, src[0..kept.len]);

    var tmp = std.heap.ArenaAllocator.init(gpa);
    defer tmp.deinit();
    playlist.removeTrack(tmp.allocator(), state.pl_path, kept, state.sel_track) catch |err| {
        log.write("playlist remove failed: {s} name=\"{s}\" idx={d}", .{ @errorName(err), kept, state.sel_track });
        state.status = "playlist save failed (see log)";
        return;
    };
    reloadPlaylists(state);
    setStatus(state, "removed from {s}", .{kept});
}

fn deletePlaylist(gpa: std.mem.Allocator, state: *State, idx: usize) void {
    if (idx >= state.playlists.len) return;
    var name_buf: [96]u8 = undefined;
    const src = state.playlists[idx].name;
    const kept = name_buf[0..@min(src.len, name_buf.len)];
    @memcpy(kept, src[0..kept.len]);

    var tmp = std.heap.ArenaAllocator.init(gpa);
    defer tmp.deinit();
    playlist.removeList(tmp.allocator(), state.pl_path, kept) catch |err| {
        log.write("playlist delete failed: {s} name=\"{s}\"", .{ @errorName(err), kept });
        state.status = "playlist save failed (see log)";
        return;
    };
    state.view_pl = null;
    reloadPlaylists(state);
    setStatus(state, "deleted {s}", .{kept});
}

fn openPicker(state: *State, track: ?api.Track) void {
    const t = track orelse return;
    if (!t.isPlayable()) {
        state.status = "only songs and videos can be saved";
        return;
    }
    state.picker_track = t;
    state.picker_from = state.phase;
    state.picker_sel = 0;
    state.picker_name.clearRetainingCapacity();
    state.phase = .picker;
    state.status = "↑↓ pick · type to name a new one · ⏎ add · esc cancel";
}

fn handlePicker(gpa: std.mem.Allocator, state: *State, key: Key) !bool {
    const new_row = state.playlists.len;
    switch (key) {
        .ctrl_c => return false,
        .escape => {
            state.phase = state.picker_from;
            state.status = "cancelled";
        },
        .up => state.picker_sel = if (state.picker_sel == 0) new_row else state.picker_sel - 1,
        .down => state.picker_sel = if (state.picker_sel >= new_row) 0 else state.picker_sel + 1,
        .enter => {
            if (state.picker_sel < state.playlists.len) {
                addToPlaylist(gpa, state, state.playlists[state.picker_sel].name);
            } else {
                addToPlaylist(gpa, state, state.picker_name.items);
            }
        },
        .backspace => {
            state.picker_sel = new_row;
            if (state.picker_name.items.len > 0) {
                var n: usize = 1;
                while (n <= state.picker_name.items.len) : (n += 1) {
                    const b = state.picker_name.items[state.picker_name.items.len - n];
                    if ((b & 0xC0) != 0x80) break;
                }
                state.picker_name.shrinkRetainingCapacity(state.picker_name.items.len - n);
            }
        },
        .text => |t| {
            state.picker_sel = new_row;
            try state.picker_name.appendSlice(gpa, t);
        },
        else => {},
    }
    return true;
}

fn refreshSuggestionsLocal(state: *State) !void {
    _ = state.sug_arena.reset(.retain_capacity);
    const a = state.sug_arena.allocator();
    state.suggestions = try history.match(a, state.hist, state.query.items, MAX_SUGGESTIONS);
    state.scroll_row = 0;
}

fn refreshSuggestions(gpa: std.mem.Allocator, io: std.Io, state: *State) !void {
    _ = state.sug_arena.reset(.retain_capacity);
    const a = state.sug_arena.allocator();
    state.last_fetched_query = try a.dupe(u8, state.query.items);
    const local = try history.match(a, state.hist, state.query.items, MAX_SUGGESTIONS);
    const remote = suggest.fetch(a, gpa, io, state.query.items, MAX_SUGGESTIONS) catch &.{};
    var out: std.ArrayList([]const u8) = .empty;
    var seen: std.StringHashMap(void) = .init(a);
    for (local) |s| {
        if (out.items.len >= MAX_SUGGESTIONS) break;
        if (seen.contains(s)) continue;
        try seen.put(s, {});
        try out.append(a, s);
    }
    for (remote) |s| {
        if (out.items.len >= MAX_SUGGESTIONS) break;
        if (seen.contains(s)) continue;
        try seen.put(s, {});
        try out.append(a, s);
    }
    state.suggestions = try out.toOwnedSlice(a);
}

fn runSearch(gpa: std.mem.Allocator, io: std.Io, state: *State) !void {
    const q_src_raw = selectedSuggestion(state) orelse std.mem.trim(u8, state.query.items, " \t");
    if (q_src_raw.len == 0) {
        state.status = "type something first";
        return;
    }
    var q_buf: [256]u8 = undefined;
    const qlen = @min(q_src_raw.len, q_buf.len);
    @memcpy(q_buf[0..qlen], q_src_raw[0..qlen]);
    const q_src = q_buf[0..qlen];

    state.query.clearRetainingCapacity();
    try state.query.appendSlice(gpa, q_src);
    state.sel_row = null;
    state.status = "searching…";
    try draw(gpa, state);

    _ = state.search_arena.reset(.retain_capacity);
    const sa = state.search_arena.allocator();

    const tracks = api.searchFiltered(sa, gpa, io, q_src, MAX_RESULTS, state.filter) catch |err| {
        log.write("search failed: {s} query=\"{s}\" filter={s}", .{ @errorName(err), q_src, state.filter.label() });
        state.status = switch (err) {
            error.NoResult => "no results",
            else => "search failed (see log)",
        };
        state.tracks = &.{};
        return;
    };

    if (state.hist_path.len > 0) {
        history.append(sa, state.hist_path, q_src) catch {};
        reloadHistory(state);
    }

    state.tracks = tracks;
    state.sel_track = 0;
    state.scroll_track = 0;
    state.phase = .results;
    state.status = "↑↓/jk pick · g/G ⌂⌃ · ⏎/l play · h back";
}

fn persistVolume(arena: std.mem.Allocator, state: *State) void {
    if (state.config_path.len == 0) return;
    var buf: [16]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d:.0}", .{state.volume}) catch return;
    config.saveKey(arena, state.config_path, "volume", s) catch {};
}

fn ensurePlayer(gpa: std.mem.Allocator, state: *State) !*player.Player {
    if (state.pl) |p| return p;
    const p = try gpa.create(player.Player);
    p.* = try player.Player.init();
    p.setVolume(state.volume);
    state.pl = p;
    return p;
}

fn activateSelected(gpa: std.mem.Allocator, arena: std.mem.Allocator, io: std.Io, state: *State) !void {
    if (state.tracks.len == 0) return;
    const t = state.tracks[state.sel_track];
    if (t.isPlayable()) {
        _ = state.play_arena.reset(.retain_capacity);
        const pa = state.play_arena.allocator();
        var q = try pa.alloc(api.Track, state.tracks.len);
        for (state.tracks, 0..) |src, i| q[i] = try cloneTrack(pa, src);
        state.queue = q;
        state.queue_idx = state.sel_track;
        try playQueueCurrent(gpa, arena, io, state);
        return;
    }
    if (t.browse_id.len > 0) {
        state.status = "loading album…";
        try draw(gpa, state);
        const sa = state.search_arena.allocator();
        const tracks = api.browseAlbum(sa, gpa, io, t.browse_id) catch |err| {
            log.write("album load failed: {s} browse_id={s} title=\"{s}\"", .{ @errorName(err), t.browse_id, t.title });
            state.status = "album load failed (see log)";
            return;
        };
        state.tracks = tracks;
        state.sel_track = 0;
        state.scroll_track = 0;
        state.status = "album loaded · ⏎/l play · h back";
        return;
    }
    state.status = "no playable target";
}

fn cloneTrack(a: std.mem.Allocator, t: api.Track) !api.Track {
    return .{
        .video_id = try a.dupe(u8, t.video_id),
        .browse_id = try a.dupe(u8, t.browse_id),
        .title = try a.dupe(u8, t.title),
        .artist = try a.dupe(u8, t.artist),
        .kind = try a.dupe(u8, t.kind),
    };
}

fn playQueueCurrent(gpa: std.mem.Allocator, arena: std.mem.Allocator, io: std.Io, state: *State) !void {
    if (state.queue.len == 0 or state.queue_idx >= state.queue.len) return;
    const t = state.queue[state.queue_idx];

    const p = try ensurePlayer(gpa, state);
    p.stop();
    state.now_track = t;
    state.connecting = true;
    state.status = "connecting to YouTube…";
    try draw(gpa, state);

    const url = stream.resolveAudioUrl(gpa, io, t.video_id) catch |err| {
        log.write("stream resolve failed: {s} video_id={s} title=\"{s}\"", .{ @errorName(err), t.video_id, t.title });
        state.now_track = null;
        state.connecting = false;
        state.status = "yt-dlp failed (see log)";
        return;
    };
    defer gpa.free(url);

    try p.loadUrl(arena, url);
    state.connecting = false;
    state.status = "playing";
}

fn queueAdvance(gpa: std.mem.Allocator, arena: std.mem.Allocator, io: std.Io, state: *State, auto: bool) !void {
    if (state.queue.len == 0) return;
    if (auto and state.repeat == .track) {
        try playQueueCurrent(gpa, arena, io, state);
        return;
    }
    if (state.queue_idx + 1 >= state.queue.len) {
        if (state.repeat == .queue) {
            state.queue_idx = 0;
            try playQueueCurrent(gpa, arena, io, state);
            return;
        }
        if (state.pl) |p| {
            p.stop();
            state.now_track = null;
            state.status = "queue end";
        }
        return;
    }
    state.queue_idx += 1;
    try playQueueCurrent(gpa, arena, io, state);
}

fn handlePlayerEvent(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    io: std.Io,
    state: *State,
    ev: player.Event,
) !void {
    switch (ev) {
        .end_file => try queueAdvance(gpa, arena, io, state, true),
        .shutdown => state.now_track = null,
        else => {},
    }
}

const Range = struct { u21, u21 };

// combining marks, hangul jungseong/jongseong, joiners, variation selectors
const zero_ranges = [_]Range{
    .{ 0x300, 0x36f },   .{ 0x1160, 0x11ff }, .{ 0x1ab0, 0x1aff }, .{ 0x1dc0, 0x1dff },
    .{ 0x200b, 0x200f }, .{ 0x20d0, 0x20ff }, .{ 0xfe00, 0xfe0f }, .{ 0xfe20, 0xfe2f },
    .{ 0xfeff, 0xfeff },
};

// East Asian Wide + Fullwidth + emoji
const wide_ranges = [_]Range{
    .{ 0x1100, 0x115f },   .{ 0x2e80, 0x303e },   .{ 0x3041, 0x33ff },   .{ 0x3400, 0x4dbf },
    .{ 0x4e00, 0x9fff },   .{ 0xa000, 0xa4cf },   .{ 0xa960, 0xa97f },   .{ 0xac00, 0xd7a3 },
    .{ 0xf900, 0xfaff },   .{ 0xfe10, 0xfe19 },   .{ 0xfe30, 0xfe6f },   .{ 0xff00, 0xff60 },
    .{ 0xffe0, 0xffe6 },   .{ 0x1f300, 0x1f64f }, .{ 0x1f680, 0x1f6ff }, .{ 0x1f900, 0x1f9ff },
    .{ 0x20000, 0x3fffd },
};

fn inRanges(cp: u21, ranges: []const Range) bool {
    for (ranges) |r| if (cp >= r[0] and cp <= r[1]) return true;
    return false;
}

fn cpWidth(cp: u21) usize {
    if (cp < 0x20 or (cp >= 0x7f and cp < 0xa0)) return 0;
    if (cp < 0x300) return 1;
    if (inRanges(cp, &zero_ranges)) return 0;
    return if (inRanges(cp, &wide_ranges)) 2 else 1;
}

const Step = struct { cols: usize, len: usize };

fn stepCols(s: []const u8, i: usize) Step {
    const b = s[i];
    const len: usize = if (b < 0x80) 1 else if (b < 0xC0) 1 else if (b < 0xE0) 2 else if (b < 0xF0) 3 else 4;
    if (b < 0x80 or i + len > s.len) return .{ .cols = cpWidth(b), .len = 1 };
    const cp = std.unicode.utf8Decode(s[i .. i + len]) catch return .{ .cols = 1, .len = len };
    return .{ .cols = cpWidth(cp), .len = len };
}

fn skipEscape(s: []const u8, start: usize) usize {
    var i = start + 1;
    if (i < s.len and s[i] == '[') {
        i += 1;
        while (i < s.len) : (i += 1) {
            const cc = s[i];
            if (cc >= 0x40 and cc <= 0x7e) {
                i += 1;
                break;
            }
        }
    }
    return i;
}

fn visibleCols(s: []const u8) usize {
    var cols: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == 0x1b) {
            i = skipEscape(s, i);
            continue;
        }
        const st = stepCols(s, i);
        cols += st.cols;
        i += st.len;
    }
    return cols;
}

fn truncateCols(s: []const u8, max_cols: usize) []const u8 {
    if (max_cols == 0) return s[0..0];
    var cols: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == 0x1b) {
            i = skipEscape(s, i);
            continue;
        }
        const st = stepCols(s, i);
        if (cols + st.cols > max_cols) return s[0..i];
        cols += st.cols;
        i += st.len;
    }
    return s;
}

fn tailCols(s: []const u8, max_cols: usize) []const u8 {
    if (visibleCols(s) <= max_cols) return s;
    var i: usize = s.len;
    var cols: usize = 0;
    while (i > 0) {
        var start = i - 1;
        while (start > 0 and (s[start] & 0xC0) == 0x80) start -= 1;
        const st = stepCols(s, start);
        if (cols + st.cols > max_cols) break;
        cols += st.cols;
        i = start;
    }
    return s[i..];
}

fn termSize() struct { cols: usize, rows: usize } {
    var ws: posix.winsize = undefined;
    const req: c_int = @bitCast(@as(c_uint, @intCast(std.c.T.IOCGWINSZ)));
    if (std.c.ioctl(STDOUT, req, &ws) == 0 and ws.col > 0) {
        return .{
            .cols = @intCast(ws.col),
            .rows = if (ws.row > 0) @intCast(ws.row) else 24,
        };
    }
    return .{ .cols = 80, .rows = 24 };
}

fn draw(gpa: std.mem.Allocator, state: *State) !void {
    const sz = termSize();
    const need: usize = sz.cols * sz.rows * 32 + 4096;
    if (state.draw_buf.capacity < need) {
        try state.draw_buf.ensureTotalCapacity(gpa, need);
    }
    state.draw_buf.clearRetainingCapacity();
    var w: std.Io.Writer = .fixed(state.draw_buf.allocatedSlice());
    const width = sz.cols;
    const height = sz.rows;
    const inner: usize = if (width > 4) width - 2 else 1;

    const chrome_main: usize = 6;
    const footer_rows: usize = if (state.now_track != null) 6 else 0;
    const min_body: usize = 4;
    const body_rows: usize = if (height > chrome_main + footer_rows + min_body)
        height - chrome_main - footer_rows
    else
        min_body;

    const th = state.theme;
    try w.writeAll("\x1b[?2026h\x1b[H");

    const title = " ♫ ytcli ";
    try w.print("{s}╭─{s}{s}{s}", .{ th.accent, th.accent_strong, title, th.reset });
    try w.writeAll(th.accent);
    var i: usize = 0;
    const used = 2 + visibleCols(title);
    while (i + used < inner + 1) : (i += 1) try w.writeAll("─");
    try w.print("╮{s}\r\n", .{th.reset});

    try drawRow(&w, th, inner, state.status, .{ .dim = true });
    try drawSearchRow(&w, th, inner, state);

    var pl_buf: [MAX_PL_ROWS]usize = undefined;
    const pls = matchedPlaylists(state, &pl_buf);
    const section = switch (state.phase) {
        .typing => if (pls.len > 0 and state.suggestions.len > 0)
            "playlists · suggestions"
        else if (pls.len > 0)
            "playlists"
        else
            "suggestions",
        .results => if (state.view_pl) |vi| state.playlists[vi].name else "results",
        .picker => "add to playlist",
    };
    var sec_buf: [128]u8 = undefined;
    const sec_label = if (state.filter == .all or state.view_pl != null or state.phase == .picker)
        section
    else
        std.fmt.bufPrint(&sec_buf, "{s} [{s}]", .{ section, state.filter.label() }) catch section;

    try w.print("{s}├─ {s}{s}{s} ", .{ th.accent, th.bold, sec_label, th.reset });
    try w.writeAll(th.accent);
    const sec_used = 3 + visibleCols(sec_label) + 1;
    var fill: usize = 0;
    while (fill + sec_used < inner + 1) : (fill += 1) try w.writeAll("─");
    try w.print("┤{s}\r\n", .{th.reset});

    switch (state.phase) {
        .typing => try drawTyping(&w, th, inner, body_rows, state, pls),
        .results => try drawResults(&w, th, inner, body_rows, state),
        .picker => try drawPicker(&w, th, inner, body_rows, state),
    }

    try w.print("{s}╰", .{th.accent});
    var j: usize = 0;
    while (j < inner) : (j += 1) try w.writeAll("─");
    try w.print("╯{s}\r\n", .{th.reset});

    if (state.now_track != null) {
        try drawNowPlaying(&w, th, inner, state);
    }

    const hint = switch (state.phase) {
        .typing => if (pls.len > 0)
            "↑↓ pick · ⏎ open/search · ^X^X delete · esc clear · ^T filter · ^Y theme · ^A save playing · ^C quit"
        else
            "tab accept · ⏎ search · ^X^X forget · esc clear · ^T filter · ^Y theme · ^A save playing · ^C quit",
        .results => if (state.view_pl != null)
            "jk/↑↓ · ⏎/l play · P add · d/^X remove · h back · [/] seek · -/= vol · m mute · ^R repeat · ␣/^P pause"
        else
            "jk/↑↓ · gG · ⏎/l play · P save (no playback) · h back · [/] seek · -/= vol · m mute · ^R repeat · ␣/^P pause",
        .picker => "↑↓ pick · type to name a new playlist · ⏎ add · esc cancel",
    };
    try w.print("{s} {s}{s}\x1b[K", .{ th.dim, hint, th.reset });
    try w.writeAll("\x1b[J\x1b[?2026l");

    try writeAll(w.buffered());
}

const RowOpts = struct { dim: bool = false };

fn drawRow(w: *std.Io.Writer, th: theme_mod.Theme, inner: usize, text: []const u8, opts: RowOpts) !void {
    const t = truncateCols(text, inner -| 2);
    try w.print("{s}│{s} ", .{ th.accent, th.reset });
    if (opts.dim) try w.writeAll(th.dim);
    try w.writeAll(t);
    if (opts.dim) try w.writeAll(th.reset);
    const used = 1 + visibleCols(t);
    var pad = inner -| used;
    while (pad > 0) : (pad -= 1) try w.writeByte(' ');
    try w.print("{s}│{s}\r\n", .{ th.accent, th.reset });
}

fn drawSearchRow(w: *std.Io.Writer, th: theme_mod.Theme, inner: usize, state: *State) !void {
    try w.print("{s}│{s} {s}search ›{s} ", .{ th.accent, th.reset, th.accent_strong, th.reset });
    const prompt_cols: usize = 1 + visibleCols("search ›") + 1;
    const room = inner -| prompt_cols;
    const q = state.query.items;

    var ghost: []const u8 = "";
    if (state.phase == .typing and q.len > 0 and state.sel_row == null) {
        for (state.suggestions) |s| {
            if (s.len > q.len and std.ascii.startsWithIgnoreCase(s, q)) {
                ghost = s[q.len..];
                break;
            }
        }
    }

    const q_show = tailCols(q, room -| @as(usize, if (state.phase == .typing) 1 else 0));
    try w.writeAll(q_show);
    var used = visibleCols(q_show);

    if (used < room and state.phase == .typing) {
        try w.print("{s} {s}", .{ th.highlight, th.reset });
        used += 1;
    }

    const ghost_room = room -| used;
    const g_show = truncateCols(ghost, ghost_room);
    if (g_show.len > 0) {
        try w.print("{s}{s}{s}", .{ th.ghost, g_show, th.reset });
        used += visibleCols(g_show);
    }

    var pad = room -| used;
    while (pad > 0) : (pad -= 1) try w.writeByte(' ');
    try w.print("{s}│{s}\r\n", .{ th.accent, th.reset });
}

fn clampScroll(scroll: *usize, sel: usize, n: usize, rows: usize) void {
    if (rows == 0 or n == 0) {
        scroll.* = 0;
        return;
    }
    if (sel < scroll.*) scroll.* = sel;
    if (sel >= scroll.* + rows) scroll.* = sel - rows + 1;
    if (scroll.* + rows > n) {
        scroll.* = if (n > rows) n - rows else 0;
    }
}

fn drawTyping(w: *std.Io.Writer, th: theme_mod.Theme, inner: usize, rows: usize, state: *State, pls: []const usize) !void {
    const total = pls.len + state.suggestions.len;
    if (total == 0) {
        try drawRow(w, th, inner, "  (no suggestions yet — keep typing)", .{ .dim = true });
        var k: usize = 1;
        while (k < rows) : (k += 1) try drawRow(w, th, inner, "", .{});
        return;
    }
    clampScroll(&state.scroll_row, state.sel_row orelse 0, total, rows);
    const start = state.scroll_row;
    const end = @min(start + rows, total);
    var idx = start;
    while (idx < end) : (idx += 1) {
        const selected = if (state.sel_row) |sl| sl == idx else false;
        if (idx < pls.len) {
            const e = state.playlists[pls[idx]];
            var tag_buf: [24]u8 = undefined;
            const tag = std.fmt.bufPrint(&tag_buf, " [{d}]", .{e.tracks.len}) catch "";
            try drawListRow(w, th, inner, e.name, tag, selected);
        } else {
            try drawListRow(w, th, inner, state.suggestions[idx - pls.len], "", selected);
        }
    }
    var rem = rows - (end - start);
    while (rem > 0) : (rem -= 1) try drawRow(w, th, inner, "", .{});
}

fn drawListRow(w: *std.Io.Writer, th: theme_mod.Theme, inner: usize, label: []const u8, tag: []const u8, selected: bool) !void {
    try w.print("{s}│{s} ", .{ th.accent, th.reset });
    const room = inner -| 1;
    const tag_cols = visibleCols(tag);
    const text = truncateCols(label, room -| 2 -| tag_cols);

    if (selected) try w.writeAll(th.highlight);
    try w.writeAll(if (selected) "▸ " else "  ");
    try w.writeAll(text);
    if (selected) try w.writeAll(th.reset);

    var pad = room -| (2 + visibleCols(text) + tag_cols);
    while (pad > 0) : (pad -= 1) try w.writeByte(' ');
    try w.print("{s}{s}{s}", .{ th.dim, tag, th.reset });
    try w.print("{s}│{s}\r\n", .{ th.accent, th.reset });
}

fn drawPicker(w: *std.Io.Writer, th: theme_mod.Theme, inner: usize, rows: usize, state: *State) !void {
    var drawn: usize = 0;
    if (state.picker_track) |t| {
        var buf: [256]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "  saving: {s} — {s}", .{ t.title, t.artist }) catch "  saving…";
        try drawRow(w, th, inner, line, .{ .dim = true });
        try drawRow(w, th, inner, "", .{});
        drawn += 2;
    }
    for (state.playlists, 0..) |e, i| {
        if (drawn >= rows) break;
        var tag_buf: [24]u8 = undefined;
        const tag = std.fmt.bufPrint(&tag_buf, " [{d}]", .{e.tracks.len}) catch "";
        try drawListRow(w, th, inner, e.name, tag, i == state.picker_sel);
        drawn += 1;
    }
    if (drawn < rows) {
        var buf: [128]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "＋ new: {s}▌", .{state.picker_name.items}) catch "＋ new playlist";
        try drawListRow(w, th, inner, line, "", state.picker_sel >= state.playlists.len);
        drawn += 1;
    }
    while (drawn < rows) : (drawn += 1) try drawRow(w, th, inner, "", .{});
}

fn drawResults(w: *std.Io.Writer, th: theme_mod.Theme, inner: usize, rows: usize, state: *State) !void {
    if (state.tracks.len == 0) {
        var k: usize = 0;
        while (k < rows) : (k += 1) try drawRow(w, th, inner, "", .{});
        return;
    }
    clampScroll(&state.scroll_track, state.sel_track, state.tracks.len, rows);
    const start = state.scroll_track;
    const end = @min(start + rows, state.tracks.len);
    var idx = start;
    while (idx < end) : (idx += 1) {
        const t = state.tracks[idx];
        const selected = idx == state.sel_track;
        try w.print("{s}│{s} ", .{ th.accent, th.reset });
        const room = inner -| 1;
        const mark: []const u8 = if (selected) "▸ " else "  ";

        const head_cols: usize = 2;
        const remaining = room -| head_cols;
        const sep = "  — ";
        const sep_cols = visibleCols(sep);

        var kind_buf: [16]u8 = undefined;
        const kind_tag = std.fmt.bufPrint(&kind_buf, " [{s}]", .{kindShort(t.kind)}) catch "";
        const kind_cols = visibleCols(kind_tag);

        const text_room = remaining -| kind_cols;
        const title_budget = if (text_room > sep_cols + 4) (text_room * 2) / 3 else text_room;
        const title = truncateCols(t.title, title_budget);
        const title_used = visibleCols(title);
        const artist_room = text_room -| title_used -| sep_cols;
        const artist = truncateCols(t.artist, artist_room);
        const artist_used = visibleCols(artist);

        if (selected) try w.writeAll(th.highlight);
        try w.writeAll(mark);
        if (!selected) try w.writeAll(th.bold);
        try w.writeAll(title);
        if (!selected) try w.writeAll(th.reset);
        try w.writeAll(if (selected) th.highlight else th.dim);
        try w.writeAll(sep);
        try w.writeAll(artist);
        try w.writeAll(th.reset);

        const used = head_cols + title_used + sep_cols + artist_used;
        const left_pad = text_room -| (used - head_cols);
        var pad = left_pad;
        while (pad > 0) : (pad -= 1) try w.writeByte(' ');

        try w.print("{s}{s}{s}", .{ th.dim, kind_tag, th.reset });

        try w.print("{s}│{s}\r\n", .{ th.accent, th.reset });
    }
    var rem = rows - (end - start);
    while (rem > 0) : (rem -= 1) try drawRow(w, th, inner, "", .{});
}

fn kindShort(k: []const u8) []const u8 {
    if (std.mem.eql(u8, k, "Song")) return "song";
    if (std.mem.eql(u8, k, "Video")) return "video";
    if (std.mem.eql(u8, k, "Album")) return "album";
    if (std.mem.eql(u8, k, "Artist")) return "artist";
    if (std.mem.eql(u8, k, "Episode")) return "ep";
    if (std.mem.eql(u8, k, "Playlist")) return "list";
    return k;
}

const BAR_CHARS = [_][]const u8{ " ", "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█" };

fn drawNowPlaying(w: *std.Io.Writer, th: theme_mod.Theme, inner: usize, state: *State) !void {
    const t = state.now_track.?;
    const pl = state.pl orelse return;
    const connecting = state.connecting;
    const paused = pl.isPaused();

    const state_txt = if (connecting) "⟳ connecting…" else if (paused) "⏸ paused" else "▶ playing";
    const rep = switch (state.repeat) {
        .off => "",
        .track => " ↻track",
        .queue => " ↻queue",
    };
    var lbl_buf: [64]u8 = undefined;
    const label = std.fmt.bufPrint(&lbl_buf, " {s}{s} ", .{ state_txt, rep }) catch " ▶ ";
    try w.print("{s}╭─{s}{s}{s}", .{ th.accent, th.accent_strong, label, th.reset });
    try w.writeAll(th.accent);
    var i: usize = 0;
    const used = 2 + visibleCols(label);
    while (i + used < inner + 1) : (i += 1) try w.writeAll("─");
    try w.print("╮{s}\r\n", .{th.reset});

    {
        try w.print("{s}│{s} ", .{ th.accent, th.reset });
        const room = inner -| 1;
        const sep = "  — ";
        const sep_cols = visibleCols(sep);
        const title_budget = if (room > sep_cols + 4) (room * 2) / 3 else room;
        const title = truncateCols(t.title, title_budget);
        const tu = visibleCols(title);
        const artist = truncateCols(t.artist, room -| tu -| sep_cols);
        const au = visibleCols(artist);
        try w.print("{s}{s}{s}", .{ th.bold, title, th.reset });
        try w.print("{s}{s}{s}{s}", .{ th.dim, sep, artist, th.reset });
        var pad = room -| (tu + sep_cols + au);
        while (pad > 0) : (pad -= 1) try w.writeByte(' ');
        try w.print("{s}│{s}\r\n", .{ th.accent, th.reset });
    }

    {
        try w.print("{s}│{s} ", .{ th.accent, th.reset });
        const room = inner -| 1;
        const pos = pl.timePos() orelse 0;
        const dur = pl.duration() orelse 0;
        const frac: f64 = if (dur > 0) std.math.clamp(pos / dur, 0, 1) else 0;

        var time_buf: [128]u8 = undefined;
        const muted = pl.isMuted();
        const vol: u32 = @intFromFloat(pl.volume());
        const filled_vol: u32 = if (muted) 0 else vol / 10;
        var vol_buf: [64]u8 = undefined;
        var vw: std.Io.Writer = .fixed(&vol_buf);
        var vbi: u32 = 0;
        while (vbi < 10) : (vbi += 1) {
            try vw.writeAll(if (vbi < filled_vol) "▮" else "▯");
        }
        var pos_buf: [16]u8 = undefined;
        var dur_buf: [16]u8 = undefined;
        const time_str = if (muted)
            std.fmt.bufPrint(&time_buf, "  {s} / {s}  vol {s} mute", .{ fmtTime(&pos_buf, pos), fmtTime(&dur_buf, dur), vw.buffered() }) catch ""
        else
            std.fmt.bufPrint(&time_buf, "  {s} / {s}  vol {s} {d:0>3}", .{ fmtTime(&pos_buf, pos), fmtTime(&dur_buf, dur), vw.buffered(), vol }) catch "";
        const time_cols = visibleCols(time_str);

        const bar_room = room -| time_cols;
        const filled: usize = @intFromFloat(@as(f64, @floatFromInt(bar_room)) * frac);
        var k: usize = 0;
        try w.writeAll(th.accent_strong);
        while (k < filled) : (k += 1) try w.writeAll("▰");
        try w.writeAll(th.dim);
        while (k < bar_room) : (k += 1) try w.writeAll("▱");
        try w.writeAll(th.reset);
        try w.print("{s}{s}{s}", .{ th.dim, time_str, th.reset });
        try w.print("{s}│{s}\r\n", .{ th.accent, th.reset });
    }

    {
        try w.print("{s}│{s} ", .{ th.accent, th.reset });
        const room = inner -| 1;
        const idle = paused or connecting or pl.isMuted();
        const rms = if (idle) 0 else pl.rmsLevel();
        try drawBars(w, th, room, state.tick, idle, rms);
        try w.print("{s}│{s}\r\n", .{ th.accent, th.reset });
    }

    {
        try w.print("{s}│{s} ", .{ th.accent, th.reset });
        const room = inner -| 1;
        const prefix = "next ▸ ";
        const prefix_cols = visibleCols(prefix);
        try w.print("{s}{s}{s}", .{ th.dim, prefix, th.reset });

        var used_n = prefix_cols;
        const text_room = room -| used_n;
        if (state.queue.len > 0 and state.queue_idx + 1 < state.queue.len) {
            const nt = state.queue[state.queue_idx + 1];
            const sep = " — ";
            const sep_cols = visibleCols(sep);
            const title_budget = if (text_room > sep_cols + 4) (text_room * 2) / 3 else text_room;
            const title = truncateCols(nt.title, title_budget);
            const tu = visibleCols(title);
            const artist = truncateCols(nt.artist, text_room -| tu -| sep_cols);
            const au = visibleCols(artist);
            try w.writeAll(title);
            try w.print("{s}{s}{s}{s}", .{ th.dim, sep, artist, th.reset });
            used_n += tu + sep_cols + au;
        } else {
            const msg = "queue end · esc back to search for more";
            const shown = truncateCols(msg, text_room);
            try w.print("{s}{s}{s}", .{ th.dim, shown, th.reset });
            used_n += visibleCols(shown);
        }
        var pad = room -| used_n;
        while (pad > 0) : (pad -= 1) try w.writeByte(' ');
        try w.print("{s}│{s}\r\n", .{ th.accent, th.reset });
    }

    try w.print("{s}╰", .{th.accent});
    var b: usize = 0;
    while (b < inner) : (b += 1) try w.writeAll("─");
    try w.print("╯{s}\r\n", .{th.reset});
}

fn drawBars(w: *std.Io.Writer, th: theme_mod.Theme, room: usize, tick: u64, paused: bool, rms: f64) !void {
    const bars = @min(room, VIS_BARS);
    const tf: f64 = @floatFromInt(tick);

    var env = std.math.clamp(rms * 2.6, 0, 1);
    if (paused) env = 0;
    if (!paused and env < 0.08) env = 0.08;

    var i: usize = 0;
    while (i < bars) : (i += 1) {
        const fi: f64 = @floatFromInt(i);
        const m1 = @sin(tf * 0.22 + fi * 0.42);
        const m2 = @sin(tf * 0.11 + fi * 0.19 + 1.9);
        const mod = (m1 + m2) * 0.25 + 0.75;
        const height = std.math.clamp(env * mod, 0, 1);
        const lvl_f = height * 8.0;
        const lvl: usize = @intFromFloat(@max(0, @min(7, lvl_f)));

        const color = if (lvl >= 7) th.accent_strong else if (lvl >= 4) th.accent else th.dim;
        try w.writeAll(color);
        try w.writeAll(BAR_CHARS[lvl]);
    }
    try w.writeAll(th.reset);
    var pad = room -| bars;
    while (pad > 0) : (pad -= 1) try w.writeByte(' ');
}

fn fmtTime(buf: []u8, secs: f64) []const u8 {
    const total: u32 = @intFromFloat(@max(0, secs));
    const h = total / 3600;
    const m = (total % 3600) / 60;
    const s = total % 60;
    if (h > 0) return std.fmt.bufPrint(buf, "{d}:{d:0>2}:{d:0>2}", .{ h, m, s }) catch "0:00:00";
    return std.fmt.bufPrint(buf, "{d:0>2}:{d:0>2}", .{ m, s }) catch "00:00";
}

var saved_termios: ?posix.termios = null;

fn onInterrupt(_: posix.SIG) callconv(.c) void {
    const restore = "\x1b[?25h\x1b[?1049l";
    _ = c.write(STDOUT, restore, restore.len);
    if (saved_termios) |t| posix.tcsetattr(STDIN, .NOW, t) catch {};
    c._exit(130);
}

fn installInterruptHandlers() void {
    const act = posix.Sigaction{
        .handler = .{ .handler = onInterrupt },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.INT, &act, null);
    posix.sigaction(posix.SIG.TERM, &act, null);
}

fn enterRaw() !posix.termios {
    const orig = try posix.tcgetattr(STDIN);
    var raw = orig;
    raw.lflag.ICANON = false;
    raw.lflag.ECHO = false;
    raw.lflag.IEXTEN = false;
    raw.iflag.IXON = false;
    raw.iflag.ICRNL = false;
    raw.cc[@intFromEnum(posix.V.MIN)] = 1;
    raw.cc[@intFromEnum(posix.V.TIME)] = 0;
    try posix.tcsetattr(STDIN, .NOW, raw);
    return orig;
}

fn restoreTty(orig: posix.termios) void {
    posix.tcsetattr(STDIN, .NOW, orig) catch {};
}

fn writeAll(bytes: []const u8) !void {
    var i: usize = 0;
    while (i < bytes.len) {
        const n = c.write(STDOUT, bytes[i..].ptr, bytes.len - i);
        if (n <= 0) return error.WriteFailed;
        i += @intCast(n);
    }
}

const testing = std.testing;

test "visibleCols counts glyphs, skipping ANSI escapes and UTF-8 continuation" {
    try testing.expectEqual(@as(usize, 3), visibleCols("abc"));
    try testing.expectEqual(@as(usize, 2), visibleCols("\x1b[31mab\x1b[0m"));
    try testing.expectEqual(@as(usize, 1), visibleCols("♫"));
    try testing.expectEqual(@as(usize, 4), visibleCols("a♫b♫"));
}

test "truncateCols cuts on column boundaries, not bytes" {
    try testing.expectEqualStrings("abc", truncateCols("abcdef", 3));
    try testing.expectEqualStrings("abcdef", truncateCols("abcdef", 99));
    try testing.expectEqualStrings("", truncateCols("abc", 0));
    try testing.expectEqualStrings("a♫", truncateCols("a♫b", 2));
}

test "visibleCols counts CJK and fullwidth as two columns" {
    try testing.expectEqual(@as(usize, 2), visibleCols("唄"));
    try testing.expectEqual(@as(usize, 8), visibleCols("うっせぇわ"[0 .. 4 * 3]));
    try testing.expectEqual(@as(usize, 5), visibleCols("a漢字"));
    try testing.expectEqual(@as(usize, 4), visibleCols("ＡＢ"));
    try testing.expectEqual(@as(usize, 2), visibleCols("\x1b[31m唄\x1b[0m"));
    try testing.expectEqual(@as(usize, 1), visibleCols("é"));
    try testing.expectEqual(@as(usize, 1), visibleCols("e\u{301}"));
}

test "truncateCols never splits a wide char" {
    try testing.expectEqualStrings("漢", truncateCols("漢字", 3));
    try testing.expectEqualStrings("漢字", truncateCols("漢字", 4));
    try testing.expectEqualStrings("", truncateCols("漢字", 1));
    try testing.expectEqualStrings("a", truncateCols("a漢", 2));
}

test "tailCols keeps the last columns on wide-char boundaries" {
    try testing.expectEqualStrings("def", tailCols("abcdef", 3));
    try testing.expectEqualStrings("abc", tailCols("abc", 9));
    try testing.expectEqualStrings("字", tailCols("漢字", 3));
    try testing.expectEqualStrings("漢字", tailCols("漢字", 4));
}

test "drawRow keeps borders aligned for CJK text" {
    var buf: [512]u8 = undefined;
    for ([_][]const u8{ "ado", "うっせぇわ", "唱 / Ado", "a漢b", "🎵 mix" }) |text| {
        var w: std.Io.Writer = .fixed(&buf);
        try drawRow(&w, theme_mod.default, 40, text, .{});
        const line = std.mem.trimEnd(u8, w.buffered(), "\r\n");
        try testing.expectEqual(@as(usize, 42), visibleCols(line));
    }
}

test "drawResults keeps every row one terminal line wide" {
    var tracks = [_]api.Track{
        .{ .title = "うっせぇわ", .artist = "Ado", .video_id = "x", .kind = "Song" },
        .{ .title = "Ado - 唱 / THE FIRST TAKE", .artist = "THE FIRST TAKE", .video_id = "y", .kind = "Video" },
        .{ .title = "私は最強", .artist = "ウタ（Ado）", .video_id = "z", .kind = "Playlist" },
    };
    var st: State = .{ .phase = .results, .tracks = &tracks, .sel_track = 1 };
    var buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const inner: usize = 60;
    try drawResults(&w, theme_mod.default, inner, tracks.len, &st);
    var it = std.mem.tokenizeAny(u8, w.buffered(), "\r\n");
    while (it.next()) |line| try testing.expectEqual(inner + 2, visibleCols(line));
}

test "typing rows put playlists before suggestions and filter by query" {
    var lists = [_]playlist.Entry{ .{ .name = "night drive" }, .{ .name = "nova" } };
    var sugs = [_][]const u8{ "nina simone", "ado" };
    var st: State = .{ .playlists = &lists, .suggestions = &sugs };
    defer st.query.deinit(testing.allocator);
    var buf: [MAX_PL_ROWS]usize = undefined;

    try testing.expectEqual(@as(usize, 2), matchedPlaylists(&st, &buf).len);
    try testing.expect(selectedSuggestion(&st) == null); // no selection
    st.sel_row = 1;
    try testing.expect(selectedSuggestion(&st) == null); // still a playlist row
    st.sel_row = 2;
    try testing.expectEqualStrings("nina simone", selectedSuggestion(&st).?);

    try st.query.appendSlice(testing.allocator, "no");
    const filtered = matchedPlaylists(&st, &buf);
    try testing.expectEqual(@as(usize, 1), filtered.len);
    try testing.expectEqualStrings("nova", st.playlists[filtered[0]].name);
    st.sel_row = 1;
    try testing.expectEqualStrings("nina simone", selectedSuggestion(&st).?);
}

test "playlist and picker rows stay inside the frame" {
    var tracks = [_]api.Track{
        .{ .video_id = "a", .title = "うっせぇわ", .artist = "Ado", .kind = "Song" },
    };
    var lists = [_]playlist.Entry{
        .{ .name = "night drive", .tracks = &tracks },
        .{ .name = "深夜のドライブ", .tracks = &tracks },
    };
    var st: State = .{ .playlists = &lists, .sel_row = 1, .picker_track = tracks[0] };
    st.suggestions = @constCast(&[_][]const u8{ "ado", "hong ting" });
    const inner: usize = 44;
    var buf: [8192]u8 = undefined;

    var w: std.Io.Writer = .fixed(&buf);
    try drawTyping(&w, theme_mod.default, inner, 5, &st, &[_]usize{ 0, 1 });
    var it = std.mem.tokenizeAny(u8, w.buffered(), "\r\n");
    var rows: usize = 0;
    while (it.next()) |line| : (rows += 1) try testing.expectEqual(inner + 2, visibleCols(line));
    try testing.expectEqual(@as(usize, 5), rows);

    var w2: std.Io.Writer = .fixed(&buf);
    try drawPicker(&w2, theme_mod.default, inner, 6, &st);
    var it2 = std.mem.tokenizeAny(u8, w2.buffered(), "\r\n");
    rows = 0;
    while (it2.next()) |line| : (rows += 1) try testing.expectEqual(inner + 2, visibleCols(line));
    try testing.expectEqual(@as(usize, 6), rows);
}

test "fmtTime formats mm:ss and clamps negatives" {
    var buf: [16]u8 = undefined;
    try testing.expectEqualStrings("00:05", fmtTime(&buf, 5));
    try testing.expectEqualStrings("01:05", fmtTime(&buf, 65));
    try testing.expectEqualStrings("10:00", fmtTime(&buf, 600));
    try testing.expectEqualStrings("00:00", fmtTime(&buf, -3));
    try testing.expectEqualStrings("1:15:00", fmtTime(&buf, 4500));
    try testing.expectEqualStrings("1:00:05", fmtTime(&buf, 3605));
}

test "clampScroll keeps selection within the viewport" {
    var s: usize = 0;
    clampScroll(&s, 12, 50, 10);
    try testing.expectEqual(@as(usize, 3), s);
    clampScroll(&s, 1, 50, 10);
    try testing.expectEqual(@as(usize, 1), s);
    var z: usize = 5;
    clampScroll(&z, 0, 0, 10);
    try testing.expectEqual(@as(usize, 0), z);
}

test "kindShort maps known kinds and passes through unknown" {
    try testing.expectEqualStrings("song", kindShort("Song"));
    try testing.expectEqualStrings("ep", kindShort("Episode"));
    try testing.expectEqualStrings("Mixtape", kindShort("Mixtape"));
}
