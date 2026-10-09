const std = @import("std");
const posix = std.posix;

const fsutil = @import("fsutil.zig");
const c = fsutil.c;

const api = @import("api.zig");
const stream = @import("stream.zig");
const player = @import("player.zig");
const suggest = @import("suggest.zig");
const history = @import("history.zig");
const playlist = @import("playlist.zig");
const track_mod = @import("track.zig");
const library = @import("library.zig");
const feed = @import("feed.zig");
const theme_mod = @import("theme.zig");
const text_mod = @import("text.zig");
const config = @import("config.zig");
const log = @import("log.zig");
const vis = @import("vis.zig");
const VERSION = @import("build_options").version;

const STDIN: posix.fd_t = 0;
const STDOUT: posix.fd_t = 1;

const SUGGEST_DEBOUNCE_MS: i32 = 250;
const MAX_SUGGESTIONS: usize = 24;
const MAX_LOCAL_HITS: usize = 12;
const MAX_LIB_NAMES: usize = 8;
const MAX_RESULTS: usize = 50;
const VIS_BARS: usize = 28;
const TICK_MS_PLAYING: i32 = 100;
const TICK_MS_IDLE: i32 = 250;
const TICK_MS_VIS: i32 = vis.TICK_MS;
const MAX_FLIPBOOKS = 32;
const QUEUE_PANEL_COLS = 30;
const MOUSE_ON = "\x1b[?1000h\x1b[?1006h";
const MOUSE_OFF = "\x1b[?1006l\x1b[?1000l";
const WHEEL_ROWS = 2;
const SEEK_SHORT_S: f64 = 10;
const SEEK_LONG_S: f64 = 60;
const VOLUME_STEP: f64 = 5;
const PASTE_ON = "\x1b[?2004h";
const PASTE_OFF = "\x1b[?2004l";
const MAX_PASTE = 4096;
const MAX_MODE_HITS = 12;
var shuffle_salt: u64 = 0;
const SPLASH_MS: i32 = 1600;

const TYPING_STATUS = "type to search · ↑/↓ pick · ⏎ go · ^L library · ^Q queue · ^C quit";

const Phase = enum { typing, results, picker, queue };
const Repeat = enum { off, track, queue };

const Scope = enum {
    both,
    youtube,
    library,

    fn label(self: Scope) []const u8 {
        return switch (self) {
            .both => "both",
            .youtube => "youtube",
            .library => "library",
        };
    }

    fn byName(name: []const u8) Scope {
        if (std.mem.eql(u8, name, "youtube")) return .youtube;
        if (std.mem.eql(u8, name, "library")) return .library;
        return .both;
    }

    fn next(self: Scope) Scope {
        return switch (self) {
            .both => .youtube,
            .youtube => .library,
            .library => .both,
        };
    }

    fn wantsYoutube(self: Scope) bool {
        return self != .library;
    }

    fn wantsLibrary(self: Scope) bool {
        return self != .youtube;
    }
};

const State = struct {
    phase: Phase = .typing,
    query: std.ArrayList(u8) = .empty,
    suggestions: [][]const u8 = &.{},
    sel_row: ?usize = null,
    scroll_row: usize = 0,
    last_fetched_buf: [512]u8 = undefined,
    last_fetched_len: usize = 0,
    filter: api.Filter = .all,
    scope: Scope = .both,

    tracks: []api.Track = &.{},
    sel_track: usize = 0,
    scroll_track: usize = 0,

    lib_entries: []library.Entry = &.{},
    lib_ready: bool = false,
    lib_cache_path: []const u8 = "",
    music_dir: []const u8 = "",
    lib_artist: []const u8 = "",
    lib_album: []const u8 = "",
    in_library: bool = false,
    in_feeds: bool = false,
    feeds_path: []const u8 = "",
    feed_title: []const u8 = "",
    scanning: bool = false,
    scan_count: usize = 0,
    local_hits: []api.Track = &.{},
    env: ?*std.process.Environ.Map = null,

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
    queue_sel: usize = 0,
    queue_scroll: usize = 0,
    queue_from: Phase = .typing,
    now_track: ?api.Track = null,
    connecting: bool = false,
    ytdlp_age: ?u32 = null,
    ytdlp_checked: bool = false,
    volume: f64 = 100,
    repeat: Repeat = .off,

    tick: u64 = 0,
    mouse: bool = true,
    body_top: usize = 0,
    body_rows: usize = 0,
    np_top: usize = 0,
    np_bar_cols: usize = 0,
    mode_row: ?usize = null,
    mode_hits: [MAX_MODE_HITS]ModeHit = undefined,
    mode_hit_len: usize = 0,
    vis_rect: Rect = .{},
    panel_rect: Rect = .{},
    panel_top: ?usize = null,
    drag_from: ?usize = null,
    vis_view: bool = false,
    vis_idx: usize = 0,
    vis_motion: vis.Motion = .{},
    vis_bufs: vis.Buffers = .{},
    vis_audio: vis.Audio = .{},
    vis_audio_tick: u64 = 0,
    flipbooks: []const vis.Flipbook = &.{},
    vis_arena: std.heap.ArenaAllocator = undefined,

    search_arena: std.heap.ArenaAllocator = undefined,

    sug_arena: std.heap.ArenaAllocator = undefined,

    play_arena: std.heap.ArenaAllocator = undefined,

    hist_arena: std.heap.ArenaAllocator = undefined,

    lib_arena: std.heap.ArenaAllocator = undefined,

    idx_arena: std.heap.ArenaAllocator = undefined,

    hit_arena: std.heap.ArenaAllocator = undefined,

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

    {
        const sz = termSize();
        log.write("start: term {d}x{d} rows/cols", .{ sz.rows, sz.cols });
    }
    var state: State = .{ .theme = theme, .theme_idx = theme_idx };
    const splash_off = blk: {
        const p = config.path(arena, env) catch break :blk false;
        const v = config.loadKey(arena, p, .splash) orelse break :blk false;
        break :blk std.mem.eql(u8, v, "off");
    };
    if (!splash_off) showSplash(theme) catch {};
    state.search_arena = std.heap.ArenaAllocator.init(gpa);
    state.sug_arena = std.heap.ArenaAllocator.init(gpa);
    state.play_arena = std.heap.ArenaAllocator.init(gpa);
    state.hist_arena = std.heap.ArenaAllocator.init(gpa);
    state.lib_arena = std.heap.ArenaAllocator.init(gpa);
    state.idx_arena = std.heap.ArenaAllocator.init(gpa);
    state.hit_arena = std.heap.ArenaAllocator.init(gpa);
    state.env = env;
    state.lib_cache_path = library.cachePath(arena, env) catch "";
    state.feeds_path = feed.path(arena, env) catch "";
    state.hist_path = history.path(arena, env) catch "";
    state.pl_path = playlist.path(arena, env) catch "";
    reloadPlaylists(&state);
    state.config_path = config.path(arena, env) catch "";
    if (state.config_path.len > 0) {
        if (config.loadKey(arena, state.config_path, .volume)) |v| {
            state.volume = std.math.clamp(std.fmt.parseFloat(f64, v) catch 100, 0, 100);
        }
        state.music_dir = config.loadKey(arena, state.config_path, .music_dir) orelse "";
        if (config.loadKey(arena, state.config_path, .scope)) |sc| state.scope = Scope.byName(sc);
    }
    if (state.config_path.len > 0) {
        if (config.loadKey(arena, state.config_path, .mouse)) |m| state.mouse = !std.mem.eql(u8, m, "off");
    }
    if (state.mouse) writeAll(MOUSE_ON) catch {};
    defer if (state.mouse) writeAll(MOUSE_OFF) catch {};
    writeAll(PASTE_ON) catch {};
    defer writeAll(PASTE_OFF) catch {};
    state.vis_arena = std.heap.ArenaAllocator.init(gpa);
    state.flipbooks = loadFlipbooks(state.vis_arena.allocator(), io, state.config_path);
    if (state.config_path.len > 0) {
        if (config.loadKey(arena, state.config_path, .visualizer)) |v| state.vis_idx = vis.indexOf(v, state.flipbooks) orelse 0;
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
        state.idx_arena.deinit();
        state.hit_arena.deinit();
        state.search_arena.deinit();
        state.sug_arena.deinit();
        state.play_arena.deinit();
        state.hist_arena.deinit();
        state.vis_bufs.deinit(gpa);
        state.vis_arena.deinit();
        if (state.pl) |p| {
            p.deinit();
            gpa.destroy(p);
        }
    }

    while (true) {
        draw(gpa, &state) catch |err| survive(&state, "draw", err);

        const playing = state.pl != null and (state.pl.?.has_track);
        const timeout: i32 = if (playing and state.vis_view) TICK_MS_VIS else if (playing) TICK_MS_PLAYING else TICK_MS_IDLE;

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
            if (state.phase == .typing and !std.mem.eql(u8, state.query.items, lastFetched(&state))) {
                refreshSuggestions(gpa, io, &state) catch |err| survive(&state, "suggest", err);
            }
        }
    }
}

fn showSplash(th: theme_mod.Theme) !void {
    const art = [_][]const u8{
        "██╗  ██╗██╗   ██╗███╗   ███╗",
        "██║  ██║██║   ██║████╗ ████║",
        "███████║██║   ██║██╔████╔██║",
        "██╔══██║██║   ██║██║╚██╔╝██║",
        "██║  ██║╚██████╔╝██║ ╚═╝ ██║",
        "╚═╝  ╚═╝ ╚═════╝ ╚═╝     ╚═╝",
    };
    const art_cols: usize = 28;
    const sz = termSize();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.heap.page_allocator);
    const a = std.heap.page_allocator;

    try buf.appendSlice(a, "\x1b[2J\x1b[H");

    if (sz.cols < art_cols + 4 or sz.rows < 12) {
        try buf.print(a, "\r\n  {s}♫ hum{s} — terminal media player\r\n", .{ th.accent_strong, th.reset });
        try buf.print(a, "  {s}v{s}{s}\r\n", .{ th.dim, VERSION, th.reset });
    } else {
        const pad = (sz.cols -| art_cols) / 2;
        var blank: usize = (sz.rows -| (art.len + 4)) / 2;
        while (blank > 0) : (blank -= 1) try buf.appendSlice(a, "\r\n");

        for (art) |line| {
            var i: usize = 0;
            while (i < pad) : (i += 1) try buf.append(a, ' ');
            try buf.print(a, "{s}{s}{s}\r\n", .{ th.accent_strong, line, th.reset });
        }
        const tag = "terminal media player";
        const tag_pad = (sz.cols -| visibleCols(tag)) / 2;
        var j: usize = 0;
        while (j < tag_pad) : (j += 1) try buf.append(a, ' ');
        try buf.print(a, "{s}{s}{s}\r\n\r\n", .{ th.dim, tag, th.reset });

        var vbuf: [32]u8 = undefined;
        const ver = std.fmt.bufPrint(&vbuf, "v{s} · press any key", .{VERSION}) catch "";
        const ver_pad = (sz.cols -| visibleCols(ver)) / 2;
        var k: usize = 0;
        while (k < ver_pad) : (k += 1) try buf.append(a, ' ');
        try buf.print(a, "{s}{s}{s}\r\n", .{ th.dim, ver, th.reset });
    }
    try writeAll(buf.items);

    if (waitInput(SPLASH_MS) catch false) {
        var key_buf: [8]u8 = undefined;
        _ = readKey(&key_buf) catch {};
    }
    try writeAll("\x1b[2J\x1b[H");
}

