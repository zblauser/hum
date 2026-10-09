const std = @import("std");
const text = @import("text.zig");

pub const Class = enum(u2) { none, dim, accent, strong };

pub const Cell = struct {
    cp: u21 = ' ',
    class: Class = .none,
};

pub const WIDE_TAIL: u21 = 0;

pub const Audio = struct {
    level: f32 = 0,
    left: f32 = 0,
    right: f32 = 0,
    bright: f32 = 0,
    paused: bool = true,
};

pub const builtin_names = [_][]const u8{ "bars", "cube", "orbit", "rings", "plasma" };

const MAX_BARS = 64;

pub const Motion = struct {
    last_tick: u64 = 0,
    ax: f32 = 0.6,
    ay: f32 = 0.2,
    az: f32 = 0,
    orbit: f32 = 0,
    ring: f32 = 0,
    plasma: f32 = 0,
    flip: f32 = 0,
    bar: [MAX_BARS]f32 = @splat(0),
    peak: [MAX_BARS]f32 = @splat(0),
};

pub const Buffers = struct {
    cells: []Cell = &.{},
    dots: []u8 = &.{},
    dot_class: []Class = &.{},

    pub fn canvas(self: *Buffers, gpa: std.mem.Allocator, w: usize, h: usize) !Canvas {
        const n = w * h;
        if (self.cells.len < n) {
            self.deinit(gpa);
            self.cells = try gpa.alloc(Cell, n);
            self.dots = try gpa.alloc(u8, n);
            self.dot_class = try gpa.alloc(Class, n);
        }
        var cv: Canvas = .{ .w = w, .h = h, .cells = self.cells[0..n], .dots = self.dots[0..n], .dot_class = self.dot_class[0..n] };
        cv.clear();
        return cv;
    }

    pub fn deinit(self: *Buffers, gpa: std.mem.Allocator) void {
        gpa.free(self.cells);
        gpa.free(self.dots);
        gpa.free(self.dot_class);
        self.* = .{};
    }
};

pub const Canvas = struct {
    w: usize,
    h: usize,
    cells: []Cell,
    dots: []u8,
    dot_class: []Class,

    fn clear(self: *Canvas) void {
        @memset(self.cells, .{});
        @memset(self.dots, 0);
        @memset(self.dot_class, .none);
    }

    pub fn at(self: *const Canvas, x: usize, y: usize) Cell {
        return self.cells[y * self.w + x];
    }

    fn put(self: *Canvas, x: isize, y: isize, cp: u21, class: Class) void {
        if (x < 0 or y < 0) return;
        const ux: usize = @intCast(x);
        const uy: usize = @intCast(y);
        if (ux >= self.w or uy >= self.h) return;
        self.cells[uy * self.w + ux] = .{ .cp = cp, .class = class };
    }

    const DOT = [4][2]u8{ .{ 0x01, 0x08 }, .{ 0x02, 0x10 }, .{ 0x04, 0x20 }, .{ 0x40, 0x80 } };

    fn dot(self: *Canvas, px: f32, py: f32, class: Class) void {
        if (!(px >= 0 and py >= 0)) return;
        const x: usize = @intFromFloat(px + 0.5);
        const y: usize = @intFromFloat(py + 0.5);
        if (x >= self.w * 2 or y >= self.h * 4) return;
        const i = (y / 4) * self.w + x / 2;
        self.dots[i] |= DOT[y % 4][x % 2];
        if (@backingInt(class) > @backingInt(self.dot_class[i])) self.dot_class[i] = class;
    }

    fn line(self: *Canvas, x0: f32, y0: f32, x1: f32, y1: f32, class: Class) void {
        const span = @max(@abs(x1 - x0), @abs(y1 - y0));
        if (!std.math.isFinite(span)) return;
        const n: usize = @intFromFloat(@min(@max(span, 1), 4096));
        const nf: f32 = @floatFromInt(n);
        var i: usize = 0;
        while (i <= n) : (i += 1) {
            const f: f32 = @as(f32, @floatFromInt(i)) / nf;
            self.dot(x0 + (x1 - x0) * f, y0 + (y1 - y0) * f, class);
        }
    }

    fn flushDots(self: *Canvas) void {
        for (self.dots, 0..) |b, i| {
            if (b != 0) self.cells[i] = .{ .cp = 0x2800 + @as(u21, b), .class = self.dot_class[i] };
        }
    }
};

