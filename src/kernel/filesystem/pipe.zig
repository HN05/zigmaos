const kernel = @import("root");

const File = @import("file.zig");

const conc = kernel.concurrency;
const mem = kernel.memory;
const execution = kernel.execution;
const UserAddress = mem.address.UserAddress;

const pipe_size = 512;

lock: conc.Mutex,
data: [pipe_size]u8,
read_count: u32, // number of bytes read
write_count: u32, // number of bytes written
read_is_open: bool, // read fd is still open
write_is_open: bool, // write fd is still open

const Pipe = @This();

pub fn alloc(read_file: **File, write_file: **File) !void {
    read_file.* = File.alloc() orelse return error.CouldNotAllocateFile;
    errdefer read_file.*.close();

    write_file.* = File.alloc() orelse return error.CouldNotAllocateFile;
    errdefer write_file.*.close();

    const page = mem.allocation.allocPage(.garbage) orelse return error.CouldNotAllocatePipe;
    errdefer mem.allocation.freePage(page);

    const pipe: *Pipe = @ptrCast(page);
    pipe.read_is_open = true;
    pipe.write_is_open = true;
    pipe.read_count = 0;
    pipe.write_count = 0;
    pipe.lock = .init(.spin, "pipe");

    read_file.*.data = .{ .pipe = pipe };
    read_file.*.is_readable = true;
    read_file.*.is_writeable = false;

    write_file.*.data = .{ .pipe = pipe };
    write_file.*.is_readable = false;
    write_file.*.is_writeable = true;
}

pub fn close(pipe: *Pipe, close_write: bool) void {
    var free_pipe = false;
    {
        pipe.lock.acquire();
        defer pipe.lock.release();

        if (close_write) {
            pipe.write_is_open = false;
            execution.scheduler.wakeup(&pipe.read_count);
        } else {
            pipe.read_is_open = false;
            execution.scheduler.wakeup(&pipe.write_count);
        }
        if (!pipe.read_is_open and !pipe.write_is_open) {
            free_pipe = true;
        }
    }
    if (free_pipe) mem.allocation.freePage(@ptrCast(@alignCast(pipe))) catch @panic("could not free pipe");
}

pub fn write(pipe: *Pipe, address: UserAddress, write_count: u32) !u32 {
    const process = execution.Process.getCurrentForce();

    pipe.lock.acquire();
    defer pipe.lock.release();

    var bytes_written: u32 = 0;

    while (bytes_written < write_count) {
        if (!pipe.read_is_open) return error.PipeReadIsClosed;
        if (process.isKilled()) return error.ProcessKilled;

        if (pipe.write_count == pipe.read_count + pipe_size) {
            // pipewrite full
            execution.scheduler.wakeup(&pipe.read_count);
            pipe.lock.sleepOn(&pipe.write_count);
        } else {
            const available_space = pipe_size - (pipe.write_count - pipe.read_count);
            const bytes_to_write = @min(available_space, write_count - bytes_written);

            const write_position = pipe.write_count % pipe_size;
            const bytes_until_end = pipe_size - write_position;
            const chunked_write_count = @min(bytes_until_end, bytes_to_write);
            const write_end = write_position + chunked_write_count;

            mem.boundry.copyIn(process.pageTable, pipe.data[write_position..write_end], address.add(bytes_written)) catch break;
            bytes_written += chunked_write_count;
            pipe.write_count += chunked_write_count;
        }
    }

    execution.scheduler.wakeup(&pipe.read_count);

    return bytes_written;
}

pub fn read(pipe: *Pipe, address: UserAddress, read_count: u32) !u32 {
    const process = execution.Process.getCurrentForce();

    pipe.lock.acquire();
    defer pipe.lock.release();

    // check if pipe empty
    while (pipe.read_count == pipe.write_count and pipe.write_is_open) {
        // wait for data to enter pipe
        if (process.isKilled()) return error.ProcessKilled;
        pipe.lock.sleepOn(&pipe.read_count);
    }

    var bytes_read: u32 = 0;

    while (bytes_read < read_count) {
        const bytes_remaining = pipe.write_count - pipe.read_count;
        if (bytes_remaining == 0) break;
        const bytes_to_read = @min(bytes_remaining, read_count - bytes_read);

        const read_position = pipe.read_count % pipe_size;
        const bytes_until_end = pipe_size - read_position;

        const chunked_read_count = @min(bytes_until_end, bytes_to_read);
        const end_read = read_position + chunked_read_count;

        mem.boundry.copyOut(process.pageTable, address.add(bytes_read), pipe.data[read_position..end_read]) catch break;
        bytes_read += chunked_read_count;
        pipe.read_count += chunked_read_count;
    }

    execution.scheduler.wakeup(&pipe.write_count);

    return bytes_read;
}
