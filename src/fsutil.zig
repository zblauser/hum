const std = @import("std");
const builtin = @import("builtin");

const windows = builtin.os.tag == .windows;

pub const c = struct {
    pub const FILE = std.c.FILE;
    pub const fopen = std.c.fopen;
    pub const fclose = std.c.fclose;
    pub const fread = std.c.fread;
    pub const fwrite = std.c.fwrite;
    pub const unlink = std.c.unlink;
    pub const rmdir = std.c.rmdir;
    pub const access = std.c.access;
    pub const getenv = std.c.getenv;
    pub const _exit = std.c._exit;

    pub extern "c" fn fseek(stream: *FILE, offset: c_long, whence: c_int) c_int;
    pub extern "c" fn ftell(stream: *FILE) c_long;
    extern "c" fn mkstemp(template: [*:0]u8) c_int;
    extern "c" fn _mkdir(path: [*:0]const u8) c_int;
    extern "kernel32" fn GetTempPathA(len: u32, buf: [*]u8) callconv(.winapi) u32;
    extern "kernel32" fn GetTempFileNameA(dir: [*:0]const u8, prefix: [*:0]const u8, unique: u32, out: [*]u8) callconv(.winapi) u32;

    fn mkdir(path: [*:0]const u8) c_int {
        return if (windows) _mkdir(path) else std.c.mkdir(path, 0o755);
    }

    pub const SEEK_SET: c_int = 0;
    pub const SEEK_END: c_int = 2;
    pub const F_OK: c_uint = 0;
};

const READ_ALL_CAP: usize = 8 * 1024 * 1024;

pub fn readFileAlloc(arena: std.mem.Allocator, file_path: []const u8) ?[]u8 {
    return readCappedAlloc(arena, file_path, READ_ALL_CAP);
}

pub fn readCappedAlloc(arena: std.mem.Allocator, file_path: []const u8, max: usize) ?[]u8 {
    const path_z = arena.dupeSentinel(u8, file_path, 0) catch return null;
    const f = c.fopen(path_z.ptr, "rb") orelse return null;
    defer _ = c.fclose(f);

    _ = c.fseek(f, 0, c.SEEK_END);
    const size = c.ftell(f);
    if (size <= 0) return null;
    _ = c.fseek(f, 0, c.SEEK_SET);

    const want = @min(@as(usize, @intCast(size)), max);
    const buf = arena.alloc(u8, want) catch return null;
    const n = c.fread(buf.ptr, 1, buf.len, f);
    if (n == 0) return null;
    return buf[0..n];
}

const APP_DIR = "hum";
const LEGACY_DIR = "ytcli";

fn exists(path: [:0]const u8) bool {
    return c.access(path.ptr, c.F_OK) == 0;
}

pub fn xdgPath(
    arena: std.mem.Allocator,
    env: *std.process.Environ.Map,
    xdg_var: []const u8,
    fallback_dir: []const u8,
    file: []const u8,
) ![:0]const u8 {
    const sep = std.fs.path.sep;
    const base: []const u8 = if (env.get(xdg_var)) |x|
        x
    else if (windows)
        env.get(if (std.mem.eql(u8, xdg_var, "XDG_CONFIG_HOME")) "APPDATA" else "LOCALAPPDATA") orelse return error.NoHome
    else blk: {
        const home = env.get("HOME") orelse return error.NoHome;
        break :blk try std.fmt.allocPrint(arena, "{s}/{s}", .{ home, fallback_dir });
    };

    const current = try std.fmt.allocPrintSentinel(arena, "{s}{c}{s}{c}{s}", .{ base, sep, APP_DIR, sep, file }, 0);
    if (exists(current)) return current;

    const legacy = try std.fmt.allocPrintSentinel(arena, "{s}{c}{s}{c}{s}", .{ base, sep, LEGACY_DIR, sep, file }, 0);
    if (exists(legacy)) return legacy;

    return current;
}

fn writeMode(arena: std.mem.Allocator, file_path: []const u8, bytes: []const u8, mode: [*:0]const u8) !void {
    if (std.fs.path.dirname(file_path)) |dir| try makePathZ(arena, dir);
    const path_z = try arena.dupeSentinel(u8, file_path, 0);
    const f = c.fopen(path_z.ptr, mode) orelse return error.OpenFailed;
    defer _ = c.fclose(f);
    if (bytes.len == 0) return;
    if (c.fwrite(bytes.ptr, 1, bytes.len, f) != bytes.len) return error.WriteFailed;
}

pub fn writeFile(arena: std.mem.Allocator, file_path: []const u8, bytes: []const u8) !void {
    return writeMode(arena, file_path, bytes, "wb");
}

pub fn appendFile(arena: std.mem.Allocator, file_path: []const u8, bytes: []const u8) !void {
    return writeMode(arena, file_path, bytes, "ab");
}

pub fn makeTemp(arena: std.mem.Allocator, prefix: []const u8, contents: []const u8) ![:0]u8 {
    const path = if (windows) blk: {
        var dir: [261:0]u8 = undefined;
        const n = c.GetTempPathA(dir.len, &dir);
        if (n == 0 or n >= dir.len) return error.TempFileOpen;
        dir[n] = 0;
        const pre = try arena.dupeSentinel(u8, prefix, 0);
        var out: [261]u8 = undefined;
        if (c.GetTempFileNameA(&dir, pre.ptr, 0, &out) == 0) return error.TempFileOpen;
        break :blk try arena.dupeSentinel(u8, std.mem.sliceTo(&out, 0), 0);
    } else blk: {
        const p = try std.fmt.allocPrintSentinel(arena, "/tmp/{s}XXXXXX", .{prefix}, 0);
        const fd = c.mkstemp(p.ptr);
        if (fd < 0) return error.TempFileOpen;
        _ = std.c.close(fd);
        break :blk p;
    };
    errdefer _ = c.unlink(path.ptr);
    writeFile(arena, path, contents) catch return error.TempFileWrite;
    return path;
}