pub fn count(flipbooks: []const Flipbook) usize {
    return builtin_names.len + flipbooks.len;
}

pub fn name(which: usize, flipbooks: []const Flipbook) []const u8 {
    if (which < builtin_names.len) return builtin_names[which];
    const i = which - builtin_names.len;
    return if (i < flipbooks.len) flipbooks[i].name else builtin_names[0];
}

pub fn indexOf(n: []const u8, flipbooks: []const Flipbook) ?usize {
    for (builtin_names, 0..) |b, i| if (std.mem.eql(u8, b, n)) return i;
    for (flipbooks, 0..) |f, i| if (std.mem.eql(u8, f.name, n)) return builtin_names.len + i;
    return null;
}

pub fn render(cv: *Canvas, which: usize, flipbooks: []const Flipbook, m: *Motion, a: Audio, tick: u64) void {
    const steps: usize = @intCast(@min(tick -% m.last_tick, 4));
    m.last_tick = tick;
    if (cv.w == 0 or cv.h == 0) return;
    switch (which) {
        0 => bars(cv, m, a, tick, steps),
        1 => cube(cv, m, a, steps),
        2 => orbit(cv, m, a, steps),
        3 => rings(cv, m, a, steps),
        4 => plasma(cv, m, a, steps),
        else => {
            const i = which - builtin_names.len;
            if (i < flipbooks.len) flipbook(cv, &flipbooks[i], m, a, steps) else bars(cv, m, a, tick, steps);
        },
    }
}

fn byLevel(v: f32) Class {
    return if (v > 0.66) .strong else if (v > 0.33) .accent else .dim;
}

fn ff(x: usize) f32 {
    return @floatFromInt(x);
}

const PART = [_]u21{ 0x2581, 0x2582, 0x2583, 0x2584, 0x2585, 0x2586, 0x2587 };
const FULL: u21 = 0x2588;
const CAP: u21 = 0x2580;

fn bars(cv: *Canvas, m: *Motion, a: Audio, tick: u64, steps: usize) void {
    const bw: usize = if (cv.w >= 72) 2 else 1;
    const n = @min(MAX_BARS, (cv.w + 1) / (bw + 1));
    if (n == 0) return;
    const used = n * (bw + 1) - 1;
    const x0 = (cv.w - used) / 2;
    var env = std.math.clamp(a.level * 1.15, 0, 1);
    if (a.paused) env = 0 else if (env < 0.06) env = 0.06;
    const tf: f32 = @floatFromInt(tick % 100_000);
    const hf = ff(cv.h);

    for (0..n) |i| {
        const fi = ff(i);
        const mod = (@sin(tf * 0.22 + fi * 0.42) + @sin(tf * 0.11 + fi * 0.19 + 1.9)) * 0.25 + 0.75;
        const target = std.math.clamp(env * mod, 0, 1);
        for (0..steps) |_| {
            m.bar[i] += (target - m.bar[i]) * 0.45;
            m.peak[i] = @max(m.peak[i] - 0.015, m.bar[i]);
        }
        const height = m.bar[i] * hf;
        const full: usize = @intFromFloat(height);
        const frac = height - ff(full);
        const x = x0 + i * (bw + 1);
        for (0..cv.h) |row| {
            const class: Class = byLevel(ff(row) / hf * 1.15);
            const cp: ?u21 = if (row < full) FULL else if (row == full and frac > 0.12) PART[@min(6, @as(usize, @intFromFloat(frac * 7)))] else null;
            if (cp) |c| for (0..bw) |b| cv.put(@intCast(x + b), @intCast(cv.h - 1 - row), c, class);
        }
        const prow: usize = @min(cv.h - 1, @as(usize, @intFromFloat(m.peak[i] * hf)));
        if (m.peak[i] > 0.04 and prow > full) {
            for (0..bw) |b| cv.put(@intCast(x + b), @intCast(cv.h - 1 - prow), CAP, .strong);
        }
    }
}

