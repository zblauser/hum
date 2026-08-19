const std = @import("std");

pub const c = @cImport({
    @cInclude("mpv/client.h");
});

pub const Error = error{
    MpvCreate,
    MpvInit,
    MpvLoad,
    OutOfMemory,
};

pub const Event = enum { none, end_file, file_error, started, idle, shutdown };

pub const Player = struct {
    handle: *c.mpv_handle,
    has_track: bool = false,
    /// Set alongside a `.file_error` event. Points at a static libmpv string.
    last_error: []const u8 = "",

    pub fn init() Error!Player {
        const h = c.mpv_create() orelse return error.MpvCreate;
        _ = c.mpv_set_option_string(h, "video", "no");
        _ = c.mpv_set_option_string(h, "ytdl", "no");
        _ = c.mpv_set_option_string(h, "terminal", "no");
        _ = c.mpv_set_option_string(h, "idle", "yes");
        _ = c.mpv_set_option_string(h, "msg-level", "all=no");
        _ = c.mpv_set_option_string(h, "audio-display", "no");

        _ = c.mpv_set_option_string(h, "input-media-keys", "yes");
        _ = c.mpv_set_option_string(h, "media-controls", "yes");

        _ = c.mpv_set_option_string(h, "af", "@vis:lavfi=[astats=metadata=1:reset=1:length=0.05]");
        _ = c.mpv_set_option_string(h, "volume-max", "100");
        if (c.mpv_initialize(h) < 0) return error.MpvInit;
        return .{ .handle = h };
    }

    pub fn deinit(self: *Player) void {
        c.mpv_terminate_destroy(self.handle);
    }

    pub fn loadUrl(self: *Player, alloc: std.mem.Allocator, url: []const u8) !void {
        const url_z = try alloc.dupeZ(u8, url);
        defer alloc.free(url_z);
        var mode_z = [_:0]u8{ 'r', 'e', 'p', 'l', 'a', 'c', 'e' };
        var argv = [_:null][*c]const u8{ "loadfile", url_z.ptr, &mode_z };
        if (c.mpv_command(self.handle, &argv) < 0) return error.MpvLoad;
        self.has_track = true;
    }

    pub fn stop(self: *Player) void {
        var argv = [_:null][*c]const u8{"stop"};
        _ = c.mpv_command(self.handle, &argv);
        self.has_track = false;
    }

    pub fn togglePause(self: *Player) bool {
        var pause: c_int = 0;
        _ = c.mpv_get_property(self.handle, "pause", c.MPV_FORMAT_FLAG, &pause);
        var new: c_int = if (pause != 0) 0 else 1;
        _ = c.mpv_set_property(self.handle, "pause", c.MPV_FORMAT_FLAG, &new);
        return new != 0;
    }

    pub fn isPaused(self: *Player) bool {
        var pause: c_int = 0;
        _ = c.mpv_get_property(self.handle, "pause", c.MPV_FORMAT_FLAG, &pause);
        return pause != 0;
    }

    pub fn toggleMute(self: *Player) bool {
        var m: c_int = 0;
        _ = c.mpv_get_property(self.handle, "mute", c.MPV_FORMAT_FLAG, &m);
        var new: c_int = if (m != 0) 0 else 1;
        _ = c.mpv_set_property(self.handle, "mute", c.MPV_FORMAT_FLAG, &new);
        return new != 0;
    }

    pub fn isMuted(self: *Player) bool {
        var m: c_int = 0;
        _ = c.mpv_get_property(self.handle, "mute", c.MPV_FORMAT_FLAG, &m);
        return m != 0;
    }

    pub fn seekRelative(self: *Player, seconds: f64) void {
        var buf: [32]u8 = undefined;
        const s = std.fmt.bufPrintZ(&buf, "{d}", .{seconds}) catch return;
        var mode_z = [_:0]u8{ 'r', 'e', 'l', 'a', 't', 'i', 'v', 'e' };
        var argv = [_:null][*c]const u8{ "seek", s.ptr, &mode_z };
        _ = c.mpv_command(self.handle, &argv);
    }

    pub fn timePos(self: *Player) ?f64 {
        var v: f64 = 0;
        if (c.mpv_get_property(self.handle, "time-pos", c.MPV_FORMAT_DOUBLE, &v) < 0) return null;
        return v;
    }

    pub fn volume(self: *Player) f64 {
        var v: f64 = 100;
        _ = c.mpv_get_property(self.handle, "volume", c.MPV_FORMAT_DOUBLE, &v);
        return v;
    }

    pub fn setVolume(self: *Player, v: f64) void {
        var clamped = std.math.clamp(v, 0, 100);
        _ = c.mpv_set_property(self.handle, "volume", c.MPV_FORMAT_DOUBLE, &clamped);
    }

    pub fn nudgeVolume(self: *Player, delta: f64) f64 {
        const v = self.volume() + delta;
        self.setVolume(v);
        return std.math.clamp(v, 0, 100);
    }

    pub fn rmsLevel(self: *Player) f64 {
        var s: [*c]u8 = null;
        const rc = c.mpv_get_property(
            self.handle,
            "af-metadata/vis/lavfi.astats.Overall.RMS_level",
            c.MPV_FORMAT_STRING,
            @ptrCast(&s),
        );
        if (rc < 0) return 0;
        if (s == null) return 0;
        defer c.mpv_free(s);
        const slice = std.mem.span(s);
        const db = std.fmt.parseFloat(f64, slice) catch return 0;
        const clamped = std.math.clamp(db, -60.0, 0.0);
        return std.math.pow(f64, 10.0, clamped / 20.0);
    }

    pub fn duration(self: *Player) ?f64 {
        var v: f64 = 0;
        if (c.mpv_get_property(self.handle, "duration", c.MPV_FORMAT_DOUBLE, &v) < 0) return null;
        return v;
    }

    pub fn pollEvent(self: *Player) Event {
        const ev = c.mpv_wait_event(self.handle, 0);
        return switch (ev.*.event_id) {
            c.MPV_EVENT_NONE => .none,
            c.MPV_EVENT_END_FILE => blk: {
                const ef: *c.mpv_event_end_file = @ptrCast(@alignCast(ev.*.data));
                if (ef.reason == c.MPV_END_FILE_REASON_EOF) break :blk .end_file;
                // a stream that fails to open ends here; swallowing it left the UI
                // reporting "playing" at 00:00 forever (see issue #6)
                if (ef.reason == c.MPV_END_FILE_REASON_ERROR) {
                    self.has_track = false;
                    self.last_error = std.mem.span(c.mpv_error_string(ef.@"error"));
                    break :blk .file_error;
                }
                break :blk .none;
            },
            c.MPV_EVENT_FILE_LOADED => .started,
            c.MPV_EVENT_IDLE => .idle,
            c.MPV_EVENT_SHUTDOWN => .shutdown,
            else => .none,
        };
    }
};
