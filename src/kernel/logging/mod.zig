const klog = @import("klog.zig");

pub const print = klog.print;
pub const printf = klog.printf;
pub const klogFn = klog.klogFn;
pub const locking = &klog.locking;
pub const panicked = &klog.panicked;

//  TODO: implement
pub fn debugLog(comptime fmt: []const u8, args: anytype) void {
    _ = fmt;
    _ = args;
}
