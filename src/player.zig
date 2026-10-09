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

pub const Player = struct {
    m: *const mpv.Api,
    handle: *mpv.Handle,
    has_track: bool = false,
    last_error: []const u8 = "",

    pub fn init() Error!Player {
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

        _ = m.set_option_string(h, "af", "@vis:lavfi=[astats=metadata=1:reset=1:length=0.05]");
        _ = m.set_option_string(h, "volume-max", "100");
        if (m.initialize(h) < 0) {
            m.terminate_destroy(h);
            return error.MpvInit;
        }
        return .{ .m = m, .handle = h };
    }

    pub fn deinit(self: *Player) void {
        self.m.terminate_destroy(self.handle);
    }

    pub fn loadUrl(self: *Player, alloc: std.mem.Allocator, url: []const u8, title: []const u8) !void {
        const url_z = try alloc.dupeSentinel(u8, url, 0);
        defer alloc.free(url_z);
        const title_z = try alloc.dupeSentinel(u8, title, 0);
        defer alloc.free(title_z);
        _ = self.m.set_property_string(self.handle, "force-media-title", title_z);
        const argv = [_:null]?[*:0]const u8{ "loadfile", url_z.ptr, "replace" };
        if (self.m.command(self.handle, &argv) < 0) return error.MpvLoad;
        self.has_track = true;
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

    pub fn rmsLevel(self: *Player) f64 {
        const db = self.stat("Overall.RMS_level") orelse return 0;
        return std.math.pow(f64, 10.0, std.math.clamp(db, -60.0, 0.0) / 20.0);
    }

    pub const Levels = struct { level: f32, left: f32, right: f32, bright: f32 };

    pub fn levels(self: *Player) Levels {
        const overall = self.stat("Overall.RMS_level") orelse return .{ .level = 0, .left = 0, .right = 0, .bright = 0 };
        const left = self.stat("1.RMS_level") orelse overall;
        const right = self.stat("2.RMS_level") orelse left;
        const zcr = self.stat("1.Zero_crossings_rate") orelse 0;
        return .{
            .level = dbNorm(overall),
            .left = dbNorm(left),
            .right = dbNorm(right),
            .bright = @floatCast(std.math.clamp(@sqrt(@max(zcr, 0) / 0.15), 0, 1)),
        };
    }

    fn dbNorm(db: f64) f32 {
        return @floatCast(std.math.clamp((db + 50.0) / 40.0, 0, 1));
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
