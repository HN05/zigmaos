const SpinLock = @import("spinlock.zig");
const SleepLock = @import("sleeplock.zig");
const execution = @import("../execution.zig");

pub const LockType = enum { spin, sleep };

const Backing = union(LockType) {
    spin: SpinLock,
    sleep: SleepLock,

    fn switchCall(self: *Backing, comptime method: []const u8, comptime Return: type) Return {
        return switch (self.*) {
            inline else => |*lock| @field(@TypeOf(lock.*), method)(lock),
        };
    }
};

const Reference = union(enum) {
    spin: *SpinLock,
    sleep: *SleepLock,
    mutex: *Mutex,

    fn switchCall(self: *Reference, comptime method: []const u8, comptime Return: type) Return {
        return switch (self.*) {
            inline else => |lock| @field(@TypeOf(lock.*), method)(lock),
        };
    }
};

pub const Mutex = union(enum) {
    backing: Backing,
    reference: Reference,

    pub fn init(kind: LockType, name: []const u8) Mutex {
        return .{
            .backing = switch (kind) {
                .spin => .{ .spin = .{ .name = name } },
                .sleep => .{ .sleep = .{ .name = name } },
            },
        };
    }

    pub fn fromPtr(pointer: *Mutex) Mutex {
        return .{ .reference = pointer };
    }

    fn switchCall(self: *Mutex, comptime method: []const u8, comptime Return: type) Return {
        return switch (self.*) {
            .backing => |*backing| backing.switchCall(method, Return),
            .reference => |*reference| reference.switchCall(method, Return),
        };
    }

    pub fn acquire(self: *Mutex) void {
        self.switchCall("acquire", void);
    }

    pub fn release(self: *Mutex) void {
        self.switchCall("release", void);
    }

    pub fn isHolding(self: *Mutex) bool {
        return self.switchCall("isHolding", bool);
    }

    // Atomically release lock and sleep on chan.
    // Reacquires lock when awakened.
    pub fn sleepWithLock(self: *Mutex, channel: *anyopaque) void {
        execution.scheduler.sleepWithLock(self, channel);
    }
};