const V3 = [3]f32;

fn rot(p: V3, ax: f32, ay: f32, az: f32) V3 {
    var x = p[0];
    var y = p[1];
    var z = p[2];
    var c = @cos(ax);
    var s = @sin(ax);
    const y1 = y * c - z * s;
    z = y * s + z * c;
    y = y1;
    c = @cos(ay);
    s = @sin(ay);
    const x1 = x * c + z * s;
    z = -x * s + z * c;
    x = x1;
    c = @cos(az);
    s = @sin(az);
    const x2 = x * c - y * s;
    y = x * s + y * c;
    return .{ x2, y, z };
}

const CUBE_V = [_]V3{ .{ -1, -1, -1 }, .{ 1, -1, -1 }, .{ 1, 1, -1 }, .{ -1, 1, -1 }, .{ -1, -1, 1 }, .{ 1, -1, 1 }, .{ 1, 1, 1 }, .{ -1, 1, 1 } };
const CUBE_E = [_][2]u8{ .{ 0, 1 }, .{ 1, 2 }, .{ 2, 3 }, .{ 3, 0 }, .{ 4, 5 }, .{ 5, 6 }, .{ 6, 7 }, .{ 7, 4 }, .{ 0, 4 }, .{ 1, 5 }, .{ 2, 6 }, .{ 3, 7 } };
const OCTA_V = [_]V3{ .{ 1, 0, 0 }, .{ -1, 0, 0 }, .{ 0, 1, 0 }, .{ 0, -1, 0 }, .{ 0, 0, 1 }, .{ 0, 0, -1 } };
const OCTA_E = [_][2]u8{ .{ 0, 2 }, .{ 0, 3 }, .{ 0, 4 }, .{ 0, 5 }, .{ 1, 2 }, .{ 1, 3 }, .{ 1, 4 }, .{ 1, 5 }, .{ 2, 4 }, .{ 2, 5 }, .{ 3, 4 }, .{ 3, 5 } };

fn wire(cv: *Canvas, verts: []const V3, edges: []const [2]u8, scale: f32, ax: f32, ay: f32, az: f32, front: Class, back: Class) void {
    const w = ff(cv.w * 2);
    const h = ff(cv.h * 4);
    const size = @min(w, h) * 0.5 * scale;
    var p: [8]V3 = undefined;
    for (verts, 0..) |v, i| {
        const q = rot(v, ax, ay, az);
        const d = 3.4 / (q[2] + 3.4);
        p[i] = .{ w / 2 + q[0] * size * d, h / 2 + q[1] * size * d, q[2] };
    }
    for (edges) |e| {
        const a = p[e[0]];
        const b = p[e[1]];
        cv.line(a[0], a[1], b[0], b[1], if (a[2] + b[2] < 0) front else back);
    }
}

fn wrap(x: f32) f32 {
    return @mod(x, std.math.tau * 64);
}

fn cube(cv: *Canvas, m: *Motion, a: Audio, steps: usize) void {
    const spin: f32 = if (a.paused) 0.002 else 0.012 + a.bright * 0.03;
    for (0..steps) |_| {
        m.ax = wrap(m.ax + spin * 0.7);
        m.ay = wrap(m.ay + spin);
        m.az = wrap(m.az + spin * 0.25);
    }
    wire(cv, &CUBE_V, &CUBE_E, 0.5 * (0.82 + 0.3 * a.level), m.ax, m.ay, m.az, .strong, .dim);
    wire(cv, &OCTA_V, &OCTA_E, 0.3 + 0.25 * a.level, -m.ax * 1.4, -m.ay * 0.8, m.az, .accent, .dim);
    cv.flushDots();
}