fn survive(state: *State, what: []const u8, err: anyerror) void {
    log.write("{s} failed: {s} phase={s}", .{ what, @errorName(err), @tagName(state.phase) });
    if (err == error.MpvMissing) return setStatus(state, "libmpv not found: install mpv", .{});
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
    mouse: Mouse,
    paste: []const u8,
    unknown,
};

const Mouse = struct { button: u16, x: u16, y: u16, press: bool };

const Rect = struct {
    x: usize = 0,
    y: usize = 0,
    w: usize = 0,
    h: usize = 0,

    fn contains(r: Rect, col: usize, row: usize) bool {
        return col >= r.x and col < r.x + r.w and row >= r.y and row < r.y + r.h;
    }
};

const ModeHit = struct {
    x: usize,
    w: usize,
    target: union(enum) { scope: Scope, filter: api.Filter },
};

var paste_buf: [MAX_PASTE]u8 = undefined;

fn readPaste() !Key {
    const end = "\x1b[201~";
    var n: usize = 0;
    var matched: usize = 0;
    while (true) {
        if (!(try waitInput(200))) break;
        var one: [1]u8 = undefined;
        if ((try posix.read(STDIN, &one)) == 0) break;
        if (one[0] == end[matched]) {
            matched += 1;
            if (matched == end.len) break;
            continue;
        }
        for (end[0..matched]) |b| {
            if (n < paste_buf.len) paste_buf[n] = b;
            n += 1;
        }
        matched = if (one[0] == end[0]) 1 else 0;
        if (matched == 0) {
            if (n < paste_buf.len) paste_buf[n] = one[0];
            n += 1;
        }
    }
    return Key{ .paste = paste_buf[0..@min(n, paste_buf.len)] };
}

fn readMouse() !Key {
    var buf: [24]u8 = undefined;
    var n: usize = 0;
    while (n < buf.len) {
        if (!(try waitInput(20))) return .unknown;
        var one: [1]u8 = undefined;
        if ((try posix.read(STDIN, &one)) == 0) return .unknown;
        if (one[0] == 'M' or one[0] == 'm') {
            var it = std.mem.splitScalar(u8, buf[0..n], ';');
            const b = std.fmt.parseInt(u16, it.next() orelse return .unknown, 10) catch return .unknown;
            const x = std.fmt.parseInt(u16, it.next() orelse return .unknown, 10) catch return .unknown;
            const y = std.fmt.parseInt(u16, it.next() orelse return .unknown, 10) catch return .unknown;
            return Key{ .mouse = .{ .button = b, .x = x, .y = y, .press = one[0] == 'M' } };
        }
        buf[n] = one[0];
        n += 1;
    }
    return .unknown;
}

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
    if (c2[0] == '<') return readMouse();
    if (c2[0] == '2') {
        var tail: [3]u8 = undefined;
        for (&tail, 0..) |*b, i| {
            if (!(try waitInput(20))) return .unknown;
            if ((try posix.read(STDIN, b[0..1])) == 0) return .unknown;
            if (b.* == '~' and i < 2) return .unknown;
        }
        return if (std.mem.eql(u8, &tail, "00~")) readPaste() else .unknown;
    }
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
            0x10 => {
                if (state.pl) |p| _ = p.togglePause();
                return true;
            },
            0x0e => {
                try queueAdvance(gpa, arena, io, state, false);
                return true;
            },
            0x13 => {
                if (state.pl) |p| {
                    p.stop();
                    state.now_track = null;
                }
                return true;
            },
            0x01 => {
                if (state.now_track) |t| openPicker(state, t) else state.status = "nothing playing to save";
                return true;
            },
            0x12 => {
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
            0x05 => {
                setScope(arena, state, state.scope.next());
                return true;
            },
            0x16 => {
                if (state.vis_view) {
                    state.vis_view = false;
                } else if (state.now_track != null) {
                    state.vis_view = true;
                } else state.status = "nothing playing to visualize";
                return true;
            },
            0x19 => {
                state.theme_idx = (state.theme_idx + 1) % theme_mod.all.len;
                state.theme = theme_mod.all[state.theme_idx].theme;
                state.status = theme_mod.all[state.theme_idx].name;
                saveSetting(arena, state, .theme, theme_mod.all[state.theme_idx].name);
                return true;
            },
            else => {},
        },
        else => {},
    }

    if (key == .mouse) return handleMouse(gpa, arena, io, state, key.mouse);
    if (key == .paste) {
        if (state.vis_view or (state.phase != .typing and state.phase != .picker)) return true;
        var fba_buf: [MAX_PASTE * 2]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&fba_buf);
        const clean = std.mem.trim(u8, text_mod.sanitize(fba.allocator(), key.paste) catch return true, " ");
        if (clean.len == 0) return true;
        return dispatchPhase(gpa, arena, io, state, .{ .text = clean });
    }
    if (state.vis_view and state.now_track != null) return handleVis(arena, state, key);

    return switch (state.phase) {
        .typing => try handleTyping(gpa, arena, io, state, key),
        .results => try handleResults(gpa, arena, io, state, key),
        .picker => try handlePicker(gpa, state, key),
        .queue => try handleQueue(gpa, arena, io, state, key),
    };
}

fn handleTyping(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    io: std.Io,
    state: *State,
    key: Key,
) !bool {
    var pl_buf: [MAX_PL_ROWS]usize = undefined;
    const pls = matchedPlaylists(state, &pl_buf);
    const total = pls.len + state.local_hits.len + state.suggestions.len;
    const on_playlist = if (state.sel_row) |r| r < pls.len else false;
    if (key != .ctrl) state.pl_del_pending = false;
    switch (key) {
        .ctrl_c => return false,
        .ctrl => |b| switch (b) {
            0x18 => if (state.sel_row) |row| {
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
            0x0C => try openLibrary(gpa, io, state, false),
            0x06 => try openFeeds(gpa, io, state),
            0x11 => openQueue(state),
            0x14 => setFilter(state, switch (state.filter) {
                .all => .songs,
                .songs => if (state.scope == .library) .albums else .videos,
                .videos => .albums,
                .albums => .artists,
                .artists => .all,
            }),
            else => {},
        },
        .escape => {
            state.query.clearRetainingCapacity();
            state.sel_row = null;
            state.last_fetched_len = 0;
            refreshLocalHits(state);
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
        .enter => if (on_playlist)
            openPlaylist(state, pls[state.sel_row.?])
        else if (selectedLocalHit(state)) |hit|
            try playLocalHit(gpa, arena, io, state, hit)
        else
            try runSearch(gpa, io, state),
        .backspace => if (state.query.items.len > 0) {
            popCodepoint(&state.query);
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
        .escape => if (state.in_library) try libraryBack(state) else if (state.in_feeds) try feedsBack(gpa, io, state) else backToTyping(state),
        .up => if (state.sel_track > 0) {
            state.sel_track -= 1;
        },
        .down => if (state.sel_track + 1 < n) {
            state.sel_track += 1;
        },
        .left => if (state.in_library) try libraryBack(state) else if (state.in_feeds) try feedsBack(gpa, io, state) else backToTyping(state),
        .right => try activateSelected(gpa, arena, io, state),
        .page_down => state.sel_track = @min(state.sel_track + 10, max_idx),
        .page_up => state.sel_track = if (state.sel_track > 10) state.sel_track - 10 else 0,
        .home => state.sel_track = 0,
        .end => state.sel_track = max_idx,
        .enter => try activateSelected(gpa, arena, io, state),
        .ctrl => |b| switch (b) {
            0x06 => state.sel_track = @min(state.sel_track + 10, max_idx),
            0x02 => state.sel_track = if (state.sel_track > 10) state.sel_track - 10 else 0,
            0x0C => try openLibrary(gpa, io, state, state.in_library),
            0x11 => openQueue(state),
            0x18 => if (state.view_pl != null) removeFromPlaylist(gpa, state),
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
                    'h' => if (state.in_library) try libraryBack(state) else if (state.in_feeds) try feedsBack(gpa, io, state) else backToTyping(state),
                    'P' => openPicker(state, if (state.tracks.len > 0) state.tracks[state.sel_track] else null),
                    's' => queueShuffle(state),
                    'a' => try queueAdd(state, false),
                    'A' => try queueAdd(state, true),
                    'd' => if (state.view_pl != null) removeFromPlaylist(gpa, state),
                    'l' => try activateSelected(gpa, arena, io, state),
                    'g' => state.sel_track = 0,
                    'G' => state.sel_track = max_idx,
                    else => _ = mediaKey(arena, state, t[0]),
                }
            }
        },
        else => {},
    }
    return true;
}

fn backToTyping(state: *State) void {
    state.phase = .typing;
    state.in_library = false;
    state.in_feeds = false;
    state.feed_title = "";
    state.lib_artist = "";
    state.lib_album = "";
    if (state.view_pl != null) {
        state.view_pl = null;
        state.tracks = &.{};
    }
    refreshSuggestionsLocal(state) catch {
        state.suggestions = &.{};
    };
    state.status = TYPING_STATUS;
}

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
    const after_local = pls.len + state.local_hits.len;
    if (row < after_local) return null;
    const i = row - after_local;
    return if (i < state.suggestions.len) state.suggestions[i] else null;
}

fn selectedLocalHit(state: *State) ?usize {
    const row = state.sel_row orelse return null;
    var buf: [MAX_PL_ROWS]usize = undefined;
    const pls = matchedPlaylists(state, &buf);
    if (row < pls.len) return null;
    const i = row - pls.len;
    return if (i < state.local_hits.len) i else null;
}