fn isSep(b: u8) bool {
    return b == '/' or (windows and b == '\\');
}

pub fn makePathZ(arena: std.mem.Allocator, dir: []const u8) !void {
    var i: usize = 0;
    while (i < dir.len) {
        while (i < dir.len and isSep(dir[i])) : (i += 1) {}
        const start = i;
        while (i < dir.len and !isSep(dir[i])) : (i += 1) {}
        if (i == start) break;
        const partial = try arena.dupeSentinel(u8, dir[0..i], 0);
        if (exists(partial)) continue;
        if (c.mkdir(partial.ptr) != 0 and !exists(partial)) return error.MkdirFailed;
    }
}

const testing = std.testing;
const S = std.fs.path.sep_str;

test "readFileAlloc round-trips contents; null on empty or missing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const path = try makeTemp(a, "hum_rfa_", "hello\nworld");
    defer _ = c.unlink(path.ptr);

    const got = readFileAlloc(a, path) orelse return error.TestUnexpectedNull;
    try testing.expectEqualStrings("hello\nworld", got);

    const empty = try makeTemp(a, "hum_rfae_", "");
    defer _ = c.unlink(empty.ptr);
    try testing.expect(readFileAlloc(a, empty) == null);

    try testing.expect(readFileAlloc(a, "/tmp/hum_definitely_missing_zzz") == null);
}

test "makePathZ creates nested dirs and is idempotent" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const base = try makeTemp(a, "hum_mp_", "");
    _ = c.unlink(base.ptr);
    try makePathZ(a, base);

    const mid = try std.fmt.allocPrintSentinel(a, "{s}/a", .{base}, 0);
    const nested = try std.fmt.allocPrintSentinel(a, "{s}/a/b", .{base}, 0);
    const leaf = try std.fmt.allocPrintSentinel(a, "{s}/a/b/f", .{base}, 0);
    defer {
        _ = c.unlink(leaf.ptr);
        _ = c.rmdir(nested.ptr);
        _ = c.rmdir(mid.ptr);
        _ = c.rmdir(base.ptr);
    }

    try makePathZ(a, nested);
    try makePathZ(a, nested);

    const f = c.fopen(leaf.ptr, "wb") orelse return error.TestUnexpectedNull;
    _ = c.fclose(f);
}

test "xdgPath prefers the new dir, falls back to the pre-rename one" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const base = try makeTemp(a, "hum_xdg_", "");
    _ = c.unlink(base.ptr);
    try makePathZ(a, base);

    const new_dir = try std.fmt.allocPrintSentinel(a, "{s}" ++ S ++ "hum", .{base}, 0);
    const old_dir = try std.fmt.allocPrintSentinel(a, "{s}" ++ S ++ "ytcli", .{base}, 0);
    const new_file = try std.fmt.allocPrintSentinel(a, "{s}" ++ S ++ "hum" ++ S ++ "history", .{base}, 0);
    const old_file = try std.fmt.allocPrintSentinel(a, "{s}" ++ S ++ "ytcli" ++ S ++ "history", .{base}, 0);
    defer {
        _ = c.unlink(new_file.ptr);
        _ = c.unlink(old_file.ptr);
        _ = c.rmdir(new_dir.ptr);
        _ = c.rmdir(old_dir.ptr);
        _ = c.rmdir(base.ptr);
    }

    var env: std.process.Environ.Map = .init(a);
    try env.put("XDG_DATA_HOME", base);

    try testing.expectEqualStrings(new_file, try xdgPath(a, &env, "XDG_DATA_HOME", ".local/share", "history"));

    try writeFile(a, old_file, "elephant gym\n");
    try testing.expectEqualStrings(old_file, try xdgPath(a, &env, "XDG_DATA_HOME", ".local/share", "history"));

    try writeFile(a, new_file, "autechre\n");
    try testing.expectEqualStrings(new_file, try xdgPath(a, &env, "XDG_DATA_HOME", ".local/share", "history"));
}

test "xdgPath falls back to HOME and still honors the legacy dir" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var env: std.process.Environ.Map = .init(a);
    if (windows) {
        try env.put("APPDATA", "C:\\r");
        try env.put("LOCALAPPDATA", "C:\\l");
        try testing.expectEqualStrings("C:\\r\\hum\\config", try xdgPath(a, &env, "XDG_CONFIG_HOME", ".config", "config"));
        try testing.expectEqualStrings("C:\\l\\hum\\log", try xdgPath(a, &env, "XDG_DATA_HOME", ".local/share", "log"));
    } else {
        try env.put("HOME", "/home/u");
        try testing.expectEqualStrings("/home/u/.config/hum/config", try xdgPath(a, &env, "XDG_CONFIG_HOME", ".config", "config"));
    }

    var empty: std.process.Environ.Map = .init(a);
    try testing.expectError(error.NoHome, xdgPath(a, &empty, "XDG_DATA_HOME", ".local/share", "log"));
}
