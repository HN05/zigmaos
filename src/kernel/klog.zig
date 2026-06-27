const std = @import("std");
const mem = std.mem;
const fmt = std.fmt;
const SpinLock = @import("spinlock.zig").SpinLock;
const common = @import("common");
const Color = common.color.Color;
const console = @import("console.zig");

var lock: SpinLock = .{ .name = "klog" };
pub var locking: bool = true;
pub export var panicked: bool = false;

fn logLevelColor(lvl: std.log.Level) Color {
    return switch (lvl) {
        .err => .red,
        .warn => .yellow,
        .debug => .magenta,
        .info => .green,
    };
}

pub fn klogFn(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    @setRuntimeSafety(false);
    const need_lock = locking;
    if (need_lock) lock.acquire();
    defer if (need_lock) lock.release();

    const scope_prefix = "(" ++ comptime Color.dim.ttyStr() ++ @tagName(scope) ++ Color.reset.ttyStr() ++ ") ";

    const prefix = scope_prefix ++ "[" ++ comptime logLevelColor(level).ttyStr() ++ level.asText() ++ Color.reset.ttyStr() ++ "]: ";
    print(prefix ++ format ++ "\n", args);
}

export fn panic(s: [*:0]u8) noreturn {
    @branchHint(.cold);
    locking = false;
    console.writeBytes("!KERNEL PANIC!\n");
    console.writeBytes(mem.span(s));
    console.writeBytes("\n");
    panicked = true; // freeze uart output from other CPUs
    while (true) {}
}

pub fn print(comptime format: []const u8, args: anytype) void {
    //  TODO: make buf infinite
    var buf: [512]u8 = undefined;

    const out = std.fmt.bufPrint(&buf, format, args) catch {
        @panic("log message too long");
    };

    console.writeBytes(out);
}

pub export fn printf(format: [*:0]const u8, ...) void {
    @setRuntimeSafety(false);
    const need_lock = locking;
    if (need_lock) lock.acquire();
    defer if (need_lock) lock.release();

    if (std.mem.span(format).len == 0) @panic("null fmt");

    var ap = @cVaStart();
    var skip_idx: ?usize = null;
    for (std.mem.span(format), 0..) |byte, i| {
        if (skip_idx != null and i == skip_idx.?) {
            continue;
        }
        if (byte != '%') {
            console.writeByte(byte);
            continue;
        }
        const ch = format[i + 1] & 0xff;
        skip_idx = i + 1;
        if (ch == 0) break;
        switch (ch) {
            'd' => print("{d}", .{@cVaArg(&ap, c_int)}),
            'x' => print("{x}", .{@cVaArg(&ap, c_int)}),
            'p' => {
                const p = @cVaArg(&ap, *usize);
                print("{p}", .{p});
            },
            's' => {
                const s = std.mem.span(@cVaArg(&ap, [*:0]const u8));
                console.writeBytes(s);
            },
            '%' => console.writeByte('%'),
            else => {
                // Print unknown % sequence to draw attention.
                console.writeByte('%');
                console.writeByte(ch);
            },
        }
    }
    @cVaEnd(&ap);
}