fn playLocalHit(gpa: std.mem.Allocator, arena: std.mem.Allocator, io: std.Io, state: *State, idx: usize) !void {
    _ = state.play_arena.reset(.retain_capacity);
    const pa = state.play_arena.allocator();
    var q = try pa.alloc(api.Track, state.local_hits.len);
    for (state.local_hits, 0..) |src, i| q[i] = try cloneTrack(pa, src);
    state.queue = q;
    state.queue_idx = idx;
    try playQueueCurrent(gpa, arena, io, state);
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
            popCodepoint(&state.picker_name);
        },
        .text => |t| {
            state.picker_sel = new_row;
            try state.picker_name.appendSlice(gpa, t);
        },
        else => {},
    }
    return true;
}

fn lastFetched(state: *const State) []const u8 {
    return state.last_fetched_buf[0..state.last_fetched_len];
}

fn setLastFetched(state: *State, q: []const u8) void {
    state.last_fetched_len = @min(q.len, state.last_fetched_buf.len);
    @memcpy(state.last_fetched_buf[0..state.last_fetched_len], q[0..state.last_fetched_len]);
}

fn ensureIndexCached(state: *State) void {
    if (state.lib_ready or state.music_dir.len == 0 or state.lib_cache_path.len == 0) return;
    const cached = library.loadCache(state.idx_arena.allocator(), state.lib_cache_path);
    if (!cached.matches(state.music_dir)) return;
    state.lib_entries = cached.entries;
    state.lib_ready = true;
}

fn refreshMusicDir(state: *State, arena: std.mem.Allocator) void {
    if (state.config_path.len == 0) return;
    const now = config.loadKey(arena, state.config_path, .music_dir) orelse "";
    if (std.mem.eql(u8, now, state.music_dir)) return;
    state.music_dir = now;
    dropIndexViews(state);
    _ = state.idx_arena.reset(.retain_capacity);
}

fn refreshLocalHits(state: *State) void {
    ensureIndexCached(state);
    _ = state.hit_arena.reset(.retain_capacity);
    state.local_hits = &.{};
    if (!state.scope.wantsLibrary()) return;
    if (!state.lib_ready or state.query.items.len == 0) return;

    const ha = state.hit_arena.allocator();
    const found = library.search(ha, state.lib_entries, state.query.items, MAX_LOCAL_HITS) catch return;
    var rows = ha.alloc(api.Track, found.len) catch return;
    for (found, 0..) |e, i| rows[i] = library.toTrack(e);
    state.local_hits = rows;
}

fn refreshSuggestionsLocal(state: *State) !void {
    refreshLocalHits(state);
    _ = state.sug_arena.reset(.retain_capacity);
    const a = state.sug_arena.allocator();
    const hist_matches = try history.match(a, state.hist, state.query.items, MAX_SUGGESTIONS);
    state.suggestions = try mergeSuggestions(a, state, hist_matches, &.{});
    state.scroll_row = 0;
}

fn mergeSuggestions(
    a: std.mem.Allocator,
    state: *State,
    hist_matches: []const []const u8,
    remote: []const []const u8,
) ![][]const u8 {
    const from_lib: []const []const u8 = if (state.scope.wantsLibrary() and state.lib_ready)
        library.namesMatching(a, state.lib_entries, state.query.items, MAX_LIB_NAMES) catch &.{}
    else
        &.{};

    var out: std.ArrayList([]const u8) = .empty;
    var seen: std.StringHashMap(void) = .init(a);
    for ([_][]const []const u8{ hist_matches, from_lib, remote }) |group| {
        for (group) |sug| {
            if (out.items.len >= MAX_SUGGESTIONS) break;
            if (seen.contains(sug)) continue;
            try seen.put(sug, {});
            try out.append(a, sug);
        }
    }
    return out.toOwnedSlice(a);
}

fn refreshSuggestions(gpa: std.mem.Allocator, io: std.Io, state: *State) !void {
    _ = state.sug_arena.reset(.retain_capacity);
    const a = state.sug_arena.allocator();
    setLastFetched(state, state.query.items);
    const local = try history.match(a, state.hist, state.query.items, MAX_SUGGESTIONS);
    const remote: []const []const u8 = if (state.scope.wantsYoutube())
        suggest.fetch(a, gpa, io, state.query.items, MAX_SUGGESTIONS) catch &.{}
    else
        &.{};
    state.suggestions = try mergeSuggestions(a, state, local, remote);
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

    if (state.scope == .library) return runLibrarySearch(state, q_src);

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

fn runLibrarySearch(state: *State, query: []const u8) !void {
    ensureIndexCached(state);
    if (!state.lib_ready) {
        state.status = if (state.music_dir.len == 0)
            "no music_dir set — try: hum library dir ~/Music"
        else
            "library not scanned yet — ^L to scan";
        return;
    }

    _ = state.search_arena.reset(.retain_capacity);
    const sa = state.search_arena.allocator();

    const rows: []api.Track = switch (state.filter) {
        .albums => blk: {
            const albums = library.albumsMatching(sa, state.lib_entries, query, MAX_RESULTS) catch &.{};
            var r = try sa.alloc(api.Track, albums.len);
            for (albums, 0..) |al, i| r[i] = .{
                .source = .local,
                .browse_id = al.album,
                .title = al.album,
                .artist = al.artist,
                .kind = "Album",
            };
            break :blk r;
        },
        .artists => blk: {
            const names = library.artistsMatching(sa, state.lib_entries, query, MAX_RESULTS) catch &.{};
            var r = try sa.alloc(api.Track, names.len);
            for (names, 0..) |name, i| {
                var count: usize = 0;
                for (state.lib_entries) |e| {
                    if (std.ascii.eqlIgnoreCase(e.artist, name)) count += 1;
                }
                r[i] = .{
                    .source = .local,
                    .browse_id = name,
                    .title = name,
                    .artist = try std.fmt.allocPrint(sa, "{d} track{s}", .{ count, if (count == 1) "" else "s" }),
                    .kind = "Artist",
                };
            }
            break :blk r;
        },
        else => blk: {
            const found = library.search(sa, state.lib_entries, query, MAX_RESULTS) catch &.{};
            var r = try sa.alloc(api.Track, found.len);
            for (found, 0..) |e, i| r[i] = library.toTrack(e);
            break :blk r;
        },
    };
    if (rows.len == 0) {
        state.status = "no local matches";
        state.tracks = &.{};
        return;
    }

    if (state.hist_path.len > 0) {
        history.append(sa, state.hist_path, query) catch {};
        reloadHistory(state);
    }

    state.tracks = rows;
    state.sel_track = 0;
    state.scroll_track = 0;
    state.in_library = false;
    state.phase = .results;
    setStatus(state, "{d} local {s} · ⏎ open · h back", .{ rows.len, state.filter.label() });
}

fn mediaKey(arena: std.mem.Allocator, state: *State, ch: u8) bool {
    const p = state.pl orelse return false;
    switch (ch) {
        ' ' => _ = p.togglePause(),
        '[' => p.seekRelative(-SEEK_SHORT_S),
        ']' => p.seekRelative(SEEK_SHORT_S),
        '{' => p.seekRelative(-SEEK_LONG_S),
        '}' => p.seekRelative(SEEK_LONG_S),
        '-', '_' => {
            state.volume = p.nudgeVolume(-VOLUME_STEP);
            persistVolume(arena, state);
        },
        '=', '+' => {
            state.volume = p.nudgeVolume(VOLUME_STEP);
            persistVolume(arena, state);
        },
        'm' => _ = p.toggleMute(),
        else => return false,
    }
    return true;
}

fn handleVis(arena: std.mem.Allocator, state: *State, key: Key) bool {
    switch (key) {
        .ctrl_c => return false,
        .escape => state.vis_view = false,
        .up => _ = mediaKey(arena, state, '='),
        .down => _ = mediaKey(arena, state, '-'),
        .left => _ = mediaKey(arena, state, '['),
        .right => _ = mediaKey(arena, state, ']'),
        .text => |t| if (t.len == 1) switch (t[0]) {
            'v' => cycleVis(arena, state, 1),
            'V' => cycleVis(arena, state, -1),
            else => _ = mediaKey(arena, state, t[0]),
        },
        else => {},
    }
    return true;
}

fn setScope(arena: std.mem.Allocator, state: *State, scope: Scope) void {
    state.scope = scope;
    if (scope == .library and state.music_dir.len == 0) {
        state.status = "search: library — but no music_dir set (hum library dir ~/Music)";
    } else {
        setStatus(state, "search: {s}", .{scope.label()});
    }
    refreshSuggestionsLocal(state) catch {};
    state.last_fetched_len = 0;
    saveSetting(arena, state, .scope, scope.label());
}

fn setFilter(state: *State, filter: api.Filter) void {
    state.filter = if (state.scope == .library and filter == .videos) .all else filter;
    state.status = state.filter.label();
    if (state.scope == .library) refreshLocalHits(state);
}

fn dispatchPhase(gpa: std.mem.Allocator, arena: std.mem.Allocator, io: std.Io, state: *State, key: Key) !bool {
    return switch (state.phase) {
        .typing => try handleTyping(gpa, arena, io, state, key),
        .results => try handleResults(gpa, arena, io, state, key),
        .picker => try handlePicker(gpa, state, key),
        .queue => try handleQueue(gpa, arena, io, state, key),
    };
}

fn handleMouse(gpa: std.mem.Allocator, arena: std.mem.Allocator, io: std.Io, state: *State, m: Mouse) !bool {
    const base = m.button & ~@as(u16, 4 | 8 | 16);
    const row: usize = m.y -| 1;
    const col: usize = m.x -| 1;
    const vis_on = state.vis_view and state.now_track != null;

    if (base == 64 or base == 65) {
        const up = base == 64;
        if (vis_on and state.panel_rect.contains(col, row)) {
            const first = panelFirst(state);
            state.panel_top = if (up) first -| 1 else @min(first + 1, state.queue.len -| 1);
        } else if (vis_on) {
            _ = mediaKey(arena, state, if (up) '=' else '-');
        } else for (0..WHEEL_ROWS) |_| {
            if (!try dispatchPhase(gpa, arena, io, state, if (up) .up else .down)) return false;
        }
        return true;
    }

    if (!m.press) return mouseRelease(gpa, arena, io, state, col, row);
    state.drag_from = null;

    if (state.now_track != null and state.np_bar_cols > 0 and row == state.np_top + 2 and col >= 2 and col < 2 + state.np_bar_cols) {
        if (base == 0) if (state.pl) |p| p.seekPercent(@as(f64, @floatFromInt(col - 2)) * 100.0 / @as(f64, @floatFromInt(state.np_bar_cols)));
        return true;
    }
    if (vis_on) {
        if (state.vis_rect.contains(col, row)) {
            if (base == 0) cycleVis(arena, state, 1) else if (base == 2) cycleVis(arena, state, -1);
        } else if (base == 0) {
            state.drag_from = panelIndexAt(state, col, row);
        }
        return true;
    }
    if (base != 0) return true;

    if (state.mode_row) |mr| if (row == mr) {
        for (state.mode_hits[0..state.mode_hit_len]) |hit| {
            if (col >= hit.x and col < hit.x + hit.w) switch (hit.target) {
                .scope => |sc| setScope(arena, state, sc),
                .filter => |f| setFilter(state, f),
            };
        }
        return true;
    };
    if (row < state.body_top or row >= state.body_top + state.body_rows) return true;
    const r = row - state.body_top;

    switch (state.phase) {
        .typing => {
            const idx = state.scroll_row + r;
            if (idx >= typingRowCount(state)) return true;
            if (state.sel_row == idx) return dispatchPhase(gpa, arena, io, state, .enter);
            state.sel_row = idx;
        },
        .results => {
            const idx = state.scroll_track + r;
            if (idx >= state.tracks.len) return true;
            if (state.sel_track == idx) return dispatchPhase(gpa, arena, io, state, .enter);
            state.sel_track = idx;
        },
        .queue => {
            const idx = state.queue_scroll + r;
            if (idx < state.queue.len) state.drag_from = idx;
        },
        .picker => {
            const head: usize = if (state.picker_track != null) 2 else 0;
            if (r < head) return true;
            const idx = r - head;
            if (idx > state.playlists.len) return true;
            if (state.picker_sel == idx) return dispatchPhase(gpa, arena, io, state, .enter);
            state.picker_sel = idx;
        },
    }
    return true;
}

fn mouseRelease(gpa: std.mem.Allocator, arena: std.mem.Allocator, io: std.Io, state: *State, col: usize, row: usize) !bool {
    const from = state.drag_from orelse return true;
    state.drag_from = null;
    if (state.vis_view and state.now_track != null) {
        const to = panelIndexAt(state, col, row) orelse return true;
        if (to != from) {
            queueMove(state, from, to);
            return true;
        }
        state.queue_idx = from;
        try playQueueCurrent(gpa, arena, io, state);
        return true;
    }
    if (state.phase != .queue or row < state.body_top or row >= state.body_top + state.body_rows) return true;
    const to = state.queue_scroll + (row - state.body_top);
    if (to >= state.queue.len) return true;
    if (to != from) {
        queueMove(state, from, to);
        return true;
    }
    if (state.queue_sel == to) return dispatchPhase(gpa, arena, io, state, .enter);
    state.queue_sel = to;
    return true;
}

fn panelFirst(state: *const State) usize {
    return @min(state.panel_top orelse state.queue_idx, state.queue.len -| 1);
}

fn panelIndexAt(state: *const State, col: usize, row: usize) ?usize {
    if (!state.panel_rect.contains(col, row)) return null;
    const r = row - state.panel_rect.y;
    if (r == 0) return null;
    const qi = panelFirst(state) + (r - 1) / 2;
    return if (qi < state.queue.len) qi else null;
}

fn typingRowCount(state: *State) usize {
    var pl_buf: [MAX_PL_ROWS]usize = undefined;
    return matchedPlaylists(state, &pl_buf).len + state.local_hits.len + state.suggestions.len;
}

fn cycleVis(arena: std.mem.Allocator, state: *State, dir: i2) void {
    const n = vis.count(state.flipbooks);
    state.vis_idx = if (dir > 0) (state.vis_idx + 1) % n else (state.vis_idx + n - 1) % n;
    saveSetting(arena, state, .visualizer, vis.name(state.vis_idx, state.flipbooks));
}

fn loadFlipbooks(arena: std.mem.Allocator, io: std.Io, config_path: []const u8) []const vis.Flipbook {
    const base = std.fs.path.dirname(config_path) orelse return &.{};
    const dir_path = std.fmt.allocPrint(arena, "{s}/visualizers", .{base}) catch return &.{};
    var dir = std.Io.Dir.openDirAbsolute(io, dir_path, .{ .iterate = true }) catch return &.{};
    defer dir.close(io);

    var out: std.ArrayList(vis.Flipbook) = .empty;
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (out.items.len >= MAX_FLIPBOOKS) break;
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".vis")) continue;
        const full = std.fmt.allocPrint(arena, "{s}/{s}", .{ dir_path, entry.name }) catch continue;
        const bytes = fsutil.readCappedAlloc(arena, full, vis.MAX_FILE_BYTES) orelse continue;
        const stem = entry.name[0 .. entry.name.len - ".vis".len];
        const fb = vis.parseFlipbook(arena, bytes, stem) orelse {
            log.write("visualizer {s}: no frames found, skipped", .{entry.name});
            continue;
        };
        if (vis.indexOf(fb.name, out.items) != null) continue;
        out.append(arena, fb) catch break;
    }
    return out.toOwnedSlice(arena) catch &.{};
}

