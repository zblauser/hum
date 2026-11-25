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
    bands: [BANDS]f32 = @splat(0),
    beat: f32 = 0,

    fn band(a: Audio, u: f32) f32 {
        const p = std.math.clamp(u, 0, 1) * (BANDS - 1);
        const i: usize = @intFromFloat(@min(p, BANDS - 2));
        return a.bands[i] + (a.bands[i + 1] - a.bands[i]) * (p - ff(i));
    }

    fn low(a: Audio) f32 {
        return (a.bands[1] + a.bands[2] + a.bands[3] + a.bands[4]) / 4;
    }
};

pub const BANDS = 16;

pub const Meter = struct {
    audio: Audio = .{},
    gain: f32 = 0.5,
    low_avg: f32 = 0,
    since_beat: u32 = 0,

    pub fn update(self: *Meter, idle: bool, level: f32, left: f32, right: f32, bright: f32, bands: [BANDS]f32) Audio {
        const a = &self.audio;
        a.paused = idle;
        const raw = [_]f32{ level, left, right, bright };
        inline for (.{ "level", "left", "right", "bright" }, 0..) |f, i| {
            const tgt = if (idle) 0 else raw[i];
            @field(a, f) += (tgt - @field(a, f)) * (if (tgt > @field(a, f)) @as(f32, 0.6) else 0.18);
        }
        var top: f32 = 0;
        for (bands) |b| top = @max(top, b);
        if (!idle) self.gain = @max(top, self.gain * 0.997, 0.35);
        for (&a.bands, bands) |*cur, b| {
            const tgt = if (idle) 0 else std.math.clamp(b / self.gain, 0, 1);
            cur.* += (tgt - cur.*) * (if (tgt > cur.*) @as(f32, 0.75) else 0.22);
        }
        const lo = a.low();
        self.since_beat +|= 1;
        a.beat *= 0.82;
        if (!idle and self.since_beat > 6 and lo > self.low_avg * 1.25 + 0.06) {
            a.beat = 1;
            self.since_beat = 0;
        }
        self.low_avg += (lo - self.low_avg) * 0.08;
        return a.*;
    }
};

pub const builtin_names = [_][]const u8{ "cover", "bars", "hypercube", "ellipses", "ripple", "plasma", "orbit", "halftone", "rain" };

const ALIASES = [_][2][]const u8{ .{ "cube", "hypercube" }, .{ "rings", "ripple" }, .{ "dither", "orbit" }, .{ "warp", "plasma" } };

pub const COVER = 0;

pub const Art = struct {
    px: []const u8 = &.{},
    side: usize = 0,
    note: []const u8 = "",
};

const MAX_BARS = 64;

const Ripple = struct { u: f32 = 0, v: f32 = 0, age: f32 = 99, power: f32 = 0 };

pub const Motion = struct {
    last_tick: u64 = 0,
    last_which: usize = std.math.maxInt(usize),
    ripples: [6]Ripple = @splat(.{}),
    spawned: u32 = 0,
    calm: f32 = 0,
    arc: f32 = 0,
    ax: f32 = 0.6,
    ay: f32 = 0.2,
    az: f32 = 0,
    orbit: f32 = 0,
    ring: f32 = 0,
    plasma: f32 = 0,
    drift: f32 = 0,
    beat: f32 = 0,
    glow: f32 = 0,
    exposure: f32 = 0,
    cover_key: u64 = 0,
    tone: f32 = 0,
    form: f32 = 0,
    rain: f32 = 0,
    density: f32 = 0,
    flip: f32 = 0,
    bar: [MAX_BARS]f32 = @splat(0),
    peak: [MAX_BARS]f32 = @splat(0),
};

pub const Buffers = struct {
    cells: []Cell = &.{},
    dots: []u8 = &.{},
    dot_class: []Class = &.{},
    glow: []f32 = &.{},
    gw: usize = 0,
    gh: usize = 0,

    pub fn canvas(self: *Buffers, gpa: std.mem.Allocator, w: usize, h: usize) !Canvas {
        const n = w * h;
        if (self.cells.len < n) {
            self.deinit(gpa);
            self.cells = try gpa.alloc(Cell, n);
            self.dots = try gpa.alloc(u8, n);
            self.dot_class = try gpa.alloc(Class, n);
            self.glow = try gpa.alloc(f32, n * 8);
        }
        if (self.gw != w or self.gh != h) {
            @memset(self.glow[0 .. n * 8], 0);
            self.gw = w;
            self.gh = h;
        }
        var cv: Canvas = .{ .w = w, .h = h, .cells = self.cells[0..n], .dots = self.dots[0..n], .dot_class = self.dot_class[0..n], .glow = self.glow[0 .. n * 8] };
        cv.clear();
        return cv;
    }

    pub fn deinit(self: *Buffers, gpa: std.mem.Allocator) void {
        gpa.free(self.cells);
        gpa.free(self.dots);
        gpa.free(self.dot_class);
        gpa.free(self.glow);
        self.* = .{};
    }
};

