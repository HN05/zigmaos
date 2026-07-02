const virtio = @import("virtio.zig");

pub const uart = @import("uart.zig");
pub const console = @import("console.zig");
pub const disk = virtio.disk_driver;