fn persistVolume(arena: std.mem.Allocator, state: *State) void {
    var buf: [16]u8 = undefined;
    saveSetting(arena, state, .volume, std.fmt.bufPrint(&buf, "{d:.0}", .{state.volume}) catch return);
}

fn saveSetting(arena: std.mem.Allocator, state: *State, key: config.Key, value: []const u8) void {
    if (state.config_path.len == 0) return;
    config.saveKey(arena, state.config_path, key, value) catch |err| log.write("config: saving {s} failed: {s}", .{ @tagName(key), @errorName(err) });
}

fn ensurePlayer(gpa: std.mem.Allocator, state: *State) !*player.Player {
    if (state.pl) |p| return p;
    const p = try gpa.create(player.Player);
    errdefer gpa.destroy(p);
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
    if (std.mem.eql(u8, t.kind, "Feed")) {
        return openFeedEpisodes(gpa, io, state, t.browse_id, t.title);
    }
    if (t.source == .local) {
        if (std.mem.eql(u8, t.kind, "Artist")) {
            state.lib_artist = t.browse_id;
            state.lib_album = "";
            return showAlbums(state);
        }
        if (std.mem.eql(u8, t.kind, "Album")) {
            state.lib_album = t.browse_id;
            if (state.lib_artist.len == 0) state.lib_artist = t.artist;
            return showTracks(state);
        }
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

// ------------------------------------------------------------------ library

const ScanCtx = struct {
    state: *State,
    gpa: std.mem.Allocator,

    fn tick(ctx: *anyopaque, scanned: usize) bool {
        const self: *ScanCtx = @ptrCast(@alignCast(ctx));
        self.state.scanning = true;
        self.state.scan_count = scanned;
        setStatus(self.state, "scanning… {d} files · any key to stop", .{scanned});
        draw(self.gpa, self.state) catch {};
        const pressed = waitInput(0) catch false;
        if (!pressed) return true;
        var buf: [8]u8 = undefined;
        _ = readKey(&buf) catch {};
        return false;
    }
};

fn dropIndexViews(state: *State) void {
    if (state.in_library) {
        state.tracks = &.{};
        state.sel_track = 0;
        state.scroll_track = 0;
    }
    state.lib_artist = "";
    state.lib_album = "";
    state.local_hits = &.{};
    _ = state.hit_arena.reset(.retain_capacity);
    state.lib_entries = &.{};
    state.lib_ready = false;
}

fn ensureIndex(gpa: std.mem.Allocator, io: std.Io, state: *State, force: bool) bool {
    if (state.lib_ready and !force) return true;

    if (state.music_dir.len == 0) {
        state.status = "no music_dir set — try: hum library dir ~/Music";
        return false;
    }
    if (force) {
        dropIndexViews(state);
        _ = state.idx_arena.reset(.retain_capacity);
    }

    const ia = state.idx_arena.allocator();
    const from_disk: library.Cached = if (state.lib_cache_path.len > 0)
        library.loadCache(ia, state.lib_cache_path)
    else
        .{};
    const cached: []library.Entry = if (from_disk.matches(state.music_dir)) from_disk.entries else &.{};

    if (!force and cached.len > 0) {
        state.lib_entries = cached;
        state.lib_ready = true;
        return true;
    }

    const env = state.env orelse return false;
    const dirs = library.roots(ia, env, state.music_dir) catch return false;
    if (dirs.len == 0) {
        state.status = "music_dir is empty — try: hum library dir ~/Music";
        return false;
    }

    var ctx: ScanCtx = .{ .state = state, .gpa = gpa };
    state.scanning = true;
    state.scan_count = 0;
    defer state.scanning = false;
    const res = library.scan(ia, io, dirs, cached, .{ .ctx = &ctx, .on = ScanCtx.tick }) catch |err| {
        survive(state, "library scan", err);
        return false;
    };
    state.lib_entries = res.entries;
    state.lib_ready = res.complete;
    if (res.complete and state.lib_cache_path.len > 0) {
        library.saveCache(ia, state.lib_cache_path, state.music_dir, res.entries) catch {};
    }
    return true;
}

fn openLibrary(gpa: std.mem.Allocator, io: std.Io, state: *State, rescan: bool) !void {
    refreshMusicDir(state, state.search_arena.allocator());
    if (!ensureIndex(gpa, io, state, rescan)) return;
    if (state.lib_entries.len == 0) {
        state.status = "library empty — nothing playable under music_dir";
        return;
    }
    state.lib_artist = "";
    state.lib_album = "";
    const partial = !state.lib_ready;
    try showArtists(state);
    if (partial) {
        setStatus(state, "scan stopped · {d} files so far · ^L to finish", .{state.lib_entries.len});
    }
}

fn enterLibraryRows(state: *State, rows: []api.Track) void {
    state.phase = .results;
    state.in_library = true;
    state.view_pl = null;
    state.tracks = rows;
    state.sel_track = 0;
    state.scroll_track = 0;
}

fn showArtists(state: *State) !void {
    _ = state.search_arena.reset(.retain_capacity);
    const sa = state.search_arena.allocator();

    const names = try library.artistsOf(sa, state.lib_entries);
    var rows = try sa.alloc(api.Track, names.len);
    for (names, 0..) |name, i| {
        var count: usize = 0;
        for (state.lib_entries) |e| {
            if (std.ascii.eqlIgnoreCase(e.artist, name)) count += 1;
        }
        rows[i] = .{
            .source = .local,
            .browse_id = name,
            .title = name,
            .artist = try std.fmt.allocPrint(sa, "{d} track{s}", .{ count, if (count == 1) "" else "s" }),
            .kind = "Artist",
        };
    }
    enterLibraryRows(state, rows);
    state.status = "library · ⏎ open · h back · ^L rescan";
}

fn showAlbums(state: *State) !void {
    const artist = state.lib_artist;
    _ = state.search_arena.reset(.retain_capacity);
    const sa = state.search_arena.allocator();

    const albums = try library.albumsOf(sa, state.lib_entries, artist);
    var rows = try sa.alloc(api.Track, albums.len);
    for (albums, 0..) |album, i| {
        rows[i] = .{
            .source = .local,
            .browse_id = album,
            .title = album,
            .artist = artist,
            .kind = "Album",
        };
    }
    enterLibraryRows(state, rows);
    state.status = "⏎ open album · h back";
}

fn showTracks(state: *State) !void {
    const artist = state.lib_artist;
    const album = state.lib_album;
    _ = state.search_arena.reset(.retain_capacity);
    const sa = state.search_arena.allocator();

    const found = try library.tracksOf(sa, state.lib_entries, artist, album);
    var rows = try sa.alloc(api.Track, found.len);
    for (found, 0..) |e, i| rows[i] = library.toTrack(e);

    enterLibraryRows(state, rows);
    state.status = "⏎ play · P save · h back";
}

fn libraryBack(state: *State) !void {
    if (state.lib_album.len > 0) {
        state.lib_album = "";
        return showAlbums(state);
    }
    if (state.lib_artist.len > 0) {
        state.lib_artist = "";
        return showArtists(state);
    }
    backToTyping(state);
}

fn libraryCrumb(state: *State, buf: []u8) []const u8 {
    if (state.lib_album.len > 0) {
        return std.fmt.bufPrint(buf, "library · {s} · {s}", .{ state.lib_artist, state.lib_album }) catch "library";
    }
    if (state.lib_artist.len > 0) {
        return std.fmt.bufPrint(buf, "library · {s}", .{state.lib_artist}) catch "library";
    }
    return "library";
}

// ------------------------------------------------------------------ podcasts

fn openFeeds(gpa: std.mem.Allocator, io: std.Io, state: *State) !void {
    _ = gpa;
    _ = io;
    if (state.feeds_path.len == 0) {
        state.status = "no data dir for feeds";
        return;
    }
    _ = state.search_arena.reset(.retain_capacity);
    const sa = state.search_arena.allocator();

    const subs = feed.loadSubs(sa, state.feeds_path);
    if (subs.len == 0) {
        state.status = "no subscriptions — add one with: hum feeds add <url>";
        return;
    }
    var rows = try sa.alloc(api.Track, subs.len);
    for (subs, 0..) |sub, i| rows[i] = .{
        .source = .url,
        .browse_id = sub.url,
        .title = if (sub.title.len > 0) sub.title else sub.url,
        .artist = hostOf(sub.url),
        .kind = "Feed",
    };

    state.phase = .results;
    state.in_feeds = true;
    state.in_library = false;
    state.view_pl = null;
    state.feed_title = "";
    state.tracks = rows;
    state.sel_track = 0;
    state.scroll_track = 0;
    state.status = "podcasts · ⏎ open · h back";
}

fn openFeedEpisodes(gpa: std.mem.Allocator, io: std.Io, state: *State, url: []const u8, title: []const u8) !void {
    state.status = "fetching episodes…";
    try draw(gpa, state);

    const body = feed.fetch(gpa, io, url) catch |err| {
        log.write("feed fetch failed: {s} url={s}", .{ @errorName(err), url });
        state.status = "could not fetch that feed (see log)";
        return;
    };
    defer gpa.free(body);

    _ = state.search_arena.reset(.retain_capacity);
    const sa = state.search_arena.allocator();
    const kept_title = sa.dupe(u8, title) catch title;

    const parsed = feed.parse(sa, body) orelse {
        state.status = "that feed did not parse";
        return;
    };
    if (parsed.episodes.len == 0) {
        state.status = "no playable episodes in that feed";
        return;
    }
    var rows = try sa.alloc(api.Track, parsed.episodes.len);
    for (parsed.episodes, 0..) |ep, i| rows[i] = feed.toTrack(ep, kept_title);

    state.feed_title = kept_title;
    state.tracks = rows;
    state.sel_track = 0;
    state.scroll_track = 0;
    setStatus(state, "{d} episodes · ⏎ play · h back", .{rows.len});
}

fn hostOf(url: []const u8) []const u8 {
    const after = if (std.mem.indexOf(u8, url, "://")) |i| url[i + 3 ..] else url;
    const end = std.mem.indexOfScalar(u8, after, '/') orelse after.len;
    return after[0..end];
}

fn feedsBack(gpa: std.mem.Allocator, io: std.Io, state: *State) !void {
    if (state.feed_title.len > 0) {
        state.feed_title = "";
        return openFeeds(gpa, io, state);
    }
    backToTyping(state);
}

// -------------------------------------------------------------------- queue

fn openQueue(state: *State) void {
    if (state.queue.len == 0) {
        state.status = "queue is empty";
        return;
    }
    state.queue_from = state.phase;
    state.phase = .queue;
    state.queue_sel = state.queue_idx;
    state.status = "queue · K/J move · d remove · ⏎ play · h back";
}

fn queueAdd(state: *State, play_next: bool) !void {
    if (state.tracks.len == 0) return;
    const t = state.tracks[state.sel_track];
    if (!t.isPlayable()) {
        state.status = "that row has nothing to queue";
        return;
    }
    const pa = state.play_arena.allocator();
    const copy = try cloneTrack(pa, t);

    var grown = try pa.alloc(api.Track, state.queue.len + 1);
    const at = if (play_next and state.queue.len > 0) @min(state.queue_idx + 1, state.queue.len) else state.queue.len;
    @memcpy(grown[0..at], state.queue[0..at]);
    grown[at] = copy;
    @memcpy(grown[at + 1 ..], state.queue[at..]);
    state.queue = grown;
    if (at <= state.queue_idx and state.queue.len > 1 and !play_next) state.queue_idx += 1;

    setStatus(state, "queued {s}{s}", .{ if (play_next) "next: " else "", t.title });
}

fn queueMove(state: *State, from: usize, to: usize) void {
    const q = state.queue;
    if (from >= q.len or to >= q.len or from == to) return;
    const t = q[from];
    if (from < to) {
        std.mem.copyForwards(api.Track, q[from..to], q[from + 1 .. to + 1]);
    } else {
        std.mem.copyBackwards(api.Track, q[to + 1 .. from + 1], q[to..from]);
    }
    q[to] = t;
    const qi = state.queue_idx;
    if (qi == from) {
        state.queue_idx = to;
    } else if (from < qi and qi <= to) {
        state.queue_idx = qi - 1;
    } else if (to <= qi and qi < from) {
        state.queue_idx = qi + 1;
    }
    state.queue_sel = to;
}

fn queueShuffle(state: *State) void {
    if (state.queue.len < 3) {
        state.status = "not enough queued to shuffle";
        return;
    }
    var stack_marker: u8 = 0;
    shuffle_salt +%= 1;
    var seed: u64 = @intFromPtr(&stack_marker);
    seed ^= state.tick *% 0x9E3779B97F4A7C15;
    seed ^= shuffle_salt *% 0xBF58476D1CE4E5B9;
    var prng = std.Random.DefaultPrng.init(seed);
    const rand = prng.random();

    var i = state.queue.len - 1;
    const first = state.queue_idx + 1;
    while (i > first) : (i -= 1) {
        const j = first + rand.uintLessThan(usize, i - first + 1);
        const tmp = state.queue[i];
        state.queue[i] = state.queue[j];
        state.queue[j] = tmp;
    }
    setStatus(state, "shuffled {d} upcoming", .{state.queue.len -| first});
}

fn queueRemove(state: *State, idx: usize) void {
    if (idx >= state.queue.len) return;
    var i = idx;
    while (i + 1 < state.queue.len) : (i += 1) state.queue[i] = state.queue[i + 1];
    state.queue = state.queue[0 .. state.queue.len - 1];

    if (state.queue.len == 0) {
        state.queue_idx = 0;
        state.queue_sel = 0;
        state.phase = state.queue_from;
        state.status = "queue emptied";
        return;
    }
    if (idx < state.queue_idx) state.queue_idx -= 1;
    if (state.queue_sel >= state.queue.len) state.queue_sel = state.queue.len - 1;
}

fn handleQueue(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    io: std.Io,
    state: *State,
    key: Key,
) !bool {
    const n = state.queue.len;
    const max_idx = if (n == 0) 0 else n - 1;
    switch (key) {
        .ctrl_c => return false,
        .escape, .left => state.phase = state.queue_from,
        .up => if (state.queue_sel > 0) {
            state.queue_sel -= 1;
        },
        .down => if (state.queue_sel + 1 < n) {
            state.queue_sel += 1;
        },
        .home => state.queue_sel = 0,
        .end => state.queue_sel = max_idx,
        .page_up => state.queue_sel = if (state.queue_sel > 10) state.queue_sel - 10 else 0,
        .page_down => state.queue_sel = @min(state.queue_sel + 10, max_idx),
        .enter, .right => if (n > 0) {
            state.queue_idx = state.queue_sel;
            try playQueueCurrent(gpa, arena, io, state);
        },
        .ctrl => |b| switch (b) {
            0x11 => state.phase = state.queue_from,
            else => {},
        },
        .text => |t| if (t.len == 1) switch (t[0]) {
            'j' => if (state.queue_sel + 1 < n) {
                state.queue_sel += 1;
            },
            'k' => if (state.queue_sel > 0) {
                state.queue_sel -= 1;
            },
            'J' => if (state.queue_sel + 1 < n) queueMove(state, state.queue_sel, state.queue_sel + 1),
            'K' => if (state.queue_sel > 0) queueMove(state, state.queue_sel, state.queue_sel - 1),
            's' => queueShuffle(state),
            'd', 'x' => queueRemove(state, state.queue_sel),
            'h' => state.phase = state.queue_from,
            'g' => state.queue_sel = 0,
            'G' => state.queue_sel = max_idx,
            else => _ = mediaKey(arena, state, t[0]),
        },
        else => {},
    }
    return true;
}

fn drawQueue(w: *std.Io.Writer, th: theme_mod.Theme, inner: usize, rows: usize, state: *State) !void {
    const n = state.queue.len;
    if (n == 0) {
        try drawRow(w, th, inner, "  (queue is empty)", .{ .dim = true });
        try blankRows(w, th, inner, rows -| 1);
        return;
    }
    clampScroll(&state.queue_scroll, state.queue_sel, n, rows);
    const start = state.queue_scroll;
    const end = @min(start + rows, n);

    var idx = start;
    var buf: [512]u8 = undefined;
    while (idx < end) : (idx += 1) {
        const t = state.queue[idx];
        const mark = if (idx == state.queue_idx) "▶ " else "  ";
        const label = std.fmt.bufPrint(&buf, "{s}{s}  — {s}", .{ mark, t.title, t.artist }) catch t.title;
        const tag = if (t.source == .youtube) " [yt]" else " [local]";
        try drawListRow(w, th, inner, label, tag, idx == state.queue_sel);
    }
    try blankRows(w, th, inner, rows - (end - start));
}

fn cloneTrack(a: std.mem.Allocator, t: api.Track) !api.Track {
    return .{
        .source = t.source,
        .video_id = try a.dupe(u8, t.video_id),
        .uri = try a.dupe(u8, t.uri),
        .browse_id = try a.dupe(u8, t.browse_id),
        .title = try a.dupe(u8, t.title),
        .artist = try a.dupe(u8, t.artist),
        .album = try a.dupe(u8, t.album),
        .duration_s = t.duration_s,
        .kind = try a.dupe(u8, t.kind),
    };
}

fn playQueueCurrent(gpa: std.mem.Allocator, arena: std.mem.Allocator, io: std.Io, state: *State) !void {
    state.panel_top = null;
    if (state.queue.len == 0 or state.queue_idx >= state.queue.len) return;
    const t = state.queue[state.queue_idx];
    if (!t.isPlayable()) {
        state.status = "nothing to play there";
        return;
    }

    const p = try ensurePlayer(gpa, state);
    p.stop();
    state.now_track = t;
    state.connecting = t.source == .youtube;
    if (state.connecting) {
        state.status = "connecting to YouTube…";
        try draw(gpa, state);
    }

    const url = stream.resolve(gpa, io, t) catch |err| {
        log.write("stream resolve failed: {s} source={s} target={s} title=\"{s}\"", .{
            @errorName(err),
            track_mod.sourceName(t.source),
            if (t.source == .youtube) t.video_id else t.uri,
            t.title,
        });
        state.now_track = null;
        state.connecting = false;
        if (t.source == .youtube) if (staleYtdlp(gpa, io, state)) |days| {
            setStatus(state, "yt-dlp failed: it is {d} days old, update it", .{days});
            return;
        };
        state.status = switch (t.source) {
            .youtube => "yt-dlp failed (see log)",
            .local => "cannot open that file (see log)",
            .url => "cannot open that URL (see log)",
        };
        return;
    };
    defer gpa.free(url);

    try p.loadUrl(arena, url, try t.mediaTitle(arena));
    state.connecting = false;
    state.status = "playing";
}

fn queueAdvance(gpa: std.mem.Allocator, arena: std.mem.Allocator, io: std.Io, state: *State, auto: bool) !void {
    if (state.queue.len == 0) return;
    if (auto and state.repeat == .track) {
        try playQueueCurrent(gpa, arena, io, state);
        return;
    }
    var next = state.queue_idx + 1;
    while (next < state.queue.len and !state.queue[next].isPlayable()) next += 1;
    if (next >= state.queue.len) {
        if (state.repeat == .queue) {
            var first: usize = 0;
            while (first < state.queue.len and !state.queue[first].isPlayable()) first += 1;
            if (first < state.queue.len) {
                state.queue_idx = first;
                try playQueueCurrent(gpa, arena, io, state);
                return;
            }
        }
        if (state.pl) |p| {
            p.stop();
            state.now_track = null;
            state.status = "queue end";
        }
        return;
    }
    state.queue_idx = next;
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
        .file_error => {
            const why = if (state.pl) |p| p.last_error else "";
            const title = if (state.now_track) |t| t.title else "";
            log.write("playback failed: {s} title=\"{s}\"", .{ why, title });
            const was_youtube = if (state.now_track) |t| t.source == .youtube else false;
            state.now_track = null;
            state.connecting = false;
            if (was_youtube) if (staleYtdlp(gpa, io, state)) |days| {
                setStatus(state, "playback failed: yt-dlp is {d} days old, update it", .{days});
                return;
            };
            setStatus(state, "playback failed: {s} (see log)", .{why});
        },
        .audio_ready => installInterruptHandlers(),
        .shutdown => state.now_track = null,
        else => {},
    }
}

fn staleYtdlp(gpa: std.mem.Allocator, io: std.Io, state: *State) ?u32 {
    if (!state.ytdlp_checked) {
        state.ytdlp_checked = true;
        if (stream.ytdlpVersion(gpa, io)) |ver| {
            defer gpa.free(ver);
            state.ytdlp_age = stream.ytdlpAgeDays(ver, std.Io.Clock.real.now(io).toSeconds());
        }
    }
    const days = state.ytdlp_age orelse return null;
    return if (days >= stream.STALE_DAYS) days else null;
}

const cpWidth = text_mod.cpWidth;

const Step = struct { cols: usize, len: usize };

fn stepCols(s: []const u8, i: usize) Step {
    const b = s[i];
    if (b < 0x80) return .{ .cols = cpWidth(b), .len = 1 };
    const len: usize = switch (b) {
        0xC2...0xDF => 2,
        0xE0...0xEF => 3,
        0xF0...0xF4 => 4,
        else => return .{ .cols = 1, .len = 1 },
    };
    if (i + len > s.len) return .{ .cols = 1, .len = 1 };
    const cp = std.unicode.utf8Decode(s[i .. i + len]) catch return .{ .cols = 1, .len = 1 };
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
    state.np_bar_cols = 0;
    if (state.vis_view and state.now_track == null) state.vis_view = false;
    if (state.vis_view) return drawVisView(gpa, state, sz.cols, sz.rows);
    const need: usize = sz.cols * sz.rows * 32 + 4096;
    if (state.draw_buf.capacity < need) {
        try state.draw_buf.ensureTotalCapacity(gpa, need);
    }
    state.draw_buf.clearRetainingCapacity();
    var w: std.Io.Writer = .fixed(state.draw_buf.allocatedSlice());
    const width = sz.cols;
    const height = sz.rows;
    const inner: usize = if (width > 4) width - 2 else 1;

    const show_mode = state.phase == .typing or state.phase == .results;
    const chrome_main: usize = if (show_mode) 7 else 6;
    const min_body: usize = 3;

    const want_footer: usize = if (state.now_track != null) 6 else 0;
    var footer_rows = want_footer;
    if (want_footer > 0 and height < chrome_main + min_body + want_footer) {
        footer_rows = if (height >= chrome_main + min_body + 4) 4 else 0;
    }
    const body_rows: usize = if (height > chrome_main + footer_rows + min_body)
        height - chrome_main - footer_rows
    else
        height -| (chrome_main + footer_rows);

    const th = state.theme;
    try w.writeAll("\x1b[?2026h\x1b[H");

    try boxTop(&w, th, inner, " ♫ hum ");

    try drawRow(&w, th, inner, state.status, .{ .dim = true });
    try drawSearchRow(&w, th, inner, state);
    if (show_mode) try drawModeLine(&w, th, inner, state);

    var pl_buf: [MAX_PL_ROWS]usize = undefined;
    var crumb_buf: [192]u8 = undefined;
    const pls = matchedPlaylists(state, &pl_buf);
    const section = switch (state.phase) {
        .typing => if (state.scope == .library)
            (if (pls.len > 0) "playlists · library · history" else "library · history")
        else if (pls.len > 0 and state.local_hits.len > 0)
            "playlists · library · suggestions"
        else if (state.local_hits.len > 0)
            "library · suggestions"
        else if (pls.len > 0 and state.suggestions.len > 0)
            "playlists · suggestions"
        else if (pls.len > 0)
            "playlists"
        else
            "suggestions",
        .results => if (state.view_pl) |vi|
            state.playlists[vi].name
        else if (state.in_feeds)
            (if (state.feed_title.len > 0)
                std.fmt.bufPrint(&crumb_buf, "podcasts · {s}", .{state.feed_title}) catch "podcasts"
            else
                "podcasts")
        else if (state.in_library)
            libraryCrumb(state, &crumb_buf)
        else
            "results",
        .picker => "add to playlist",
        .queue => "queue",
    };
    var sec_buf: [192]u8 = undefined;
    const show_filter = state.filter != .all and state.phase == .queue;
    const show_scope = state.scope != .both and state.phase == .queue;
    const sec_label = if (show_filter and show_scope)
        std.fmt.bufPrint(&sec_buf, "{s} ⟨^E {s}⟩ ⟨^T {s}⟩", .{ section, state.scope.label(), state.filter.label() }) catch section
    else if (show_scope)
        std.fmt.bufPrint(&sec_buf, "{s} ⟨^E {s}⟩", .{ section, state.scope.label() }) catch section
    else if (show_filter)
        std.fmt.bufPrint(&sec_buf, "{s} ⟨^T {s}⟩", .{ section, state.filter.label() }) catch section
    else
        section;

    try w.print("{s}├─ {s}{s}{s} ", .{ th.accent, th.bold, sec_label, th.reset });
    try w.writeAll(th.accent);
    try w.splatBytesAll("─", (inner + 1) -| (3 + visibleCols(sec_label) + 1));
    try w.print("┤{s}\r\n", .{th.reset});

    state.body_top = if (show_mode) 5 else 4;
    state.mode_row = if (show_mode) 3 else null;
    state.body_rows = body_rows;
    state.np_top = state.body_top + body_rows + 1;
    if (state.scanning) {
        try drawScanning(&w, th, inner, body_rows, state);
    } else switch (state.phase) {
        .typing => try drawTyping(&w, th, inner, body_rows, state, pls),
        .results => try drawResults(&w, th, inner, body_rows, state),
        .picker => try drawPicker(&w, th, inner, body_rows, state),
        .queue => try drawQueue(&w, th, inner, body_rows, state),
    }

    try boxBottom(&w, th, inner);

    if (state.now_track != null and footer_rows > 0) {
        try drawNowPlaying(&w, th, inner, state, footer_rows, true);
    }

    const tight = width < 76;
    const hint = if (tight) switch (state.phase) {
        .typing => "⏎ search · ^E scope · ^L library · ^Q queue · ^C quit",
        .results => "⏎ play · a queue · h back · [/] seek · ␣ pause",
        .picker => "⏎ add · esc cancel",
        .queue => "KJ move · d remove · ⏎ play · h back",
    } else switch (state.phase) {
        .typing => if (pls.len > 0)
            "↑↓ · ⏎ open/search · ^E scope · ^L library · ^F podcasts · ^Q queue · ^T filter · ^Y theme · ^C quit"
        else
            "tab accept · ⏎ search · ^E scope · ^L library · ^F podcasts · ^Q queue · ^T filter · ^Y theme · ^C quit",
        .results => if (state.view_pl != null)
            "jk/↑↓ · ⏎/l play · P add · d/^X remove · h back · [/] seek · -/= vol · m mute · ^R repeat · ␣/^P pause"
        else
            "jk/↑↓ · ⏎/l play · a/A queue · ^Q queue view · P save · h back · [/] seek · -/= vol · ^V visualizer · ␣ pause",
        .picker => "↑↓ pick · type to name a new playlist · ⏎ add · esc cancel",
        .queue => "jk/↑↓ · KJ move · d remove · s shuffle · ⏎ play · h back · ␣ pause · -/= vol · ^V visualizer",
    };
    const hint_fit = truncateCols(hint, width -| 1);
    try w.print("{s} {s}{s}\x1b[K", .{ th.dim, hint_fit, th.reset });
    try w.writeAll("\x1b[J\x1b[?2026l");

    try writeAll(w.buffered());
}

fn drawVisView(gpa: std.mem.Allocator, state: *State, width: usize, height: usize) !void {
    const need: usize = width * height * 32 + 4096;
    if (state.draw_buf.capacity < need) try state.draw_buf.ensureTotalCapacity(gpa, need);
    state.draw_buf.clearRetainingCapacity();
    var w: std.Io.Writer = .fixed(state.draw_buf.allocatedSlice());
    const th = state.theme;
    try w.writeAll("\x1b[?2026h\x1b[H");

    if (width < 30 or height < 10) {
        try w.writeAll("\x1b[2J");
        const msg = if (width >= 34) "make the terminal a little bigger" else "too small";
        const top = height / 2 -| 1;
        try w.print("\x1b[{d};1H{s}{s}{s}", .{ top + 1, th.dim, truncateCols(msg, width), th.reset });
        try w.writeAll("\x1b[?2026l");
        return writeAll(w.buffered());
    }

    const inner = width - 2;
    const np_rows: usize = if (height >= 16) 5 else 4;
    const main_h = height - np_rows - 1;
    const panel: usize = if (width >= 96) QUEUE_PANEL_COLS else 0;
    const vis_w = width - 4 - (if (panel > 0) panel + 1 else 0);
    const vis_h = main_h - 2;

    var lbl_buf: [96]u8 = undefined;
    const n = vis.count(state.flipbooks);
    const label = std.fmt.bufPrint(&lbl_buf, " ♫ hum · {s} {d}/{d} ", .{ vis.name(state.vis_idx, state.flipbooks), state.vis_idx + 1, n }) catch " ♫ hum ";
    try boxTop(&w, th, inner, label);

    state.mode_row = null;
    state.vis_rect = .{ .x = 2, .y = 1, .w = vis_w, .h = vis_h };
    state.panel_rect = if (panel > 0) .{ .x = vis_w + 4, .y = 1, .w = panel, .h = vis_h } else .{};
    var cv = try state.vis_bufs.canvas(gpa, vis_w, vis_h);
    vis.render(&cv, state.vis_idx, state.flipbooks, &state.vis_motion, visAudio(state), state.tick);

    for (0..vis_h) |y| {
        try w.print("{s}│{s} ", .{ th.accent, th.reset });
        try emitCanvasRow(&w, th, &cv, y);
        try w.writeByte(' ');
        if (panel > 0) {
            try w.print("{s}│{s}", .{ th.dim, th.reset });
            try drawQueuePanelRow(&w, th, panel, y, state);
        }
        try w.print("{s}│{s}\r\n", .{ th.accent, th.reset });
    }

    try boxBottom(&w, th, inner);

    state.np_top = main_h;
    try drawNowPlaying(&w, th, inner, state, np_rows, false);

    const hint = if (width < 76)
        "v/V visualizer · ^V back · ␣ pause · -/= vol"
    else
        "v next · V prev · ^V/esc back · ␣ pause · -/= vol · [/] seek · m mute · ^Y theme";
    try w.print("{s} {s}{s}\x1b[K", .{ th.dim, truncateCols(hint, width -| 1), th.reset });
    try w.writeAll("\x1b[J\x1b[?2026l");
    try writeAll(w.buffered());
}

fn visAudio(state: *State) vis.Audio {
    if (state.vis_audio_tick == state.tick) return state.vis_audio;
    state.vis_audio_tick = state.tick;
    const pl = state.pl orelse return .{};
    const idle = state.connecting or pl.isPaused() or pl.isMuted();
    const raw = if (idle) player.Player.Levels{ .level = 0, .left = 0, .right = 0, .bright = 0 } else pl.levels();
    const a = &state.vis_audio;
    a.paused = idle;
    inline for (.{ "level", "left", "right", "bright" }) |f| {
        const cur = @field(a, f);
        const tgt = @field(raw, f);
        @field(a, f) = cur + (tgt - cur) * (if (tgt > cur) @as(f32, 0.6) else 0.18);
    }
    return a.*;
}

fn emitCanvasRow(w: *std.Io.Writer, th: theme_mod.Theme, cv: *const vis.Canvas, y: usize) !void {
    var cur: vis.Class = .none;
    var enc: [4]u8 = undefined;
    for (0..cv.w) |x| {
        const cell = cv.at(x, y);
        if (cell.cp == vis.WIDE_TAIL) continue;
        if (cell.class != cur and cell.cp != ' ') {
            try w.writeAll(th.reset);
            try w.writeAll(switch (cell.class) {
                .none => "",
                .dim => th.dim,
                .accent => th.accent,
                .strong => th.accent_strong,
            });
            cur = cell.class;
        }
        const len = std.unicode.utf8Encode(cell.cp, &enc) catch {
            try w.writeByte(' ');
            continue;
        };
        try w.writeAll(enc[0..len]);
    }
    try w.writeAll(th.reset);
}

fn drawQueuePanelRow(w: *std.Io.Writer, th: theme_mod.Theme, cols: usize, y: usize, state: *State) !void {
    const room = cols -| 2;
    var used: usize = 0;
    try w.writeByte(' ');
    if (y == 0) {
        const t = truncateCols("up next", room);
        try w.print("{s}{s}{s}", .{ th.dim, t, th.reset });
        used = visibleCols(t);
    } else if (y >= 1) {
        const qi = panelFirst(state) + (y - 1) / 2;
        if (state.queue.len > 0 and qi < state.queue.len) {
            const t = state.queue[qi];
            const playing = qi == state.queue_idx;
            if ((y - 1) % 2 == 0) {
                const mark = if (playing) "▶ " else "  ";
                const title = truncateCols(t.title, room -| 2);
                try w.print("{s}{s}{s}{s}{s}{s}", .{ th.accent_strong, mark, th.reset, if (playing) th.bold else "", title, th.reset });
                used = 2 + visibleCols(title);
            } else {
                const artist = truncateCols(t.artist, room -| 2);
                try w.print("  {s}{s}{s}", .{ th.dim, artist, th.reset });
                used = 2 + visibleCols(artist);
            }
        }
    }
    try w.splatByteAll(' ', (cols -| 1) -| used);
}

fn drawScanning(w: *std.Io.Writer, th: theme_mod.Theme, inner: usize, rows: usize, state: *State) !void {
    const spin = [_][]const u8{ "▁▃▅▇", "▃▅▇▅", "▅▇▅▃", "▇▅▃▁" };
    const bars = spin[(state.scan_count / 32) % spin.len];

    var buf: [256]u8 = undefined;
    const head = std.fmt.bufPrint(&buf, "  {s}  scanning your library…", .{bars}) catch "  scanning…";

    const top = rows / 3;
    try blankRows(w, th, inner, top -| 0);

    try drawRow(w, th, inner, head, .{});

    var line2_buf: [256]u8 = undefined;
    const line2 = std.fmt.bufPrint(&line2_buf, "      {d} files read · reading tags, nothing is being moved", .{state.scan_count}) catch "";
    try drawRow(w, th, inner, line2, .{ .dim = true });
    try drawRow(w, th, inner, "      press any key to stop", .{ .dim = true });

    try blankRows(w, th, inner, rows -| (top + 3));
}

fn modeGroupCols(key: []const u8, labels: []const []const u8, active: usize, only_active: bool) usize {
    var cols = visibleCols(key) + 3;
    for (labels, 0..) |label, i| {
        if (only_active and i != active) continue;
        cols += visibleCols(label) + 2 + @as(usize, if (i == active) 2 else 0);
    }
    return cols;
}

fn drawModeGroup(
    w: *std.Io.Writer,
    th: theme_mod.Theme,
    state: *State,
    x: usize,
    key: []const u8,
    labels: []const []const u8,
    active: usize,
    only_active: bool,
    is_scope: bool,
) !usize {
    try w.print("{s}{s}{s}   ", .{ th.dim, key, th.reset });
    var at = x + visibleCols(key) + 3;
    for (labels, 0..) |label, i| {
        if (only_active and i != active) continue;
        const width = visibleCols(label) + @as(usize, if (i == active) 2 else 0);
        if (i == active) {
            try w.print("{s} {s} {s}", .{ th.highlight, label, th.reset });
        } else {
            try w.print("{s}{s}{s}", .{ th.dim, label, th.reset });
        }
        try w.writeAll("  ");
        if (state.mode_hit_len < MAX_MODE_HITS) {
            const target: @FieldType(ModeHit, "target") = if (is_scope)
                .{ .scope = Scope.byName(label) }
            else
                .{ .filter = std.meta.stringToEnum(api.Filter, label) orelse .all };
            state.mode_hits[state.mode_hit_len] = .{ .x = at, .w = width, .target = target };
            state.mode_hit_len += 1;
        }
        at += width + 2;
    }
    return at;
}

fn drawModeLine(w: *std.Io.Writer, th: theme_mod.Theme, inner: usize, state: *State) !void {
    const scopes = [_][]const u8{ "both", "youtube", "library" };
    const scope_idx: usize = switch (state.scope) {
        .both => 0,
        .youtube => 1,
        .library => 2,
    };

    const yt_filters = [_][]const u8{ "all", "songs", "videos", "albums", "artists" };
    const lib_filters = [_][]const u8{ "all", "songs", "albums", "artists" };
    const filters: []const []const u8 = if (state.scope == .library) &lib_filters else &yt_filters;
    var filter_idx: usize = 0;
    for (filters, 0..) |label, i| {
        if (std.mem.eql(u8, label, state.filter.label())) filter_idx = i;
    }

    const lead: usize = 2;
    const gap: usize = 3;
    const full = lead + modeGroupCols("^E", &scopes, scope_idx, false) + gap +
        modeGroupCols("^T", filters, filter_idx, false);
    const only_active = full > inner;
    const used = if (only_active)
        lead + modeGroupCols("^E", &scopes, scope_idx, true) + gap +
            modeGroupCols("^T", filters, filter_idx, true)
    else
        full;

    try w.print("{s}│{s}  ", .{ th.accent, th.reset });
    state.mode_hit_len = 0;
    const after = try drawModeGroup(w, th, state, 1 + lead, "^E", &scopes, scope_idx, only_active, true);
    try w.writeAll("   ");
    _ = try drawModeGroup(w, th, state, after + gap, "^T", filters, filter_idx, only_active, false);

    try w.splatByteAll(' ', inner -| used);
    try w.print("{s}│{s}\r\n", .{ th.accent, th.reset });
}

const RowOpts = struct { dim: bool = false };

fn boxTop(w: *std.Io.Writer, th: theme_mod.Theme, inner: usize, label: []const u8) !void {
    const shown = truncateCols(label, inner -| 1);
    try w.print("{s}╭─{s}{s}{s}{s}", .{ th.accent, th.accent_strong, shown, th.reset, th.accent });
    try w.splatBytesAll("─", (inner + 1) -| (2 + visibleCols(shown)));
    try w.print("╮{s}\r\n", .{th.reset});
}

fn boxBottom(w: *std.Io.Writer, th: theme_mod.Theme, inner: usize) !void {
    try w.print("{s}╰", .{th.accent});
    try w.splatBytesAll("─", inner);
    try w.print("╯{s}\r\n", .{th.reset});
}

fn blankRows(w: *std.Io.Writer, th: theme_mod.Theme, inner: usize, n: usize) !void {
    for (0..n) |_| try drawRow(w, th, inner, "", .{});
}

fn drawRow(w: *std.Io.Writer, th: theme_mod.Theme, inner: usize, text: []const u8, opts: RowOpts) !void {
    const t = truncateCols(text, inner -| 2);
    try w.print("{s}│{s} ", .{ th.accent, th.reset });
    if (opts.dim) try w.writeAll(th.dim);
    try w.writeAll(t);
    if (opts.dim) try w.writeAll(th.reset);
    const used = 1 + visibleCols(t);
    try w.splatByteAll(' ', inner -| used);
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

    try w.splatByteAll(' ', room -| used);
    try w.print("{s}│{s}\r\n", .{ th.accent, th.reset });
}

fn popCodepoint(buf: *std.ArrayList(u8)) void {
    if (buf.items.len == 0) return;
    var n: usize = 1;
    while (n <= buf.items.len) : (n += 1) {
        if ((buf.items[buf.items.len - n] & 0xC0) != 0x80) break;
    }
    buf.shrinkRetainingCapacity(buf.items.len - @min(n, buf.items.len));
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
    const total = pls.len + state.local_hits.len + state.suggestions.len;
    if (total == 0) {
        try drawRow(w, th, inner, "  (no suggestions yet — keep typing)", .{ .dim = true });
        try blankRows(w, th, inner, rows -| 1);
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
        } else if (idx < pls.len + state.local_hits.len) {
            const t = state.local_hits[idx - pls.len];
            var row_buf: [512]u8 = undefined;
            const label = std.fmt.bufPrint(&row_buf, "{s}  — {s}", .{ t.title, t.artist }) catch t.title;
            try drawListRow(w, th, inner, label, " [local]", selected);
        } else {
            try drawListRow(w, th, inner, state.suggestions[idx - pls.len - state.local_hits.len], "", selected);
        }
    }
    try blankRows(w, th, inner, rows - (end - start));
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

    try w.splatByteAll(' ', room -| (2 + visibleCols(text) + tag_cols));
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
    try blankRows(w, th, inner, rows -| drawn);
}

