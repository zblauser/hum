// Test aggregator root. `zig build test` compiles this; referencing each module
// with `_ = @import(...)` forces its colocated `test` blocks to be included
// (importing a module for its functions alone does not pull in its tests).
test {
    _ = @import("theme.zig");
    _ = @import("history.zig");
    _ = @import("playlist.zig");
    _ = @import("suggest.zig");
    _ = @import("fsutil.zig");
    _ = @import("api.zig");
    _ = @import("ui.zig");
    _ = @import("log.zig");
}
