// modules
pub const concurrency = @import("concurrency/mod.zig");
pub const execution = @import("execution/mod.zig");
pub const drivers = @import("drivers/mod.zig");
pub const filesystem = @import("filesystem/mod.zig");
pub const memory = @import("memory/mod.zig");
pub const traps = @import("traps/mod.zig");

// for starting kernel
const std = @import("std");
const start_file = @import("start.zig");
const param = @import("common").param;
const log_root = @import("klog.zig");

export fn start() void {
    start_file.start();
}

// entry.S needs one stack per CPU.
const stack_size: usize = 4096 * param.NCPU;

// entry.S needs one stack per CPU.
export var stack0 align(16) = [_]u8{0} ** stack_size;

pub const std_options = std.Options{
    // Set the log level to info
    .log_level = .debug,
    // Define logFn to override the std implementation
    .logFn = log_root.klogFn,
};

pub fn panic(
    msg: []const u8,
    error_return_trace: ?*std.builtin.StackTrace,
    _: ?usize,
) noreturn {
    @branchHint(.cold);
    _ = error_return_trace;
    const panic_log = std.log.scoped(.panic);
    log_root.locking = false;
    panic_log.err("{s}\n", .{msg});
    log_root.panicked = true; // freeze uart output from other CPUs
    while (true) {}
}