fn drawResults(w: *std.Io.Writer, th: theme_mod.Theme, inner: usize, rows: usize, state: *State) !void {
    if (state.tracks.len == 0) {
        try blankRows(w, th, inner, rows);
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

        var dur_buf: [16]u8 = undefined;
        const dur_text: []const u8 = if (t.duration_s > 0)
            fmtTime(&dur_buf, @floatFromInt(t.duration_s))
        else
            "";
        const dur_cols: usize = if (remaining > 40) 9 else 0;

        const text_room = remaining -| kind_cols -| dur_cols;
        const fit = fitTitleArtist(t.title, t.artist, text_room, sep_cols);

        if (selected) try w.writeAll(th.highlight);
        try w.writeAll(mark);
        if (!selected) try w.writeAll(th.bold);
        try w.writeAll(fit.title);
        if (!selected) try w.writeAll(th.reset);
        try w.writeAll(if (selected) th.highlight else th.dim);
        try w.writeAll(sep);
        try w.writeAll(fit.artist);
        try w.writeAll(th.reset);

        try w.splatByteAll(' ', text_room -| fit.cols);

        if (dur_cols > 0) {
            var dpad = dur_cols -| visibleCols(dur_text);
            while (dpad > 0) : (dpad -= 1) try w.writeByte(' ');
            try w.print("{s}{s}{s}", .{ th.dim, dur_text, th.reset });
        }

        try w.print("{s}{s}{s}", .{ th.dim, kind_tag, th.reset });

        try w.print("{s}│{s}\r\n", .{ th.accent, th.reset });
    }
    try blankRows(w, th, inner, rows - (end - start));
}