fn orbit(cv: *Canvas, m: *Motion, a: Audio, steps: usize) void {
    const speed: f32 = if (a.paused) 0.002 else 0.01 + a.bright * 0.035;
    for (0..steps) |_| m.orbit = wrap(m.orbit + speed);
    const w = ff(cv.w * 2);
    const h = ff(cv.h * 4);
    const ampx = w * 0.46 * (0.35 + 0.65 * a.left);
    const ampy = h * 0.44 * (0.35 + 0.65 * a.right);
    const N = 420;
    for ([_]f32{ 0.5, 0 }, [_]Class{ .dim, .strong }) |lag, class| {
        var px: f32 = 0;
        var py: f32 = 0;
        for (0..N + 1) |i| {
            const u = ff(i) / N * std.math.tau;
            const x = w / 2 + @sin(3 * u + m.orbit - lag) * ampx;
            const y = h / 2 + @sin(2 * u) * ampy;
            if (i > 0) cv.line(px, py, x, y, class);
            px = x;
            py = y;
        }
    }
    cv.flushDots();
}

const RAMP = " .:-=+*#%@";

fn ramp(cv: *Canvas, x: usize, y: usize, v: f32) void {
    const idx: usize = @intFromFloat(std.math.clamp(v * 10, 0, 9));
    if (idx == 0) return;
    const class: Class = if (idx >= 7) .strong else if (idx >= 4) .accent else .dim;
    cv.put(@intCast(x), @intCast(y), RAMP[idx], class);
}

fn rings(cv: *Canvas, m: *Motion, a: Audio, steps: usize) void {
    const speed: f32 = if (a.paused) 0.01 else 0.12 + a.level * 0.45;
    for (0..steps) |_| m.ring = wrap(m.ring + speed);
    const cx = ff(cv.w) / 2;
    const cy = ff(cv.h) / 2;
    const maxd = @max(1, @sqrt(cx * cx + cy * cy * 4));
    for (0..cv.h) |y| for (0..cv.w) |x| {
        const dx = ff(x) - cx;
        const dy = (ff(y) - cy) * 2;
        const d = @sqrt(dx * dx + dy * dy);
        const v = (0.5 + 0.5 * @sin(d * 0.6 - m.ring)) * (0.25 + 0.75 * a.level) * (1 - 0.55 * d / maxd);
        ramp(cv, x, y, v);
    };
}

fn plasma(cv: *Canvas, m: *Motion, a: Audio, steps: usize) void {
    const speed: f32 = if (a.paused) 0.003 else 0.025 + a.level * 0.09;
    for (0..steps) |_| m.plasma = wrap(m.plasma + speed);
    const t = m.plasma;
    const cx = ff(cv.w) / 2;
    const cy = ff(cv.h) / 2;
    for (0..cv.h) |y| for (0..cv.w) |x| {
        const fx = ff(x);
        const fy = ff(y) * 2;
        const dx = fx - cx;
        const dy = (ff(y) - cy) * 2;
        var v = @sin(fx * 0.11 + t) + @sin(fy * 0.09 + t * 0.7) + @sin((fx + fy) * 0.06 + t * 0.5) +
            @sin(@sqrt(dx * dx + dy * dy) * 0.13 - t * 1.3);
        v = (v + 4) / 8 * (0.35 + 0.65 * a.level);
        ramp(cv, x, y, v);
    };
}

// ------------------------------------------------------------- flipbooks

pub const Flipbook = struct {
    name: []const u8,
    fps: f32 = 8,
    speed_level: bool = false,
    color: ColorMode = .level,
    frames: []const []const []const u8,
    width: usize,
    height: usize,
};

pub const ColorMode = enum { level, dim, accent, strong };

pub const MAX_FILE_BYTES = 64 * 1024;
const MAX_FRAMES = 120;
const MAX_LINES = 60;
const MAX_COLS = 200;
const MAX_NAME_COLS = 24;

