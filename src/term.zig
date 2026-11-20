const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

pub const windows = builtin.os.tag == .windows;

const w = struct {
    const HANDLE = *anyopaque;
    const BOOL = c_int;
    const INFINITE: u32 = 0xFFFF_FFFF;
    const KEY_EVENT: u16 = 1;
    const UTF8: u32 = 65001;
    const IN_RAW: u32 = 0x0200 | 0x0080;
    const OUT_VT: u32 = 0x0001 | 0x0004;
    const BROKEN_PIPE: u32 = 109;
    const NO_DATA: u32 = 232;

    const Coord = extern struct { x: i16, y: i16 };
    const Rect = extern struct { left: i16, top: i16, right: i16, bottom: i16 };
    const BufferInfo = extern struct { size: Coord, cursor: Coord, attrs: u16, window: Rect, max: Coord };
    const KeyEvent = extern struct { down: BOOL, repeat: u16, vkey: u16, vscan: u16, char: u16, state: u32 };
    const Record = extern struct { kind: u16, ev: extern union { key: KeyEvent, raw: [16]u8 } };

    extern "kernel32" fn GetStdHandle(u32) callconv(.winapi) ?HANDLE;
    extern "kernel32" fn GetConsoleMode(HANDLE, *u32) callconv(.winapi) BOOL;
    extern "kernel32" fn SetConsoleMode(HANDLE, u32) callconv(.winapi) BOOL;
    extern "kernel32" fn GetConsoleOutputCP() callconv(.winapi) u32;
    extern "kernel32" fn SetConsoleOutputCP(u32) callconv(.winapi) BOOL;
    extern "kernel32" fn GetConsoleScreenBufferInfo(HANDLE, *BufferInfo) callconv(.winapi) BOOL;
    extern "kernel32" fn WaitForSingleObject(HANDLE, u32) callconv(.winapi) u32;
    extern "kernel32" fn ReadConsoleInputW(HANDLE, [*]Record, u32, *u32) callconv(.winapi) BOOL;
    extern "kernel32" fn WriteFile(HANDLE, [*]const u8, u32, ?*u32, ?*anyopaque) callconv(.winapi) BOOL;
    extern "kernel32" fn GetLastError() callconv(.winapi) u32;
    extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;

    fn in() ?HANDLE {
        return GetStdHandle(@bitCast(@as(i32, -10)));
    }
    fn out() ?HANDLE {
        return GetStdHandle(@bitCast(@as(i32, -11)));
    }
};

pub const Saved = if (windows) struct { in: u32, out: u32 } else posix.termios;

pub fn enterRaw() !Saved {
    if (windows) {
        const in = w.in() orelse return error.NotATerminal;
        const out = w.out() orelse return error.NotATerminal;
        var s: Saved = .{ .in = 0, .out = 0 };
        if (w.GetConsoleMode(in, &s.in) == 0 or w.GetConsoleMode(out, &s.out) == 0) return error.NotATerminal;
        if (w.SetConsoleMode(in, w.IN_RAW) == 0) return error.NotATerminal;
        if (w.SetConsoleMode(out, s.out | w.OUT_VT) == 0) {
            _ = w.SetConsoleMode(in, s.in);
            return error.NoVirtualTerminal;
        }
        return s;
    }
    const orig = try posix.tcgetattr(0);
    var raw = orig;
    raw.lflag.ICANON = false;
    raw.lflag.ECHO = false;
    raw.lflag.IEXTEN = false;
    raw.iflag.IXON = false;
    raw.iflag.ICRNL = false;
    raw.cc[@backingInt(posix.V.MIN)] = 1;
    raw.cc[@backingInt(posix.V.TIME)] = 0;
    try posix.tcsetattr(0, .NOW, raw);
    saved_tty = orig;
    return orig;
}

pub fn restore(s: Saved) void {
    if (windows) {
        if (w.in()) |h| _ = w.SetConsoleMode(h, s.in);
        if (w.out()) |h| _ = w.SetConsoleMode(h, s.out);
        return;
    }
    posix.tcsetattr(0, .NOW, s) catch {};
}

var saved_tty: ?Saved = null;

pub fn exitOnInterrupt(comptime seq: []const u8) void {
    if (windows) return;
    const H = struct {
        fn on(_: posix.SIG) callconv(.c) void {
            _ = std.c.write(1, seq.ptr, seq.len);
            if (saved_tty) |t| posix.tcsetattr(0, .NOW, t) catch {};
            std.c._exit(130);
        }
    };
    const act = posix.Sigaction{ .handler = .{ .handler = H.on }, .mask = posix.sigemptyset(), .flags = 0 };
    posix.sigaction(posix.SIG.INT, &act, null);
    posix.sigaction(posix.SIG.TERM, &act, null);
}

