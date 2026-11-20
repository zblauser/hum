const std = @import("std");

const mpv = @import("mpv.zig");

pub const Error = error{
    MpvMissing,
    MpvCreate,
    MpvInit,
    MpvLoad,
    OutOfMemory,
};

pub const Event = enum { none, end_file, file_error, started, audio_ready, idle, shutdown };

pub const BANDS = 16;

const VIS_AF = blk: {
    var split: []const u8 = "";
    var chains: []const u8 = "";
    var merge: []const u8 = "[o]";
    for (0..BANDS) |i| {
        const f = 45.0 * @exp2(@as(f64, @floatFromInt(i)) / 2.0);
        const bp = std.fmt.comptimePrint("bandpass=f={d:.0}:width_type=o:w=0.5", .{f});
        split = split ++ std.fmt.comptimePrint("[s{d}]", .{i});
        chains = chains ++ std.fmt.comptimePrint("[s{d}]{s},{s}[b{d}];", .{ i, bp, bp, i });
        merge = merge ++ std.fmt.comptimePrint("[b{d}]", .{i});
    }
    const graph = "aformat=channel_layouts=stereo,asplit=2[o][m];[m]pan=mono|c0=0.5*c0+0.5*c1,asplit=" ++
        std.fmt.comptimePrint("{d}", .{BANDS}) ++ split ++ ";" ++ chains ++ merge ++
        std.fmt.comptimePrint("amerge=inputs={d}", .{BANDS + 1}) ++
        ",astats=metadata=1:reset=1:length=0.05:measure_perchannel=RMS_level+Zero_crossings_rate:measure_overall=none,pan=stereo|c0=c0|c1=c1";
    break :blk std.fmt.comptimePrint("@vis:lavfi=%{d}%{s}", .{ graph.len, graph });
};

const BASIC_AF = "@vis:lavfi=[astats=metadata=1:reset=1:length=0.05]";

fn spectrumReady(version: []const u8) bool {
    if (std.mem.startsWith(u8, version, "N-")) return true;
    var it = std.mem.tokenizeAny(u8, std.mem.trimStart(u8, version, "n"), ".-~+ ");
    const major = std.fmt.parseInt(u32, it.next() orelse return false, 10) catch return false;
    const minor = std.fmt.parseInt(u32, it.next() orelse "0", 10) catch 0;
    return major > 4 or (major == 4 and minor >= 4);
}

test "the spectrum graph needs ffmpeg 4.4 or a git build" {
    for ([_][]const u8{ "6.1.1", "n7.0", "4.4.2-0ubuntu0.22.04.1", "N-112345-gdeadbeef", "8.0" }) |v| try std.testing.expect(spectrumReady(v));
    for ([_][]const u8{ "4.3.6-0+deb11u1", "n4.2", "3.4.11", "", "git-2020" }) |v| try std.testing.expect(!spectrumReady(v));
}