pub fn parseFlipbook(arena: std.mem.Allocator, bytes: []const u8, fallback_name: []const u8) ?Flipbook {
    var fb: Flipbook = .{ .name = "", .frames = &.{}, .width = 0, .height = 0 };
    var frames: std.ArrayList([]const []const u8) = .empty;
    var cur: std.ArrayList([]const u8) = .empty;
    var in_header = true;

    var it = std.mem.splitScalar(u8, bytes[0..@min(bytes.len, MAX_FILE_BYTES)], '\n');
    while (it.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (std.mem.eql(u8, std.mem.trim(u8, line, " \t"), "---")) {
            if (!in_header and cur.items.len > 0) {
                if (frames.items.len >= MAX_FRAMES) break;
                frames.append(arena, cur.toOwnedSlice(arena) catch return null) catch return null;
            }
            cur = .empty;
            in_header = false;
            continue;
        }
        if (in_header) {
            headerLine(arena, &fb, line);
            continue;
        }
        if (cur.items.len >= MAX_LINES) continue;
        const clean = text.sanitize(arena, line) catch return null;
        const fit = clipCols(clean, MAX_COLS);
        cur.append(arena, fit) catch return null;
        fb.width = @max(fb.width, colsOf(fit));
    }
    if (!in_header and cur.items.len > 0 and frames.items.len < MAX_FRAMES) {
        frames.append(arena, cur.toOwnedSlice(arena) catch return null) catch return null;
    }

    for (frames.items) |f| {
        var h = f.len;
        while (h > 0 and std.mem.trim(u8, f[h - 1], " ").len == 0) h -= 1;
        fb.height = @max(fb.height, h);
    }
    if (frames.items.len == 0 or fb.width == 0 or fb.height == 0) return null;
    fb.frames = frames.toOwnedSlice(arena) catch return null;
    if (fb.name.len == 0) fb.name = clipCols(text.sanitize(arena, fallback_name) catch return null, MAX_NAME_COLS);
    if (fb.name.len == 0) return null;
    return fb;
}

fn headerLine(arena: std.mem.Allocator, fb: *Flipbook, line: []const u8) void {
    const t = std.mem.trim(u8, line, " \t");
    if (t.len == 0 or t[0] == '#') return;
    const eq = std.mem.indexOfScalar(u8, t, '=') orelse return;
    const key = std.mem.trim(u8, t[0..eq], " \t");
    var val = std.mem.trim(u8, t[eq + 1 ..], " \t");
    if (std.mem.indexOfScalar(u8, val, '#')) |hash| val = std.mem.trim(u8, val[0..hash], " \t");
    if (std.mem.eql(u8, key, "name")) {
        const clean = text.sanitize(arena, val) catch return;
        fb.name = clipCols(std.mem.trim(u8, clean, " "), MAX_NAME_COLS);
    } else if (std.mem.eql(u8, key, "fps")) {
        const f = std.fmt.parseFloat(f32, val) catch return;
        if (std.math.isFinite(f)) fb.fps = std.math.clamp(f, 1, 30);
    } else if (std.mem.eql(u8, key, "speed")) {
        fb.speed_level = std.mem.eql(u8, val, "level");
    } else if (std.mem.eql(u8, key, "color")) {
        fb.color = std.meta.stringToEnum(ColorMode, val) orelse fb.color;
    }
}

fn colsOf(s: []const u8) usize {
    var n: usize = 0;
    var it = std.unicode.Utf8View.initUnchecked(s).iterator();
    while (it.nextCodepoint()) |cp| n += text.cpWidth(cp);
    return n;
}

fn clipCols(s: []const u8, max: usize) []const u8 {
    var n: usize = 0;
    var it = std.unicode.Utf8View.initUnchecked(s).iterator();
    var end: usize = 0;
    while (it.nextCodepoint()) |cp| {
        const w = text.cpWidth(cp);
        if (n + w > max) break;
        n += w;
        end = it.i;
    }
    return s[0..end];
}