pub fn utf8Output() u32 {
    if (!windows) return 0;
    const cp = w.GetConsoleOutputCP();
    _ = w.SetConsoleOutputCP(w.UTF8);
    return cp;
}

pub fn restoreOutput(cp: u32) void {
    if (windows and cp != 0) _ = w.SetConsoleOutputCP(cp);
}

pub const Size = struct { cols: usize, rows: usize };

pub fn size() Size {
    if (windows) {
        var info: w.BufferInfo = undefined;
        const h = w.out() orelse return .{ .cols = 80, .rows = 24 };
        if (w.GetConsoleScreenBufferInfo(h, &info) == 0) return .{ .cols = 80, .rows = 24 };
        const cols = @as(i32, info.window.right) - info.window.left + 1;
        const rows = @as(i32, info.window.bottom) - info.window.top + 1;
        return .{ .cols = if (cols > 0) @intCast(cols) else 80, .rows = if (rows > 0) @intCast(rows) else 24 };
    }
    var ws: posix.winsize = undefined;
    const req: c_int = @bitCast(@as(c_uint, @intCast(std.c.T.IOCGWINSZ)));
    if (std.c.ioctl(1, req, &ws) == 0 and ws.col > 0) {
        return .{ .cols = @intCast(ws.col), .rows = if (ws.row > 0) @intCast(ws.row) else 24 };
    }
    return .{ .cols = 80, .rows = 24 };
}

pub fn writeAll(bytes: []const u8) !void {
    var i: usize = 0;
    while (i < bytes.len) {
        if (windows) {
            const h = w.out() orelse return error.WriteFailed;
            var n: u32 = 0;
            const want: u32 = @intCast(@min(bytes.len - i, 1 << 20));
            if (w.WriteFile(h, bytes[i..].ptr, want, &n, null) == 0) {
                const e = w.GetLastError();
                return if (e == w.BROKEN_PIPE or e == w.NO_DATA) error.BrokenPipe else error.WriteFailed;
            }
            if (n == 0) return error.WriteFailed;
            i += n;
            continue;
        }
        const n = std.c.write(1, bytes[i..].ptr, bytes.len - i);
        if (n < 0) return if (std.c._errno().* == @backingInt(std.c.E.PIPE)) error.BrokenPipe else error.WriteFailed;
        if (n == 0) return error.WriteFailed;
        i += @intCast(n);
    }
}

pub fn waitInput(timeout_ms: i32) !bool {
    if (windows) return winWait(timeout_ms);
    var fds = [_]posix.pollfd{.{ .fd = 0, .events = posix.POLL.IN, .revents = 0 }};
    const n = try posix.poll(&fds, timeout_ms);
    return n > 0 and (fds[0].revents & posix.POLL.IN) != 0;
}

pub fn read(buf: []u8) !usize {
    if (windows) {
        while (!winWait(-1)) {}
        const n = @min(buf.len, pend_len - pend_head);
        @memcpy(buf[0..n], pend[pend_head..][0..n]);
        pend_head += n;
        return n;
    }
    return posix.read(0, buf);
}

var pend: [512]u8 = undefined;
var pend_head: usize = 0;
var pend_len: usize = 0;
var high_surrogate: u16 = 0;

fn winWait(ms: i32) bool {
    if (pend_head < pend_len) return true;
    const in = w.in() orelse return false;
    const t0 = w.GetTickCount64();
    while (true) {
        const spent = w.GetTickCount64() - t0;
        const budget: u64 = if (ms < 0) w.INFINITE else @intCast(ms);
        const left: u32 = if (ms < 0) w.INFINITE else @intCast(budget -| spent);
        if (w.WaitForSingleObject(in, left) != 0) return false;
        if (pump(in)) return true;
        if (ms >= 0 and spent >= budget) return false;
    }
}

fn pump(in: w.HANDLE) bool {
    pend_head = 0;
    pend_len = 0;
    var recs: [32]w.Record = undefined;
    var n: u32 = 0;
    if (w.ReadConsoleInputW(in, &recs, recs.len, &n) == 0) return false;
    for (recs[0..n]) |r| {
        if (r.kind != w.KEY_EVENT or r.ev.key.down == 0 or r.ev.key.char == 0) continue;
        for (0..@max(r.ev.key.repeat, 1)) |_| push(r.ev.key.char);
    }
    return pend_len > 0;
}

fn push(unit: u16) void {
    var cp: u21 = unit;
    if (std.unicode.utf16IsHighSurrogate(unit)) {
        high_surrogate = unit;
        return;
    }
    if (std.unicode.utf16IsLowSurrogate(unit)) {
        if (high_surrogate == 0) return;
        cp = std.unicode.utf16DecodeSurrogatePair(&.{ high_surrogate, unit }) catch return;
    }
    high_surrogate = 0;
    if (pend_len + 4 > pend.len) return;
    pend_len += std.unicode.utf8Encode(cp, pend[pend_len..]) catch 0;
}
