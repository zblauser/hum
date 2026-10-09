const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");

pub const Handle = opaque {};

pub const FORMAT_STRING: c_int = 1;
pub const FORMAT_FLAG: c_int = 3;
pub const FORMAT_DOUBLE: c_int = 5;

pub const EVENT_NONE: c_int = 0;
pub const EVENT_SHUTDOWN: c_int = 1;
pub const EVENT_END_FILE: c_int = 7;
pub const EVENT_FILE_LOADED: c_int = 8;
pub const EVENT_IDLE: c_int = 11;
pub const EVENT_AUDIO_RECONFIG: c_int = 18;

pub const END_FILE_REASON_EOF: c_int = 0;
pub const END_FILE_REASON_ERROR: c_int = 4;

pub const Event = extern struct {
    event_id: c_int,
    @"error": c_int,
    reply_userdata: u64,
    data: ?*anyopaque,
};

pub const EndFile = extern struct {
    reason: c_int,
    @"error": c_int,
};

pub const Argv = [*:null]const ?[*:0]const u8;

pub const Api = struct {
    create: *const fn () callconv(.c) ?*Handle,
    set_option_string: *const fn (*Handle, [*:0]const u8, [*:0]const u8) callconv(.c) c_int,
    set_property_string: *const fn (*Handle, [*:0]const u8, [*:0]const u8) callconv(.c) c_int,
    initialize: *const fn (*Handle) callconv(.c) c_int,
    terminate_destroy: *const fn (*Handle) callconv(.c) void,
    command: *const fn (*Handle, Argv) callconv(.c) c_int,
    get_property: *const fn (*Handle, [*:0]const u8, c_int, *anyopaque) callconv(.c) c_int,
    set_property: *const fn (*Handle, [*:0]const u8, c_int, *anyopaque) callconv(.c) c_int,
    free: *const fn (?*anyopaque) callconv(.c) void,
    wait_event: *const fn (*Handle, f64) callconv(.c) *Event,
    error_string: *const fn (c_int) callconv(.c) [*:0]const u8,
    client_api_version: *const fn () callconv(.c) c_ulong,
};

pub const Error = error{MpvMissing};

const system_paths = switch (builtin.os.tag) {
    .macos => [_][:0]const u8{
        "/opt/homebrew/lib/libmpv.2.dylib",
        "/usr/local/lib/libmpv.2.dylib",
        "/opt/local/lib/libmpv.2.dylib",
    },
    else => [_][:0]const u8{ "libmpv.so.2", "libmpv.so.1", "/home/linuxbrew/.linuxbrew/lib/libmpv.so.2" },
};

const lib_name = if (builtin.os.tag == .macos) "libmpv.2.dylib" else "libmpv.so.2";

const prefix_path: [:0]const u8 = if (build_options.mpv_prefix.len > 0)
    build_options.mpv_prefix ++ "/lib/" ++ lib_name
else
    "";

var api: Api = undefined;
var loaded: ?[:0]const u8 = null;
var why_buf: [256]u8 = undefined;
var why: []const u8 = "";

pub fn load() Error!*const Api {
    if (loaded != null) return &api;
    const prefixed = [_][:0]const u8{prefix_path};
    for (prefixed ++ system_paths) |path| {
        if (path.len == 0) continue;
        if (tryOpen(path)) |a| {
            api = a;
            loaded = path;
            return &api;
        }
    }
    return error.MpvMissing;
}

pub fn failure() []const u8 {
    return why;
}

pub fn describe(buf: []u8) ?[]const u8 {
    const path = loaded orelse return null;
    const v = api.client_api_version();
    return std.fmt.bufPrint(buf, "{s} (api {d}.{d})", .{ path, v >> 16, v & 0xffff }) catch null;
}

fn tryOpen(path: [:0]const u8) ?Api {
    const lib = std.c.dlopen(path, .{ .LAZY = true, .GLOBAL = true }) orelse {
        const msg = std.mem.span(std.c.dlerror() orelse return null);
        if (std.ascii.findIgnoreCase(msg, "no such file") == null) note("{s}", .{msg});
        return null;
    };
    var out: Api = undefined;
    const info = @typeInfo(Api).@"struct";
    inline for (info.field_names) |name| {
        const sym = std.c.dlsym(lib, "mpv_" ++ name) orelse {
            note("{s}: no mpv_{s}", .{ path, name });
            _ = std.c.dlclose(lib);
            return null;
        };
        @field(out, name) = @ptrCast(@alignCast(sym));
    }
    const major = out.client_api_version() >> 16;
    if (major < 1 or major > 2) {
        note("{s}: client api {d} unsupported", .{ path, major });
        _ = std.c.dlclose(lib);
        return null;
    }
    return out;
}

pub fn mprisPlugin(buf: []u8) ?[:0]const u8 {
    if (builtin.os.tag == .macos) return null;
    const system = [_][:0]const u8{
        "/etc/mpv/scripts/mpris.so",
        "/usr/lib/mpv-mpris/mpris.so",
        "/usr/local/etc/mpv/scripts/mpris.so",
    };
    for (system) |path| {
        if (std.c.access(path, 0) == 0) return path;
    }
    const user = if (std.c.getenv("XDG_CONFIG_HOME")) |x|
        std.fmt.bufPrintSentinel(buf, "{s}/mpv/scripts/mpris.so", .{std.mem.span(x)}, 0)
    else if (std.c.getenv("HOME")) |h|
        std.fmt.bufPrintSentinel(buf, "{s}/.config/mpv/scripts/mpris.so", .{std.mem.span(h)}, 0)
    else
        return null;
    const path = user catch return null;
    return if (std.c.access(path, 0) == 0) path else null;
}

fn note(comptime fmt: []const u8, args: anytype) void {
    why = std.fmt.bufPrint(&why_buf, fmt, args) catch why_buf[0..];
}