pub const TICK_MS = 40;
const TICK_SECONDS: f32 = @as(f32, TICK_MS) / 1000;

fn flipbook(cv: *Canvas, fb: *const Flipbook, m: *Motion, a: Audio, steps: usize) void {
    const rate: f32 = if (a.paused) 0 else fb.fps * TICK_SECONDS * (if (fb.speed_level) 0.3 + 1.7 * a.level else 1);
    for (0..steps) |_| m.flip = @mod(m.flip + rate, @as(f32, @floatFromInt(fb.frames.len)));
    const idx = @min(fb.frames.len - 1, @as(usize, @intFromFloat(m.flip)));
    const frame = fb.frames[idx];
    const class: Class = switch (fb.color) {
        .level => if (a.paused) .dim else byLevel(a.level * 1.2),
        .dim => .dim,
        .accent => .accent,
        .strong => .strong,
    };
    const ox: isize = @divFloor(@as(isize, @intCast(cv.w)) - @as(isize, @intCast(fb.width)), 2);
    const oy: isize = @divFloor(@as(isize, @intCast(cv.h)) - @as(isize, @intCast(fb.height)), 2);
    for (frame, 0..) |row, ry| {
        if (ry >= fb.height) break;
        var x = ox;
        var it = std.unicode.Utf8View.initUnchecked(row).iterator();
        while (it.nextCodepoint()) |cp| {
            const w = text.cpWidth(cp);
            if (w == 0) continue;
            const y = oy + @as(isize, @intCast(ry));
            const fits = x >= 0 and x + @as(isize, @intCast(w)) <= @as(isize, @intCast(cv.w));
            if (cp != ' ' and fits) {
                cv.put(x, y, cp, class);
                if (w == 2) cv.put(x + 1, y, WIDE_TAIL, class);
            }
            x += @intCast(w);
        }
    }
}

// ----------------------------------------------------------------- tests

const testing = std.testing;

test "every visualizer renders at every size without leaving the canvas" {
    var bufs: Buffers = .{};
    defer bufs.deinit(testing.allocator);
    var m: Motion = .{};
    const loud: Audio = .{ .level = 1, .left = 1, .right = 1, .bright = 1, .paused = false };
    var tick: u64 = 0;
    for ([_]usize{ 1, 2, 3, 7, 12, 40, 97, 160 }) |w| {
        for ([_]usize{ 1, 2, 3, 5, 18, 50 }) |h| {
            var cv = try bufs.canvas(testing.allocator, w, h);
            for (0..builtin_names.len) |which| {
                tick += 1;
                render(&cv, which, &.{}, &m, loud, tick);
                render(&cv, which, &.{}, &m, .{}, tick + 1);
            }
        }
    }
}

test "motion survives a resize: the next frame continues from the same angle" {
    var bufs: Buffers = .{};
    defer bufs.deinit(testing.allocator);
    var m: Motion = .{};
    const a: Audio = .{ .level = 0.5, .bright = 0.5, .paused = false };
    var cv = try bufs.canvas(testing.allocator, 80, 24);
    render(&cv, 1, &.{}, &m, a, 1);
    const before = m.ay;
    cv = try bufs.canvas(testing.allocator, 33, 9);
    render(&cv, 1, &.{}, &m, a, 2);
    try testing.expect(m.ay > before);
    try testing.expect(m.ay - before < 0.1);
}

test "a paused visualizer barely moves" {
    var bufs: Buffers = .{};
    defer bufs.deinit(testing.allocator);
    var m: Motion = .{};
    var cv = try bufs.canvas(testing.allocator, 40, 12);
    render(&cv, 3, &.{}, &m, .{ .paused = true }, 1);
    const r0 = m.ring;
    render(&cv, 3, &.{}, &m, .{ .paused = true }, 2);
    try testing.expect(m.ring - r0 < 0.02);
}

