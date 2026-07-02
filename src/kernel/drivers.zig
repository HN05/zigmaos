const virtio = @import("drivers/virtio.zig");

pub const uart = @import("drivers/uart.zig");
pub const console = @import("drivers/console.zig");
pub const disk = virtio.disk_driver;