pub const Player = struct {
    m: *const mpv.Api,
    handle: *mpv.Handle,
    has_track: bool = false,
    last_error: []const u8 = "",

    pub const Options = struct { gapless: bool = true, replaygain: [:0]const u8 = "no" };

    pub fn init(opts: Options) Error!Player {
        const m = try mpv.load();
        const h = m.create() orelse return error.MpvCreate;
        _ = m.set_option_string(h, "video", "no");
        _ = m.set_option_string(h, "ytdl", "no");
        _ = m.set_option_string(h, "terminal", "no");
        _ = m.set_option_string(h, "idle", "yes");
        _ = m.set_option_string(h, "msg-level", "all=no");
        _ = m.set_option_string(h, "audio-display", "no");

        _ = m.set_option_string(h, "input-media-keys", "yes");
        _ = m.set_option_string(h, "media-controls", "yes");
        var plugin_buf: [512]u8 = undefined;
        if (mpv.mprisPlugin(&plugin_buf)) |plugin| _ = m.set_option_string(h, "scripts", plugin);

        _ = m.set_option_string(h, "volume-max", "100");
        _ = m.set_option_string(h, "gapless-audio", if (opts.gapless) "weak" else "no");
        _ = m.set_option_string(h, "prefetch-playlist", if (opts.gapless) "yes" else "no");
        _ = m.set_option_string(h, "replaygain", opts.replaygain);
        if (m.initialize(h) < 0) {
            m.terminate_destroy(h);
            return error.MpvInit;
        }
        var ver: ?[*:0]u8 = null;
        const known = m.get_property(h, "ffmpeg-version", mpv.FORMAT_STRING, @ptrCast(&ver)) >= 0 and ver != null;
        defer if (known) m.free(ver.?);
        _ = m.set_property_string(h, "af", if (known and spectrumReady(std.mem.span(ver.?))) VIS_AF else BASIC_AF);
        return .{ .m = m, .handle = h };
    }

    pub fn deinit(self: *Player) void {
        self.m.terminate_destroy(self.handle);
    }

    pub fn loadUrl(self: *Player, alloc: std.mem.Allocator, url: []const u8, title: []const u8) !void {
        try self.setTitle(alloc, title);
        try self.loadfile(alloc, url, "replace");
        self.has_track = true;
    }

    pub fn appendUrl(self: *Player, alloc: std.mem.Allocator, url: []const u8) !void {
        try self.loadfile(alloc, url, "append");
    }

    pub fn dropUpcoming(self: *Player) void {
        const argv = [_:null]?[*:0]const u8{"playlist-clear"};
        _ = self.m.command(self.handle, &argv);
    }

    pub fn setTitle(self: *Player, alloc: std.mem.Allocator, title: []const u8) !void {
        const title_z = try alloc.dupeSentinel(u8, title, 0);
        defer alloc.free(title_z);
        _ = self.m.set_property_string(self.handle, "force-media-title", title_z);
    }

    fn loadfile(self: *Player, alloc: std.mem.Allocator, url: []const u8, how: [*:0]const u8) !void {
        const url_z = try alloc.dupeSentinel(u8, url, 0);
        defer alloc.free(url_z);
        const argv = [_:null]?[*:0]const u8{ "loadfile", url_z.ptr, how };
        if (self.m.command(self.handle, &argv) < 0) return error.MpvLoad;
    }

    pub fn stop(self: *Player) void {
        const argv = [_:null]?[*:0]const u8{"stop"};
        _ = self.m.command(self.handle, &argv);
        self.has_track = false;
    }

    pub fn togglePause(self: *Player) bool {
        var pause: c_int = 0;
        _ = self.m.get_property(self.handle, "pause", mpv.FORMAT_FLAG, &pause);
        var new: c_int = if (pause != 0) 0 else 1;
        _ = self.m.set_property(self.handle, "pause", mpv.FORMAT_FLAG, &new);
        return new != 0;
    }

    pub fn isPaused(self: *Player) bool {
        var pause: c_int = 0;
        _ = self.m.get_property(self.handle, "pause", mpv.FORMAT_FLAG, &pause);
        return pause != 0;
    }

    pub fn toggleMute(self: *Player) bool {
        var m: c_int = 0;
        _ = self.m.get_property(self.handle, "mute", mpv.FORMAT_FLAG, &m);
        var new: c_int = if (m != 0) 0 else 1;
        _ = self.m.set_property(self.handle, "mute", mpv.FORMAT_FLAG, &new);
        return new != 0;
    }

    pub fn isMuted(self: *Player) bool {
        var m: c_int = 0;
        _ = self.m.get_property(self.handle, "mute", mpv.FORMAT_FLAG, &m);
        return m != 0;
    }

    pub fn seekRelative(self: *Player, seconds: f64) void {
        var buf: [32]u8 = undefined;
        const s = std.fmt.bufPrintSentinel(&buf, "{d}", .{seconds}, 0) catch return;
        const argv = [_:null]?[*:0]const u8{ "seek", s.ptr, "relative" };
        _ = self.m.command(self.handle, &argv);
    }

    pub fn seekPercent(self: *Player, pct: f64) void {
        var buf: [32]u8 = undefined;
        const s = std.fmt.bufPrintSentinel(&buf, "{d:.2}", .{std.math.clamp(pct, 0, 100)}, 0) catch return;
        const argv = [_:null]?[*:0]const u8{ "seek", s.ptr, "absolute-percent" };
        _ = self.m.command(self.handle, &argv);
    }

    pub fn timePos(self: *Player) ?f64 {
        var v: f64 = 0;
        if (self.m.get_property(self.handle, "time-pos", mpv.FORMAT_DOUBLE, &v) < 0) return null;
        return v;
    }

    pub fn volume(self: *Player) f64 {
        var v: f64 = 100;
        _ = self.m.get_property(self.handle, "volume", mpv.FORMAT_DOUBLE, &v);
        return v;
    }

    pub fn setVolume(self: *Player, v: f64) void {
        var clamped = std.math.clamp(v, 0, 100);
        _ = self.m.set_property(self.handle, "volume", mpv.FORMAT_DOUBLE, &clamped);
    }

    pub fn nudgeVolume(self: *Player, delta: f64) f64 {
        const v = self.volume() + delta;
        self.setVolume(v);
        return std.math.clamp(v, 0, 100);
    }

    pub const Levels = struct { level: f32 = 0, left: f32 = 0, right: f32 = 0, bright: f32 = 0, bands: [BANDS]f32 = @splat(0) };

    pub fn levels(self: *Player) Levels {
        const left = self.stat("1.RMS_level") orelse return .{};
        const right = self.stat("2.RMS_level") orelse left;
        const zcr = self.stat("1.Zero_crossings_rate") orelse 0;
        const power = (std.math.pow(f64, 10, left / 10) + std.math.pow(f64, 10, right / 10)) / 2;
        var out: Levels = .{
            .level = dbNorm(10 * @log10(@max(power, 1e-12)), 50, 40),
            .left = dbNorm(left, 50, 40),
            .right = dbNorm(right, 50, 40),
            .bright = @floatCast(std.math.clamp(@sqrt(@max(zcr, 0) / 0.15), 0, 1)),
        };
        inline for (0..BANDS) |i| {
            const db = self.stat(std.fmt.comptimePrint("{d}.RMS_level", .{i + 3})) orelse -120;
            out.bands[i] = dbNorm(db + @as(f64, @floatFromInt(i)) * 0.8, 44, 34);
        }
        return out;
    }

    fn dbNorm(db: f64, floor: f64, range: f64) f32 {
        return @floatCast(std.math.clamp((db + floor) / range, 0, 1));
    }

    fn stat(self: *Player, comptime key: []const u8) ?f64 {
        var s: ?[*:0]u8 = null;
        const rc = self.m.get_property(self.handle, "af-metadata/vis/lavfi.astats." ++ key, mpv.FORMAT_STRING, @ptrCast(&s));
        if (rc < 0) return null;
        const str = s orelse return null;
        defer self.m.free(str);
        const v = std.fmt.parseFloat(f64, std.mem.span(str)) catch return null;
        return if (std.math.isFinite(v)) v else null;
    }

    pub fn duration(self: *Player) ?f64 {
        var v: f64 = 0;
        if (self.m.get_property(self.handle, "duration", mpv.FORMAT_DOUBLE, &v) < 0) return null;
        return v;
    }

    pub fn pollEvent(self: *Player) Event {
        const ev = self.m.wait_event(self.handle, 0);
        return switch (ev.event_id) {
            mpv.EVENT_NONE => .none,
            mpv.EVENT_END_FILE => blk: {
                const ef: *const mpv.EndFile = @ptrCast(@alignCast(ev.data orelse break :blk .none));
                if (ef.reason == mpv.END_FILE_REASON_EOF) break :blk .end_file;
                if (ef.reason == mpv.END_FILE_REASON_ERROR) {
                    self.has_track = false;
                    self.last_error = std.mem.span(self.m.error_string(ef.@"error"));
                    break :blk .file_error;
                }
                break :blk .none;
            },
            mpv.EVENT_FILE_LOADED => .started,
            mpv.EVENT_AUDIO_RECONFIG => .audio_ready,
            mpv.EVENT_IDLE => .idle,
            mpv.EVENT_SHUTDOWN => .shutdown,
            else => .none,
        };
    }
};