test "flipbook parses header and frames" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const src =
        \\# a comment
        \\name = heartbeat
        \\fps = 12
        \\speed = level
        \\color = accent # trailing comment
        \\---
        \\  .-.
        \\ (   )
        \\---
        \\ .---.
        \\(     )
        \\
    ;
    const fb = parseFlipbook(arena.allocator(), src, "file").?;
    try testing.expectEqualStrings("heartbeat", fb.name);
    try testing.expectEqual(@as(f32, 12), fb.fps);
    try testing.expect(fb.speed_level);
    try testing.expectEqual(ColorMode.accent, fb.color);
    try testing.expectEqual(@as(usize, 2), fb.frames.len);
    try testing.expectEqual(@as(usize, 7), fb.width);
    try testing.expectEqual(@as(usize, 2), fb.height);
}

test "flipbook strips escapes, caps sizes, and falls back to the file name" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const evil = parseFlipbook(a, "fps = 9999\n---\n\x1b[2Jboom\x07\n", "evil").?;
    try testing.expectEqualStrings("evil", evil.name);
    try testing.expectEqual(@as(f32, 30), evil.fps);
    try testing.expect(std.mem.indexOfScalar(u8, evil.frames[0][0], 0x1b) == null);

    var big: std.ArrayList(u8) = .empty;
    try big.appendSlice(a, "---\n");
    for (0..500) |_| try big.appendSlice(a, "xxx\n---\n");
    const many = parseFlipbook(a, big.items, "many").?;
    try testing.expect(many.frames.len <= MAX_FRAMES);

    const wide = parseFlipbook(a, "---\n" ++ @as([1000]u8, @splat('w')) ++ "\n", "wide").?;
    try testing.expectEqual(@as(usize, MAX_COLS), wide.width);

    try testing.expect(parseFlipbook(a, "name = empty\n", "x") == null);
    try testing.expect(parseFlipbook(a, "---\n   \n\n---\n", "blank") == null);
}

test "flipbook frames and names cannot carry terminal control sequences" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const payloads = [_][]const u8{
        "\x1b]52;c;cm0gLXJmIH4=\x07",
        "\x1b]0;owned\x07",
        "\x1b[6n",
        "\x1b[?1049l\x1b[2J",
        "\x9b6n",
        "\x1bP+q544e\x1b\\",
        "a\u{202e}gnirts\u{2066}x\u{2069}",
        "\xc0\xaf\xed\xa0\x80\xff",
    };
    for (payloads) |p| {
        const src = try std.fmt.allocPrint(a, "name = {s}\n---\n{s}\n", .{ p, p });
        const fb = parseFlipbook(a, src, "x") orelse continue;
        for ([_][]const u8{ fb.name, fb.frames[0][0] }) |out| {
            try testing.expect(std.unicode.utf8ValidateSlice(out));
            var it = std.unicode.Utf8View.initUnchecked(out).iterator();
            while (it.nextCodepoint()) |cp| {
                try testing.expect(cp >= 0x20 and cp != 0x7f);
                try testing.expect(cp < 0x80 or cp > 0x9f);
                try testing.expect(!(cp >= 0x202a and cp <= 0x202e) and !(cp >= 0x2066 and cp <= 0x2069));
            }
        }
    }
}

test "flipbook with wide characters stays inside a narrow canvas" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const fb = parseFlipbook(arena.allocator(), "---\n音楽音楽音楽\n♫ hum ♫\n", "cjk").?;
    try testing.expectEqual(@as(usize, 12), fb.width);
    var bufs: Buffers = .{};
    defer bufs.deinit(testing.allocator);
    var m: Motion = .{};
    for ([_]usize{ 1, 2, 3, 5, 11, 12, 13 }) |w| {
        var cv = try bufs.canvas(testing.allocator, w, 3);
        render(&cv, builtin_names.len, &.{fb}, &m, .{ .level = 0.5, .paused = false }, 1);
        for (0..cv.h) |y| for (0..cv.w) |x| {
            const cell = cv.at(x, y);
            if (cell.cp == WIDE_TAIL) try testing.expect(x > 0 and text.cpWidth(cv.at(x - 1, y).cp) == 2);
        };
    }
}