const TitleArtist = struct { title: []const u8, artist: []const u8, cols: usize };

fn fitTitleArtist(title: []const u8, artist: []const u8, room: usize, sep_cols: usize) TitleArtist {
    const budget = if (room > sep_cols + 4) (room * 2) / 3 else room;
    const t = truncateCols(title, budget);
    const t_cols = visibleCols(t);
    const a = truncateCols(artist, room -| t_cols -| sep_cols);
    return .{ .title = t, .artist = a, .cols = t_cols + sep_cols + visibleCols(a) };
}

fn kindShort(k: []const u8) []const u8 {
    if (std.mem.eql(u8, k, "Song")) return "song";
    if (std.mem.eql(u8, k, "Video")) return "video";
    if (std.mem.eql(u8, k, "Album")) return "album";
    if (std.mem.eql(u8, k, "Artist")) return "artist";
    if (std.mem.eql(u8, k, "Episode")) return "ep";
    if (std.mem.eql(u8, k, "Playlist")) return "list";
    if (std.mem.eql(u8, k, "Feed")) return "feed";
    return k;
}

const BAR_CHARS = [_][]const u8{ " ", "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█" };

fn drawNowPlaying(w: *std.Io.Writer, th: theme_mod.Theme, inner: usize, state: *State, rows: usize, with_bars: bool) !void {
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
    try boxTop(w, th, inner, label);

    {
        try w.print("{s}│{s} ", .{ th.accent, th.reset });
        const room = inner -| 1;
        const sep = "  — ";
        const fit = fitTitleArtist(t.title, t.artist, room, visibleCols(sep));
        try w.print("{s}{s}{s}", .{ th.bold, fit.title, th.reset });
        try w.print("{s}{s}{s}{s}", .{ th.dim, sep, fit.artist, th.reset });
        try w.splatByteAll(' ', room -| fit.cols);
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
        state.np_bar_cols = bar_room;
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

    const show_bars = with_bars and rows >= 6;
    const show_next = if (with_bars) rows >= 6 else rows >= 5;

    if (show_bars) {
        try w.print("{s}│{s} ", .{ th.accent, th.reset });
        const room = inner -| 1;
        const idle = paused or connecting or pl.isMuted();
        const rms = if (idle) 0 else pl.rmsLevel();
        try drawBars(w, th, room, state.tick, idle, rms);
        try w.print("{s}│{s}\r\n", .{ th.accent, th.reset });
    }

    if (show_next) {
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
            const fit = fitTitleArtist(nt.title, nt.artist, text_room, visibleCols(sep));
            try w.writeAll(fit.title);
            try w.print("{s}{s}{s}{s}", .{ th.dim, sep, fit.artist, th.reset });
            used_n += fit.cols;
        } else {
            const msg = "queue end · esc back to search for more";
            const shown = truncateCols(msg, text_room);
            try w.print("{s}{s}{s}", .{ th.dim, shown, th.reset });
            used_n += visibleCols(shown);
        }
        try w.splatByteAll(' ', room -| used_n);
        try w.print("{s}│{s}\r\n", .{ th.accent, th.reset });
    }

    try boxBottom(w, th, inner);
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
    try w.splatByteAll(' ', room -| bars);
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
    const restore = MOUSE_OFF ++ PASTE_OFF ++ "\x1b[?25h\x1b[?1049l";
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
    raw.cc[@backingInt(posix.V.MIN)] = 1;
    raw.cc[@backingInt(posix.V.TIME)] = 0;
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

test "column math survives invalid UTF-8 (latin-1 from suggest endpoint)" {
    const bad = "mot\xfcrhead";
    try testing.expectEqual(@as(usize, 9), visibleCols(bad));
    try testing.expectEqualStrings("mot", truncateCols(bad, 3));
    try testing.expectEqual(@as(usize, 4), visibleCols(truncateCols(bad, 4)));
    try testing.expectEqual(@as(usize, 4), visibleCols(tailCols(bad, 4)));

    const lone_lead = "ab\xf0";
    try testing.expectEqual(@as(usize, 3), visibleCols(lone_lead));
    const stray_cont = "\x80\xbfok";
    try testing.expectEqual(@as(usize, 4), visibleCols(stray_cont));
    const truncated_wide = "\xe6\xbc";
    try testing.expectEqual(@as(usize, 2), visibleCols(truncated_wide));
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
    try testing.expect(selectedSuggestion(&st) == null);
    st.sel_row = 1;
    try testing.expect(selectedSuggestion(&st) == null);
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
