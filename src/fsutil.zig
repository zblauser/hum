const std = @import("std");

/// The one libc @cImport for the program; FreeBSD translate-c workarounds live here.
pub const c = @cImport({
    // FreeBSD's __ssp fortify wrappers break translate-c; disable them
    @cDefine("_FORTIFY_SOURCE", "0");
    @cInclude("stdio.h");
    @cInclude("stdlib.h");
    @cInclude("errno.h");
    @cInclude("unistd.h");
});

/// Our own files (history, playlists, config) are small by construction.
const READ_ALL_CAP: usize = 8 * 1024 * 1024;

pub fn readFileAlloc(arena: std.mem.Allocator, file_path: []const u8) ?[]u8 {
    return readCappedAlloc(arena, file_path, READ_ALL_CAP);
}

/// Reads at most `max` bytes: a tag read must never be sized by the file.
pub fn readCappedAlloc(arena: std.mem.Allocator, file_path: []const u8, max: usize) ?[]u8 {
    const path_z = arena.dupeZ(u8, file_path) catch return null;
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

/// LEGACY_DIR is the pre-v0.1.7 name; see `xdgPath`.
const APP_DIR = "hum";
const LEGACY_DIR = "ytcli";

fn exists(path: [:0]const u8) bool {
    return c.access(path.ptr, c.F_OK) == 0;
}

/// Falls back to the legacy dir when the new path does not exist, and copies nothing: an upgrade keeps working with no migration step.
pub fn xdgPath(
    arena: std.mem.Allocator,
    env: *std.process.Environ.Map,
    xdg_var: []const u8,
    fallback_dir: []const u8,
    file: []const u8,
) ![:0]const u8 {
    const base: []const u8 = if (env.get(xdg_var)) |x|
        x
    else blk: {
        const home = env.get("HOME") orelse return error.NoHome;
        break :blk try std.fmt.allocPrint(arena, "{s}/{s}", .{ home, fallback_dir });
    };

    const current = try std.fmt.allocPrintSentinel(arena, "{s}/{s}/{s}", .{ base, APP_DIR, file }, 0);
    if (exists(current)) return current;

    const legacy = try std.fmt.allocPrintSentinel(arena, "{s}/{s}/{s}", .{ base, LEGACY_DIR, file }, 0);
    if (exists(legacy)) return legacy;

    return current;
}

/// Create the parent directory, then write (mode "wb") or append (mode "ab") bytes.
fn writeMode(arena: std.mem.Allocator, file_path: []const u8, bytes: []const u8, mode: [*:0]const u8) !void {
    if (std.fs.path.dirname(file_path)) |dir| try makePathZ(arena, dir);
    const path_z = try arena.dupeZ(u8, file_path);
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

pub fn makePathZ(arena: std.mem.Allocator, dir: []const u8) !void {
    var i: usize = 0;
    while (i < dir.len) {
        while (i < dir.len and dir[i] == '/') : (i += 1) {}
        const start = i;
        while (i < dir.len and dir[i] != '/') : (i += 1) {}
        if (i == start) break;
        const partial = try arena.dupeZ(u8, dir[0..i]);
        const r = std.c.mkdir(partial.ptr, 0o755);
        if (r != 0) {
            const e = std.c._errno().*;
            if (e != c.EEXIST) return error.MkdirFailed;
        }
    }
}

const testing = std.testing;

test "readFileAlloc round-trips contents; null on empty or missing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const path = try a.dupeZ(u8, "/tmp/hum_rfa_XXXXXX");
    const fd = c.mkstemp(path.ptr);
    try testing.expect(fd >= 0);
    defer _ = c.unlink(path.ptr);
    const data = "hello\nworld";
    try testing.expectEqual(@as(isize, data.len), c.write(fd, data.ptr, data.len));
    _ = c.close(fd);

    const got = readFileAlloc(a, path) orelse return error.TestUnexpectedNull;
    try testing.expectEqualStrings("hello\nworld", got);

    const empty = try a.dupeZ(u8, "/tmp/hum_rfae_XXXXXX");
    const efd = c.mkstemp(empty.ptr);
    try testing.expect(efd >= 0);
    defer _ = c.unlink(empty.ptr);
    _ = c.close(efd);
    try testing.expect(readFileAlloc(a, empty) == null);

    try testing.expect(readFileAlloc(a, "/tmp/hum_definitely_missing_zzz") == null);
}

test "makePathZ creates nested dirs and is idempotent" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const base = try a.dupeZ(u8, "/tmp/hum_mp_XXXXXX");
    try testing.expect(c.mkdtemp(base.ptr) != null);

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

    const base = try a.dupeZ(u8, "/tmp/hum_xdg_XXXXXX");
    try testing.expect(c.mkdtemp(base.ptr) != null);

    const new_dir = try std.fmt.allocPrintSentinel(a, "{s}/hum", .{base}, 0);
    const old_dir = try std.fmt.allocPrintSentinel(a, "{s}/ytcli", .{base}, 0);
    const new_file = try std.fmt.allocPrintSentinel(a, "{s}/hum/history", .{base}, 0);
    const old_file = try std.fmt.allocPrintSentinel(a, "{s}/ytcli/history", .{base}, 0);
    defer {
        _ = c.unlink(new_file.ptr);
        _ = c.unlink(old_file.ptr);
        _ = c.rmdir(new_dir.ptr);
        _ = c.rmdir(old_dir.ptr);
        _ = c.rmdir(base.ptr);
    }

    var env: std.process.Environ.Map = .init(a);
    try env.put("XDG_DATA_HOME", base);

    // fresh install gets the new path
    try testing.expectEqualStrings(new_file, try xdgPath(a, &env, "XDG_DATA_HOME", ".local/share", "history"));

    // only the legacy file exists: keep reading it
    try writeFile(a, old_file, "elephant gym\n");
    try testing.expectEqualStrings(old_file, try xdgPath(a, &env, "XDG_DATA_HOME", ".local/share", "history"));

    // the new path wins once it exists
    try writeFile(a, new_file, "autechre\n");
    try testing.expectEqualStrings(new_file, try xdgPath(a, &env, "XDG_DATA_HOME", ".local/share", "history"));
}

test "xdgPath falls back to HOME and still honors the legacy dir" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var env: std.process.Environ.Map = .init(a);
    try env.put("HOME", "/home/u");
    try testing.expectEqualStrings("/home/u/.config/hum/config", try xdgPath(a, &env, "XDG_CONFIG_HOME", ".config", "config"));

    var empty: std.process.Environ.Map = .init(a);
    try testing.expectError(error.NoHome, xdgPath(a, &empty, "XDG_DATA_HOME", ".local/share", "log"));
}