pub const Canvas = struct {
    w: usize,
    h: usize,
    cells: []Cell,
    dots: []u8,
    dot_class: []Class,
    glow: []f32 = &.{},

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

    fn fade(self: *Canvas, k: f32, steps: usize) void {
        if (steps == 0) return;
        const f = std.math.pow(f32, k, ff(steps));
        for (self.glow) |*g| g.* *= f;
    }

    fn spark(self: *Canvas, px: f32, py: f32, v: f32) void {
        if (!(px >= 0 and py >= 0)) return;
        const x: usize = @intFromFloat(px + 0.5);
        const y: usize = @intFromFloat(py + 0.5);
        if (x >= self.w * 2 or y >= self.h * 4) return;
        const g = &self.glow[y * self.w * 2 + x];
        g.* = @max(g.*, v);
    }

    fn beam(self: *Canvas, x0: f32, y0: f32, x1: f32, y1: f32, v: f32, halo: f32) void {
        const span = @max(@abs(x1 - x0), @abs(y1 - y0));
        if (!std.math.isFinite(span)) return;
        const n: usize = @intFromFloat(@min(@max(span, 1), 4096));
        for (0..n + 1) |i| {
            const f = ff(i) / ff(n);
            const x = x0 + (x1 - x0) * f;
            const y = y0 + (y1 - y0) * f;
            self.spark(x, y, v);
            if (halo == 0) continue;
            self.spark(x + 1, y, v * halo);
            self.spark(x - 1, y, v * halo);
            self.spark(x, y + 1, v * halo);
            self.spark(x, y - 1, v * halo);
        }
    }

    fn glowAt(self: Canvas, x: f32, y: f32) f32 {
        return self.glow[@as(usize, @intFromFloat(y)) * self.w * 2 + @as(usize, @intFromFloat(x))];
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
    for (ALIASES) |al| if (std.mem.eql(u8, al[0], n)) return indexOf(al[1], flipbooks);
    return null;
}

pub fn render(cv: *Canvas, which: usize, flipbooks: []const Flipbook, m: *Motion, a: Audio, tick: u64, art: Art) void {
    const steps: usize = @intCast(@min(tick -% m.last_tick, 4));
    m.last_tick = tick;
    if (cv.w == 0 or cv.h == 0) return;
    if (which != m.last_which) {
        @memset(cv.glow, 0);
        m.last_which = which;
        m.cover_key = 0;
    }
    switch (which) {
        0 => cover(cv, m, a, steps, art),
        1 => bars(cv, m, a, steps),
        2 => hypercube(cv, m, a, steps),
        3 => ellipses(cv, m, a, steps),
        4 => ripple(cv, m, a, steps),
        5 => plasma(cv, m, a, steps),
        6 => orbit(cv, m, a, steps),
        7 => halftone(cv, m, a, steps),
        8 => rain(cv, m, a, steps),
        else => {
            const i = which - builtin_names.len;
            if (i < flipbooks.len) flipbook(cv, &flipbooks[i], m, a, steps) else bars(cv, m, a, steps);
        },
    }
}

fn byLevel(v: f32) Class {
    return if (v > 0.66) .strong else if (v > 0.33) .accent else .dim;
}

fn ff(x: usize) f32 {
    return @floatFromInt(x);
}

fn wrap(x: f32) f32 {
    return @mod(x, std.math.tau * 64);
}

fn smooth(x: f32) f32 {
    const k = std.math.clamp(x, 0, 1);
    return k * k * (3 - 2 * k);
}

const Bars = struct {
    x0: f32,
    pitch: f32,
    bw: f32,
    n: usize,
    h: f32,
    bar: *const [MAX_BARS]f32,
    peak: *const [MAX_BARS]f32,

    fn at(k: Bars, x: f32, y: f32) f32 {
        const rel = x - k.x0;
        if (rel < 0) return 0;
        const i: usize = @intFromFloat(rel / k.pitch);
        if (i >= k.n or rel - ff(i) * k.pitch >= k.bw) return 0;
        const up = (k.h - 1 - y) / k.h;
        const v = k.bar[i];
        if (k.peak[i] > 0.03 and @abs(up - k.peak[i]) * k.h < 0.5) return 1;
        if (up > v) return if (y == k.h - 1) 0.25 else 0;
        const r = up / @max(v, 0.001);
        return 0.18 + 0.82 * r * @sqrt(r) * (0.5 + 0.5 * v);
    }
};

fn bars(cv: *Canvas, m: *Motion, a: Audio, steps: usize) void {
    const w = ff(cv.w * 2);
    const n: usize = @intFromFloat(std.math.clamp(@floor(w / 5), 1, MAX_BARS));
    const pitch = @floor(w / ff(n));
    const bw = @max(1, pitch - @max(1, @floor(pitch / 3)));
    for (0..n) |i| {
        const u = if (n > 1) ff(i) / ff(n - 1) else 0.5;
        const target: f32 = if (a.paused) 0 else std.math.clamp(a.band(u) * (0.88 + 0.2 * a.beat), 0, 1);
        for (0..steps) |_| {
            m.bar[i] += (target - m.bar[i]) * (if (target > m.bar[i]) @as(f32, 0.7) else 0.2);
            m.peak[i] = @max(m.peak[i] - 0.012, m.bar[i]);
        }
    }
    const k: Bars = .{ .x0 = @floor((w - pitch * ff(n) + pitch - bw) / 2), .pitch = pitch, .bw = bw, .n = n, .h = ff(cv.h * 4), .bar = &m.bar, .peak = &m.peak };
    shadeWith(cv, k, Bars.at, true);
}

fn turn(v: *[4]f32, i: usize, j: usize, ang: f32) void {
    const c = @cos(ang);
    const s = @sin(ang);
    const a = v[i];
    v[i] = a * c - v[j] * s;
    v[j] = a * s + v[j] * c;
}

const Core = struct {
    cv: Canvas,
    w: f32,
    h: f32,
    r: f32,
    lx: f32,
    ly: f32,

    fn at(k: Core, x: f32, y: f32) f32 {
        const trail = k.cv.glowAt(x, y);
        const nx = (x - k.w / 2) / k.r;
        const ny = (y - k.h / 2) / k.r;
        const d2 = nx * nx + ny * ny;
        if (d2 >= 1) return trail;
        const lit = nx * k.lx + ny * k.ly + @sqrt(1 - d2) * 0.7;
        return @max(trail, std.math.clamp(lit, 0, 1));
    }
};

fn hypercube(cv: *Canvas, m: *Motion, a: Audio, steps: usize) void {
    const spin: f32 = if (a.paused) 0.002 else 0.007 + a.band(0.5) * 0.018 + a.bright * 0.01;
    for (0..steps) |_| {
        m.ax = wrap(m.ax + spin * 0.6);
        m.ay = wrap(m.ay + spin);
        m.az = wrap(m.az + spin * 0.35);
        m.beat += (a.beat - m.beat) * 0.5;
    }
    const w = ff(cv.w * 2);
    const h = ff(cv.h * 4);
    cv.fade(0.6, steps);
    const eye = 4.5 - 0.8 * m.beat - 0.3 * a.low();
    const size = @min(w, h) * 0.17 * (0.9 + 0.2 * a.level);
    var p: [16][3]f32 = undefined;
    for (0..16) |i| {
        var v: [4]f32 = undefined;
        for (0..4) |b| v[b] = if (i >> @intCast(b) & 1 == 1) 1 else -1;
        turn(&v, 0, 3, m.ax);
        turn(&v, 1, 3, m.ay * 0.7);
        turn(&v, 2, 3, m.az);
        turn(&v, 0, 2, m.ay * 0.5);
        turn(&v, 1, 2, m.ax * 0.3);
        const s4 = eye / (eye - v[3]);
        const s3 = 4.2 / (4.2 + v[2] * s4);
        p[i] = .{ w / 2 + v[0] * s4 * s3 * size, h / 2 + v[1] * s4 * s3 * size, v[3] };
    }
    for (0..16) |i| for (i + 1..16) |j| {
        if (@popCount(i ^ j) != 1) continue;
        const depth = (p[i][2] + p[j][2]) / 2;
        cv.beam(p[i][0], p[i][1], p[j][0], p[j][1], 0.35 + 0.3 * std.math.clamp((depth + 2) / 4, 0, 1), 0.45);
    };
    const core: Core = .{ .cv = cv.*, .w = w, .h = h, .r = @min(w, h) * (0.07 + 0.06 * a.low() + 0.04 * m.beat), .lx = @sin(m.ay) * 0.6, .ly = @cos(m.ax) * 0.4 };
    shade(cv, core, Core.at);
    for (0..16) |i| for (i + 1..16) |j| {
        if (@popCount(i ^ j) != 1) continue;
        const depth = (p[i][2] + p[j][2]) / 2;
        cv.line(p[i][0], p[i][1], p[j][0], p[j][1], if (depth > 0.4) .strong else if (depth > -0.4) .accent else .dim);
    };
    cv.flushDots();
}

const ELL = [_][2]f32{ .{ 1, 2 }, .{ 2, 3 }, .{ 3, 2 }, .{ 1, 3 }, .{ 3, 4 } };

fn ellipses(cv: *Canvas, m: *Motion, a: Audio, steps: usize) void {
    const speed: f32 = if (a.paused) 0.002 else 0.01 + a.level * 0.025 + a.bright * 0.015;
    for (0..steps) |_| {
        m.orbit = wrap(m.orbit + speed);
        m.beat += (a.beat - m.beat) * 0.5;
    }
    cv.fade(0.62, steps);
    const w = ff(cv.w * 2);
    const h = ff(cv.h * 4);
    const t = m.orbit;
    const N = 200;
    for (ELL, 0..) |r, k| {
        const kf = ff(k);
        const e = if (a.paused) 0.2 else a.band((kf + 0.5) / ELL.len);
        const reach = 0.22 + 0.55 * e + 0.12 * m.beat;
        const ph = t * (0.7 + 0.23 * kf) + kf * 1.7 + 0.8 * @sin(t * 0.31 + kf);
        const tilt = 0.6 * @sin(t * 0.13 + kf * 2.1);
        const cx = w / 2 + w * 0.06 * @sin(t * 0.4 + kf * 1.3);
        const cy = h / 2 + h * 0.06 * @cos(t * 0.5 + kf);
        const c = @cos(tilt);
        const s = @sin(tilt);
        var px: f32 = 0;
        var py: f32 = 0;
        for (0..N + 1) |i| {
            const u = ff(i) / N * std.math.tau;
            const lx = @sin(r[0] * u + ph);
            const ly = @sin(r[1] * u);
            const x = cx + (lx * c - ly * s) * w * 0.46 * reach;
            const y = cy + (lx * s + ly * c) * h * 0.44 * reach;
            if (i > 0) cv.beam(px, py, x, y, 0.4 + 0.6 * e, 0.25);
            px = x;
            py = y;
        }
    }
    shade(cv, cv.*, Canvas.glowAt);
}

const Pond = struct {
    h: f32,
    mid: f32,
    aspect: f32,
    t: f32,
    amp: f32,
    rs: []const Ripple,

    fn at(k: Pond, x: f32, y: f32) f32 {
        const u = x / k.h;
        const v = y / k.h;
        const dx = u - k.mid;
        const dy = v - 0.5;
        const d0 = @sqrt(dx * dx + dy * dy);
        const swell = 0.5 + 0.5 * @sin(d0 * 20 - k.t);
        var lit = swell * swell * swell * k.amp * @max(0, 1 - d0 * 0.9);
        for (k.rs) |r| {
            if (r.power <= 0 or r.age > 4) continue;
            const ex = u - r.u * k.aspect;
            const ey = v - r.v;
            const off = @sqrt(ex * ex + ey * ey) - r.age * 0.3;
            if (@abs(off) > 0.1) continue;
            const env = r.power * @exp(-r.age * 0.8) * (1 - @abs(off) / 0.1);
            lit += env * @max(0, @cos(off * 70));
        }
        return std.math.clamp((lit - 0.05) * 1.1, 0, 1);
    }
};

fn ripple(cv: *Canvas, m: *Motion, a: Audio, steps: usize) void {
    const speed: f32 = if (a.paused) 0.01 else 0.05 + a.level * 0.12;
    for (0..steps) |_| {
        m.ring = wrap(m.ring + speed);
        for (&m.ripples) |*r| r.age += TICK_SECONDS;
        m.calm += TICK_SECONDS;
    }
    if (steps > 0 and !a.paused and (a.beat > 0.95 or m.calm > 1.8)) {
        const seed = mix32(m.spawned, 91);
        m.ripples[m.spawned % m.ripples.len] = .{
            .u = 0.15 + 0.7 * ff(seed & 0xffff) / 65535,
            .v = 0.2 + 0.6 * ff(seed >> 16) / 65535,
            .age = 0,
            .power = if (a.beat > 0.95) 0.55 + 0.45 * a.low() else 0.35,
        };
        m.spawned +%= 1;
        m.calm = 0;
    }
    const h = ff(cv.h * 4);
    const aspect = ff(cv.w * 2) / h;
    const k: Pond = .{ .h = h, .mid = aspect / 2, .aspect = aspect, .t = m.ring, .amp = if (a.paused) 0.15 else 0.25 + 0.45 * a.level, .rs = &m.ripples };
    shadeSoft(cv, k, Pond.at);
}

const Plasma = struct {
    h: f32,
    mid: f32,
    t: f32,
    pull: f32,
    amp: f32,
    hi: f32,

    fn at(k: Plasma, x: f32, y: f32) f32 {
        const u = x / k.h;
        const v = y / k.h;
        const t = k.t;
        const qx = @sin(u * 2.1 + t * 0.9) + @sin(v * 1.7 - t * 0.6);
        const qy = @cos(v * 2.4 - t * 0.7) + @sin(u * 1.3 + t * 0.5);
        const pu = u + qx * k.pull;
        const pv = v + qy * k.pull;
        const r = @sqrt((pu - k.mid) * (pu - k.mid) + (pv - 0.5) * (pv - 0.5));
        const s = @sin(pu * 3.2 + t) + @sin(pv * 2.7 - t * 0.8) + @sin((pu + pv) * 2.1 + t * 0.4) + @sin(r * 6 - t * 1.3);
        const g = smooth(smooth((s + 4) / 8));
        const f = g * g;
        const band = @abs(@mod(f * 5 + t * 0.15, 1) - 0.5);
        const ridge: f32 = if (band > 0.46) 0.3 * k.hi else 0;
        return std.math.clamp(f * k.amp + ridge, 0, 1);
    }
};

fn plasma(cv: *Canvas, m: *Motion, a: Audio, steps: usize) void {
    const speed: f32 = if (a.paused) 0.003 else 0.016 + a.level * 0.05;
    for (0..steps) |_| {
        m.plasma = wrap(m.plasma + speed);
        m.beat += (a.beat - m.beat) * 0.4;
    }
    const h = ff(cv.h * 4);
    const k: Plasma = .{
        .h = h,
        .mid = ff(cv.w * 2) / h / 2,
        .t = m.plasma,
        .pull = 0.22 + 0.35 * a.low() + 0.25 * m.beat,
        .amp = if (a.paused) 0.35 else 0.5 + 0.5 * a.level,
        .hi = 0.4 + 0.6 * a.band(0.85),
    };
    shadeSoft(cv, k, Plasma.at);
}

const BAYER = [8][8]u8{
    .{ 0, 32, 8, 40, 2, 34, 10, 42 },
    .{ 48, 16, 56, 24, 50, 18, 58, 26 },
    .{ 12, 44, 4, 36, 14, 46, 6, 38 },
    .{ 60, 28, 52, 20, 62, 30, 54, 22 },
    .{ 3, 35, 11, 43, 1, 33, 9, 41 },
    .{ 51, 19, 59, 27, 49, 17, 57, 25 },
    .{ 15, 47, 7, 39, 13, 45, 5, 37 },
    .{ 63, 31, 55, 23, 61, 29, 53, 21 },
};

fn shade(cv: *Canvas, ctx: anytype, comptime sample: fn (@TypeOf(ctx), f32, f32) f32) void {
    shadeWith(cv, ctx, sample, false);
}

const Soft = struct {
    g: []const f32,
    n: usize,

    fn at(k: Soft, x: f32, y: f32) f32 {
        const xi: usize = @intFromFloat(x);
        const yi: usize = @intFromFloat(y);
        const i = (yi / 2) * k.n + xi / 2;
        const fx = ff(xi & 1) * 0.5;
        const fy = ff(yi & 1) * 0.5;
        const top = k.g[i] + (k.g[i + 1] - k.g[i]) * fx;
        const bot = k.g[i + k.n] + (k.g[i + k.n + 1] - k.g[i + k.n]) * fx;
        return top + (bot - top) * fy;
    }
};

fn shadeSoft(cv: *Canvas, ctx: anytype, comptime sample: fn (@TypeOf(ctx), f32, f32) f32) void {
    const n = cv.w + 1;
    for (0..cv.h * 2 + 1) |y| for (0..n) |x| {
        cv.glow[y * n + x] = sample(ctx, ff(x * 2), ff(y * 2));
    };
    shade(cv, Soft{ .g = cv.glow, .n = n }, Soft.at);
}

fn shadeWith(cv: *Canvas, ctx: anytype, comptime sample: fn (@TypeOf(ctx), f32, f32) f32, comptime lit: bool) void {
    for (0..cv.h) |cy| for (0..cv.w) |cx| {
        var bits: u8 = 0;
        var sum: f32 = 0;
        var on: f32 = 0;
        for (0..4) |sy| for (0..2) |sx| {
            const dx = cx * 2 + sx;
            const dy = cy * 4 + sy;
            const v = sample(ctx, ff(dx), ff(dy));
            if (v * 64 > ff(BAYER[dy & 7][dx & 7]) + 0.5) {
                bits |= Canvas.DOT[sy][sx];
                on += 1;
                if (lit) sum += v;
            }
            if (!lit) sum += v;
        };
        if (bits == 0) continue;
        const avg = if (lit) sum / on else sum / 8;
        const class: Class = if (avg > 0.72) .strong else if (avg > 0.38) .accent else .dim;
        cv.cells[cy * cv.w + cx] = .{ .cp = 0x2800 + @as(u21, bits), .class = class };
    };
}

fn diffuse(cv: *Canvas, ctx: anytype, comptime sample: fn (@TypeOf(ctx), f32, f32) f32) void {
    const DW = 1024;
    const cw = @min(cv.w, DW / 2);
    var err: [3][DW + 5]f32 = @splat(@splat(0));
    var bits: [DW / 2]u8 = undefined;
    var sum: [DW / 2]f32 = undefined;
    for (0..cv.h) |cy| {
        @memset(bits[0..cw], 0);
        @memset(sum[0..cw], 0);
        for (0..4) |sy| {
            const back = sy & 1 == 1;
            for (0..cw * 2) |n| {
                const x = if (back) cw * 2 - 1 - n else n;
                const v = sample(ctx, ff(x), ff(cy * 4 + sy));
                sum[x / 2] += v;
                const want = v + err[0][x + 2];
                const on = want > 0.5;
                if (on) bits[x / 2] |= Canvas.DOT[sy][x & 1];
                const e = (want - @as(f32, if (on) 1 else 0)) / 8;
                const ahead = if (back) x + 1 else x + 3;
                const far = if (back) x else x + 4;
                err[0][ahead] += e;
                err[0][far] += e;
                err[1][x + 1] += e;
                err[1][x + 2] += e;
                err[1][x + 3] += e;
                err[2][x + 2] += e;
            }
            err[0] = err[1];
            err[1] = err[2];
            err[2] = @splat(0);
        }
        for (0..cw) |cx| {
            if (bits[cx] == 0) continue;
            const avg = sum[cx] / 8;
            const class: Class = if (avg > 0.72) .strong else if (avg > 0.38) .accent else .dim;
            cv.cells[cy * cv.w + cx] = .{ .cp = 0x2800 + @as(u21, bits[cx]), .class = class };
        }
    }
}

const Field = struct { w: f32, h: f32, t: f32, amp: f32, beat: f32 = 0, e: [3]f32 = @splat(0.5) };

const FORM_S = 24.0;
const FORM_FADE_S = 3.0;

const Forms = struct {
    f: Field,
    a: usize,
    b: usize,
    mix: f32,

    fn at(k: Forms, x: f32, y: f32) f32 {
        const u = x / k.f.h;
        const v = y / k.f.h;
        const p = form(k.f, k.a, u, v);
        const q = if (k.mix > 0) form(k.f, k.b, u, v) else p;
        const val = std.math.clamp((p + (q - p) * k.mix) * k.f.amp, 0, 1);
        if (val > 0.03) return val;
        const xi: u32 = @intFromFloat(x);
        const yi: u32 = @intFromFloat(y);
        const star = mix32(xi *% 7919 +% yi, 3);
        if (star % 1000 >= 3) return val;
        return if (@sin(k.f.t * 2.5 + ff(star % 97)) > -0.2) 1 else val;
    }

    fn form(c: Field, which: usize, u: f32, v: f32) f32 {
        const mid = 0.5 * c.w / c.h;
        return smooth(switch (which) {
            0 => blk: {
                const r = 0.34 + 0.06 * c.amp;
                const cx = mid + 0.08 * @sin(c.t * 0.7);
                const cy = 0.5 + 0.05 * @cos(c.t * 0.9);
                const nx = (u - cx) / r;
                const ny = (v - cy) / r;
                const d2 = nx * nx + ny * ny;
                const lx = @sin(c.t * 1.3);
                const ly = -0.45;
                const lz = @cos(c.t * 1.3) * 0.6 + 0.5;
                const ll = @sqrt(lx * lx + ly * ly + lz * lz);
                const th = c.t * 0.9;
                const mx = cx + 0.62 * @cos(th);
                const my = cy + 0.16 * @sin(th);
                const mr = 0.055 + 0.015 * c.beat;
                const behind = @sin(th) < 0;
                const ox = (u - cx) / 0.62;
                const oy = (v - cy) / 0.16;
                const track = @abs(ox * ox + oy * oy - 1) < 0.05;
                const mnx = (u - mx) / mr;
                const mny = (v - my) / mr;
                const md2 = mnx * mnx + mny * mny;
                if (md2 < 1 and !(behind and d2 < 1)) {
                    const mlit = (mnx * lx + mny * ly + @sqrt(1 - md2) * lz) / ll;
                    break :blk 0.15 + 0.85 * @max(mlit, 0);
                }
                if (d2 >= 1) break :blk if (track) 0.32 else 0;
                if (track and v > cy) break :blk 0.45;
                const nz = @sqrt(1 - d2);
                const lit = (nx * lx + ny * ly + nz * lz) / ll;
                const bands = 0.08 * @sin(ny * 9 + c.t * 2);
                break :blk @max(lit, 0) * 0.95 + bands + std.math.pow(f32, @max(lit, 0), 18) * 0.4;
            },
            1 => blk: {
                const ax = mid + 0.35 * @sin(c.t * 1.1);
                const ay = 0.5 + 0.3 * @cos(c.t * 0.8);
                const bx = mid + 0.45 * @cos(c.t * 0.6 + 2);
                const by = 0.5 + 0.35 * @sin(c.t * 1.3 + 1);
                const d1 = @sqrt((u - ax) * (u - ax) + (v - ay) * (v - ay));
                const d2 = @sqrt((u - bx) * (u - bx) + (v - by) * (v - by));
                const wave = 0.5 + 0.25 * @sin(d1 * 18 - c.t * 3) + 0.25 * @sin(d2 * 14 + c.t * 2);
                const fall = 1 - std.math.clamp(@min(d1, d2) * 1.4, 0, 1);
                break :blk (wave * (0.3 + 0.7 * fall) - 0.12) / 0.7;
            },
            else => blk: {
                const pull = 0.3 + 0.25 * c.amp;
                const qx = @sin(u * 3.1 + c.t) + @sin(v * 2.3 - c.t * 0.6);
                const qy = @cos(v * 3.7 - c.t * 0.8) + @sin(u * 1.9 + c.t * 0.4);
                const rx = @sin((v + qy * pull) * 2.7 - c.t * 0.5);
                const ry = @cos((u + qx * pull) * 2.2 + c.t * 0.3);
                const w = @sin((u + (qx + rx) * pull) * 5 + c.t) * @cos((v + (qy + ry) * pull) * 4 - c.t * 0.7);
                break :blk 0.5 + 0.55 * w;
            },
        });
    }
};

fn orbit(cv: *Canvas, m: *Motion, a: Audio, steps: usize) void {
    const speed: f32 = if (a.paused) 0.002 else 0.012 + a.level * 0.05;
    for (0..steps) |_| {
        m.drift = wrap(m.drift + speed);
        m.form = @mod(m.form + TICK_SECONDS, FORM_S * 2);
        m.beat += (a.beat - m.beat) * 0.4;
    }
    const idx: usize = @intFromFloat(m.form / FORM_S);
    const into = m.form - ff(idx) * FORM_S;
    const k: Forms = .{ .f = field(cv, m, a), .a = idx % 2, .b = (idx + 1) % 2, .mix = smooth((into - (FORM_S - FORM_FADE_S)) / FORM_FADE_S) };
    shadeSoft(cv, k, Forms.at);
}

fn field(cv: *const Canvas, m: *const Motion, a: Audio) Field {
    return .{ .w = ff(cv.w * 2), .h = ff(cv.h * 4), .t = m.drift, .amp = 0.6 + 0.6 * a.level, .beat = m.beat };
}

fn halftone(cv: *Canvas, m: *Motion, a: Audio, steps: usize) void {
    const speed: f32 = if (a.paused) 0.002 else 0.01 + a.level * 0.04;
    for (0..steps) |_| {
        m.tone = wrap(m.tone + speed);
        m.beat += (a.beat - m.beat) * 0.5;
    }
    const f: Field = .{
        .w = ff(cv.w * 2),
        .h = ff(cv.h * 4),
        .t = m.tone,
        .amp = if (a.paused) 0.2 else 0.35 + 0.65 * a.level,
        .beat = if (a.paused) 0 else m.beat,
        .e = if (a.paused) @splat(0.3) else .{ a.low(), a.band(0.5), a.band(0.85) },
    };
    @memset(cv.glow, 0);
    const P: f32 = 7;
    const R = std.math.sqrt1_2;
    const gw = ff(cv.w * 2);
    const gh = ff(cv.h * 4);
    const nu: usize = @intFromFloat((gw + gh) * R / P + 1);
    for (0..nu) |i| for (0..nu * 2) |j| {
        const cu = (ff(i) + 0.5) * P;
        const cv_ = (ff(j) + 0.5) * P - gw * R;
        const x = (cu - cv_) * R;
        const y = (cu + cv_) * R;
        if (x < -P or y < -P or x > gw + P or y > gh + P) continue;
        const r2 = tone(f, x, y) * P * P * 0.42;
        const r = @sqrt(r2);
        const x0: usize = @intFromFloat(std.math.clamp(x - r, 0, gw));
        const y0: usize = @intFromFloat(std.math.clamp(y - r, 0, gh));
        const x1: usize = @intFromFloat(std.math.clamp(x + r + 1, 0, gw));
        const y1: usize = @intFromFloat(std.math.clamp(y + r + 1, 0, gh));
        for (y0..y1) |dy| for (x0..x1) |dx| {
            const du = (ff(dx) + ff(dy)) * R - cu;
            const dv = (ff(dy) - ff(dx)) * R - cv_;
            if (du * du + dv * dv < r2 and @max(@abs(du), @abs(dv)) <= P / 2) cv.glow[dy * cv.w * 2 + dx] = 1;
        };
    };
    shade(cv, cv.*, Canvas.glowAt);
}

fn tone(c: Field, x: f32, y: f32) f32 {
    const u = x / c.h;
    const v = y / c.h;
    const mid = 0.5 * c.w / c.h;
    var sum: f32 = 0;
    for (0..3) |i| {
        const k = ff(i);
        const bx = mid + mid * 0.7 * @sin(c.t * (0.5 + 0.17 * k) + 2.1 * k);
        const by = 0.5 + 0.32 * @cos(c.t * (0.7 + 0.11 * k) + k);
        const d2 = (u - bx) * (u - bx) + (v - by) * (v - by);
        sum += @exp(-d2 / (0.015 + 0.06 * c.e[i]));
    }
    const wave = 0.12 * (0.5 + 0.5 * @sin((u + v) * 7 - c.t * 2));
    return std.math.clamp(sum * (0.4 + 0.6 * c.amp) + wave + 0.22 * c.beat, 0, 1);
}

fn mix32(a: u32, b: u32) u32 {
    var h = (a *% 0x9E3779B1) ^ (b *% 0x85EBCA77);
    h ^= h >> 15;
    h *%= 0x2C1B3C6D;
    h ^= h >> 12;
    return h;
}

const RAIN_GLYPHS = "0123456789ABCDEFXZ$+*<>=#:";

fn rain(cv: *Canvas, m: *Motion, a: Audio, steps: usize) void {
    const target: f32 = if (a.paused) 0.15 else 0.25 + 0.5 * a.level + 0.3 * a.beat;
    const speed: f32 = if (a.paused) 0.03 else 0.22 + a.level * 0.45 + a.beat * 0.25;
    for (0..steps) |_| {
        m.rain = @mod(m.rain + speed, 1 << 16);
        m.density += (target - m.density) * 0.08;
    }
    const hf = ff(cv.h);
    const flick: u32 = @intFromFloat(m.rain * 0.15);
    for (0..cv.w) |x| {
        const xi: u32 = @intCast(x);
        const hx = mix32(xi, 7);
        const vel = 0.5 + ff(hx & 0xff) / 255 * 0.9;
        const trail = 3 + ff((hx >> 8) & 0xff) / 255 * hf * 0.8;
        const span = hf + trail + 2 + ff((hx >> 16) & 0x3f) / 63 * hf * 0.5;
        const pos = m.rain * vel + ff(hx >> 22);
        const cycle: u32 = @intFromFloat(@floor(pos / span));
        if (ff(mix32(xi, cycle) & 0xffff) / 65535 > m.density) continue;
        const head: isize = @intFromFloat(pos - ff(cycle) * span);
        const len: usize = @intFromFloat(trail);
        for (0..len) |k| {
            const row = head - @as(isize, @intCast(k));
            if (row < 0) break;
            if (row >= cv.h) continue;
            const ri: u32 = @intCast(row);
            const age = ff(k) / trail;
            const class: Class = if (k == 0) .strong else if (age < 0.3) .accent else .dim;
            const seed = if (k == 0 or mix32(xi, ri) % 7 == 0) cycle +% flick else cycle;
            const g = RAIN_GLYPHS[mix32(xi *% 131 +% ri, seed) % RAIN_GLYPHS.len];
            cv.put(@intCast(x), row, g, class);
        }
    }
}

const Cover = struct {
    art: Art,
    ox: f32,
    oy: f32,
    s: f32,
    gain: f32,

    fn at(k: Cover, x: f32, y: f32) f32 {
        const u = (x - k.ox) / k.s;
        const v = (y - k.oy) / k.s;
        if (u < 0 or v < 0 or u >= 1 or v >= 1) return 0;
        const n = k.art.side;
        const side = ff(n);
        const step = side / k.s;
        const fx = u * side;
        const fy = v * side;
        if (step <= 1) {
            const cx = std.math.clamp(fx + step / 2 - 0.5, 0, side - 1);
            const cy = std.math.clamp(fy + step / 2 - 0.5, 0, side - 1);
            const x0: usize = @intFromFloat(cx);
            const y0: usize = @intFromFloat(cy);
            const x1 = @min(x0 + 1, n - 1);
            const y1 = @min(y0 + 1, n - 1);
            const tx = cx - ff(x0);
            const ty = cy - ff(y0);
            const top = ff(k.art.px[y0 * n + x0]) * (1 - tx) + ff(k.art.px[y0 * n + x1]) * tx;
            const bot = ff(k.art.px[y1 * n + x0]) * (1 - tx) + ff(k.art.px[y1 * n + x1]) * tx;
            return std.math.clamp((top * (1 - ty) + bot * ty) / 255 * k.gain, 0, 1);
        }
        const x0: usize = @intFromFloat(fx);
        const y0: usize = @intFromFloat(fy);
        const x1 = @min(n, @max(x0 + 1, @as(usize, @intFromFloat(@ceil(fx + step)))));
        const y1 = @min(n, @max(y0 + 1, @as(usize, @intFromFloat(@ceil(fy + step)))));
        var sum: u32 = 0;
        for (y0..y1) |yy| for (x0..x1) |xx| {
            sum += k.art.px[yy * n + xx];
        };
        const p = ff(sum) / ff((y1 - y0) * (x1 - x0)) / 255;
        return std.math.clamp(p * k.gain, 0, 1);
    }
};

fn cover(cv: *Canvas, m: *Motion, a: Audio, steps: usize, art: Art) void {
    const target: f32 = if (a.paused) 0 else a.level;
    for (0..steps) |_| m.glow += (target - m.glow) * 0.35;
    if (art.px.len == 0 or art.side == 0 or art.px.len < art.side * art.side) {
        caption(cv, if (art.note.len > 0) art.note else "no cover");
        return;
    }
    const w = ff(cv.w * 2);
    const h = ff(cv.h * 4);
    const s = @min(w, h);
    if (@abs(m.glow - m.exposure) > 0.2) m.exposure = @round(m.glow * 4) / 4;
    const c: Cover = .{ .art = art, .ox = (w - s) / 2, .oy = (h - s) / 2, .s = s, .gain = 0.9 + 0.25 * m.exposure };
    const key = std.hash.Wyhash.hash(@as(u64, cv.w) << 32 | cv.h << 1 | 1, art.px) ^ @as(u32, @bitCast(c.gain));
    if (key != m.cover_key) {
        m.cover_key = key;
        sharpCover(cv, c);
    }
    diffuse(cv, cv.*, Canvas.glowAt);
}

fn sharpCover(cv: *Canvas, c: Cover) void {
    const dw = cv.w * 2;
    for (0..cv.h * 4) |y| for (0..dw) |x| {
        cv.glow[y * dw + x] = c.at(ff(x), ff(y));
    };
    var prev: [1024]f32 = undefined;
    var cur: [1024]f32 = undefined;
    const n = @min(dw, prev.len);
    @memcpy(prev[0..n], cv.glow[0..n]);
    for (1..cv.h * 4 -| 1) |y| {
        const row = cv.glow[y * dw ..][0..n];
        @memcpy(cur[0..n], row);
        const next = cv.glow[(y + 1) * dw ..][0..n];
        for (1..n -| 1) |x| {
            const blur = (prev[x] + next[x] + cur[x - 1] + cur[x + 1]) / 4;
            row[x] = std.math.clamp(cur[x] + (cur[x] - blur) * 0.8, 0, 1);
        }
        @memcpy(prev[0..n], cur[0..n]);
    }
}

fn caption(cv: *Canvas, msg: []const u8) void {
    const cols = colsOf(msg);
    if (cols + 4 > cv.w or cv.h == 0) return;
    const x0 = (cv.w - cols) / 2;
    const y = cv.h / 2;
    for (x0 -| 1..@min(x0 + cols + 1, cv.w)) |x| cv.cells[y * cv.w + x] = .{};
    var view = std.unicode.Utf8View.init(msg) catch return;
    var it = view.iterator();
    var x = x0;
    while (it.nextCodepoint()) |cp| : (x += 1) cv.put(@intCast(x), @intCast(y), cp, .dim);
}

const Arc = struct {
    w: f32,
    h: f32,
    t: f32,
    seed: u32,
    a: Audio,

    fn noise(x: f32, seed: u32, sharp: bool) f32 {
        const i: u32 = @intFromFloat(@floor(@abs(x)));
        const r = @abs(x) - @floor(@abs(x));
        const f = if (sharp) r else smooth(r);
        const p = ff(mix32(i, seed) & 0xffff) / 32767.5 - 1;
        const q = ff(mix32(i +% 1, seed) & 0xffff) / 32767.5 - 1;
        return p + (q - p) * f;
    }

    fn at(k: Arc, x: f32, y: f32) f32 {
        const mid = (k.h - 1) / 2;
        if (k.a.paused) return if (@abs(y - mid) < 0.6) 0.3 else 0;
        const e = k.a.band(x / k.w);
        const wander = noise(x * 0.06 + k.t, 11, false) * 0.5 + noise(x * 0.3, k.seed, true) * 0.7;
        const d = @abs(y - (mid + wander * (k.h / 2) * (0.25 + 1.1 * e)));
        if (d < 0.5) return 0.6 + 0.4 * e;
        const xi: u32 = @intFromFloat(x);
        const yi: u32 = @intFromFloat(y);
        if (d < 2.5 and mix32(xi *% 31 +% yi, k.seed) % 29 == 0) return e;
        return @exp(-d * d / (0.25 + 0.6 * e)) * (0.1 + 0.4 * e);
    }
};

pub fn strip(cv: *Canvas, m: *Motion, a: Audio, tick: u64) void {
    const steps: usize = @intCast(@min(tick -% m.last_tick, 4));
    m.last_tick = tick;
    if (cv.w == 0 or cv.h == 0) return;
    for (0..steps) |_| m.arc = wrap(m.arc + 0.04 + a.level * 0.12);
    const k: Arc = .{ .w = ff(cv.w * 2), .h = ff(cv.h * 4), .t = m.arc, .seed = @truncate(tick), .a = a };
    shade(cv, k, Arc.at);
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
    const fake_art = [_]u8{ 0, 80, 160, 255, 0, 80, 160, 255, 0, 80, 160, 255, 0, 80, 160, 255 };
    var tick: u64 = 0;
    for ([_]usize{ 1, 2, 3, 7, 12, 40, 97, 160 }) |w| {
        for ([_]usize{ 1, 2, 3, 5, 18, 50 }) |h| {
            var cv = try bufs.canvas(testing.allocator, w, h);
            for (0..builtin_names.len) |which| {
                tick += 1;
                render(&cv, which, &.{}, &m, loud, tick, .{});
                render(&cv, which, &.{}, &m, loud, tick, .{ .px = &fake_art, .side = 4 });
                render(&cv, which, &.{}, &m, .{}, tick + 1, .{});
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
    const hc = indexOf("hypercube", &.{}).?;
    render(&cv, hc, &.{}, &m, a, 1, .{});
    const before = m.ay;
    cv = try bufs.canvas(testing.allocator, 33, 9);
    render(&cv, hc, &.{}, &m, a, 2, .{});
    try testing.expect(m.ay > before);
    try testing.expect(m.ay - before < 0.1);
}

test "a paused visualizer barely moves" {
    var bufs: Buffers = .{};
    defer bufs.deinit(testing.allocator);
    var m: Motion = .{};
    var cv = try bufs.canvas(testing.allocator, 40, 12);
    const rp = indexOf("ripple", &.{}).?;
    render(&cv, rp, &.{}, &m, .{ .paused = true }, 1, .{});
    const r0 = m.ring;
    render(&cv, rp, &.{}, &m, .{ .paused = true }, 2, .{});
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
        render(&cv, builtin_names.len, &.{fb}, &m, .{ .level = 0.5, .paused = false }, 1, .{});
        for (0..cv.h) |y| for (0..cv.w) |x| {
            const cell = cv.at(x, y);
            if (cell.cp == WIDE_TAIL) try testing.expect(x > 0 and text.cpWidth(cv.at(x - 1, y).cp) == 2);
        };
    }
}

test "cover dithers the art into the square, brighter pixels get more dots" {
    var bufs: Buffers = .{};
    defer bufs.deinit(testing.allocator);
    var m: Motion = .{};
    var px: [16 * 16]u8 = undefined;
    for (0..16) |y| for (0..16) |x| {
        px[y * 16 + x] = @intCast(x * 17);
    };
    var cv = try bufs.canvas(testing.allocator, 40, 10);
    render(&cv, COVER, &.{}, &m, .{ .paused = true }, 1, .{ .px = &px, .side = 16 });
    var left: u32 = 0;
    var right: u32 = 0;
    for (0..cv.h) |y| {
        try testing.expectEqual(@as(u21, ' '), cv.at(0, y).cp);
        try testing.expectEqual(@as(u21, ' '), cv.at(cv.w - 1, y).cp);
        for (10..20) |x| left += @popCount(cv.at(x, y).cp -% 0x2800 & 0xff);
        for (20..30) |x| right += @popCount(cv.at(x, y).cp -% 0x2800 & 0xff);
    }
    try testing.expect(right > left * 2);
}

test "halftone dots swell with the level" {
    var bufs: Buffers = .{};
    defer bufs.deinit(testing.allocator);
    var dots: [2]u32 = .{ 0, 0 };
    for ([_]f32{ 0.05, 1 }, 0..) |level, i| {
        var m: Motion = .{};
        var cv = try bufs.canvas(testing.allocator, 60, 20);
        render(&cv, indexOf("halftone", &.{}).?, &.{}, &m, .{ .level = level, .paused = false, .bands = @splat(level) }, 1, .{});
        for (cv.cells) |c| if (c.cp >= 0x2800 and c.cp < 0x2900) {
            dots[i] += @popCount(c.cp - 0x2800);
        };
    }
    try testing.expect(dots[1] > dots[0] + dots[0] / 2);
}

test "rain falls: the same column keeps its drop and moves it down" {
    var bufs: Buffers = .{};
    defer bufs.deinit(testing.allocator);
    var m: Motion = .{ .density = 1 };
    const loud: Audio = .{ .level = 1, .paused = false };
    var cv = try bufs.canvas(testing.allocator, 40, 30);
    render(&cv, indexOf("rain", &.{}).?, &.{}, &m, loud, 1, .{});
    var lit: usize = 0;
    for (cv.cells) |c| if (c.class == .strong) {
        lit += 1;
    };
    try testing.expect(lit > 10);
    const before = m.rain;
    cv = try bufs.canvas(testing.allocator, 13, 7);
    render(&cv, indexOf("rain", &.{}).?, &.{}, &m, loud, 2, .{});
    try testing.expect(m.rain > before and m.rain - before < 1);
}

test "cover without art says why in the middle of the canvas" {
    var bufs: Buffers = .{};
    defer bufs.deinit(testing.allocator);
    var m: Motion = .{};
    var cv = try bufs.canvas(testing.allocator, 40, 10);
    render(&cv, COVER, &.{}, &m, .{}, 1, .{ .note = "no cover" });
    try testing.expectEqual(@as(u21, 'n'), cv.at(16, 5).cp);
    try testing.expectEqual(Class.dim, cv.at(16, 5).class);
}

test "bars follow the spectrum: loud lows stand taller than quiet highs" {
    var bufs: Buffers = .{};
    defer bufs.deinit(testing.allocator);
    var m: Motion = .{};
    var a: Audio = .{ .level = 0.7, .paused = false };
    for (0..BANDS) |i| a.bands[i] = if (i < 5) 0.9 else 0.1;
    var cv = try bufs.canvas(testing.allocator, 60, 20);
    for (1..20) |t| render(&cv, indexOf("bars", &.{}).?, &.{}, &m, a, t, .{});
    var left: u32 = 0;
    var right: u32 = 0;
    for (0..cv.h) |y| for (0..cv.w) |x| {
        const c = cv.at(x, y);
        if (c.cp < 0x2800 or c.cp > 0x28ff) continue;
        if (x < 15) left += @popCount(c.cp - 0x2800) else if (x >= 45) right += @popCount(c.cp - 0x2800);
    };
    try testing.expect(left > right * 3);
}

test "the meter fires a beat on a bass hit and not on a steady tone" {
    var mt: Meter = .{};
    var quiet: [BANDS]f32 = @splat(0.2);
    for (0..40) |_| _ = mt.update(false, 0.4, 0.4, 0.4, 0.3, quiet);
    try testing.expect(mt.audio.beat < 0.1);
    quiet[1] = 1;
    quiet[2] = 1;
    quiet[3] = 1;
    quiet[4] = 1;
    try testing.expect(mt.update(false, 0.8, 0.8, 0.8, 0.3, quiet).beat > 0.9);
    try testing.expect(mt.update(true, 0, 0, 0, 0, quiet).bands[2] < 1);
}

test "old visualizer names still find their successors" {
    try testing.expectEqual(indexOf("hypercube", &.{}), indexOf("cube", &.{}));
    try testing.expectEqual(indexOf("ripple", &.{}), indexOf("rings", &.{}));
    try testing.expectEqual(indexOf("orbit", &.{}), indexOf("dither", &.{}));
    try testing.expectEqual(indexOf("plasma", &.{}), indexOf("warp", &.{}));
    try testing.expectEqual(@as(?usize, COVER), indexOf("cover", &.{}));
}

test "the arc strip stays on its row and lies flat when paused" {
    var bufs: Buffers = .{};
    defer bufs.deinit(testing.allocator);
    var m: Motion = .{};
    var a: Audio = .{ .level = 1, .paused = false };
    a.bands = @splat(1);
    for ([_]usize{ 1, 2, 9, 80 }) |w| {
        var cv = try bufs.canvas(testing.allocator, w, 1);
        strip(&cv, &m, a, w);
        strip(&cv, &m, .{}, w + 1);
        for (cv.cells) |c| try testing.expect(c.cp == ' ' or (c.cp >= 0x2800 and c.cp <= 0x28ff));
    }
}
