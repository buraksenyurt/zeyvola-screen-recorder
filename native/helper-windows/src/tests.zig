//! The unit tests (zig build test): the parts that need no Windows call, on the host.
test {
    _ = @import("line.zig");
    _ = @import("parse.zig");
    _ = @import("wav.zig");
}
