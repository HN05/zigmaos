const Inode = @import("inode.zig");
const Pipe = @import("pipe.zig");
const Device = @import("device.zig");
const std = @import("std");
const common = @import("common");
const log = @import("log.zig");
const ad = @import("address.zig");
const fs = @import("filesystem.zig");
const mem = @import("memory.zig");
const execution = @import("execution.zig");
const conc = @import("concurrency.zig");

pub const FileType = enum {
    none,
    pipe,
    inode,
    device,
};

pub const FileData = union(FileType) {
    none: void,
    pipe: *Pipe,
    inode: struct {
        inode: *Inode,
        offset: u32,
    },
    device: struct {
        inode: *Inode,
        device_id: Device.ID,
    },
};

const File = @This();

reference_count: u32 = 0,
is_readable: bool = false,
is_writeable: bool = false,
data: FileData = .none,

pub fn getType(file: *const File) FileType {
    return std.meta.activeTag(file.data);
}

// must check before that is either inode or device type
pub fn getInode(file: *const File) *Inode {
    return switch (file.data) {
        .inode => |inode| inode.inode,
        .device => |device| device.inode,
        else => @panic("can't get inode of non inode containing file"),
    };
}

pub fn hasInode(file: *const File) bool {
    return file.data == .device or file.data == .inode;
}

const FileTable = struct {
    lock: conc.Mutex = .init(.spin, "FileTable"),
    files: [common.param.NFILE]File = [_]File{.{}} ** common.param.NFILE,
};

var file_table: FileTable = .{};

// Allocate a file structure.
pub fn alloc() ?*File {
    file_table.lock.acquire();
    defer file_table.lock.release();
    for (&file_table.files) |*file| {
        if (file.reference_count == 0) {
            file.reference_count = 1;
            return file;
        }
    }
    return null;
}

// Increment ref count for file f.
pub fn duplicate(file: *File) *File {
    file_table.lock.acquire();
    defer file_table.lock.release();

    if (file.reference_count < 1) @panic("file duplication failed");
    file.reference_count += 1;
    return file;
}

// Close file f.  (Decrement ref count, close when reaches 0.)
pub fn close(file: *File) void {
    var closed_file: File = undefined;
    // update file table
    {
        file_table.lock.acquire();
        defer file_table.lock.release();

        if (file.reference_count < 1) @panic("file closing failed");

        file.reference_count -= 1;
        if (file.reference_count > 0) {
            return;
        }

        // close file completely
        closed_file = file.*;
        file.reference_count = 0;
        file.data = .none;
    }
    // clean up file data
    switch (closed_file.data) {
        .pipe => |pipe| {
            pipe.close(closed_file.is_writeable);
        },
        .inode, .device => {
            log.beginOperation();
            defer log.endOperation();

            closed_file.getInode().put();
        },
        .none => return,
    }
}

// Get metadata about file f.
// addr is a user virtual address, pointing to a struct stat.
pub fn getStatus(file: *const File, destination_address: ad.UserAddress) !void {
    if (!file.hasInode()) return error.WrongFileType;

    var status: fs.FileStatus = undefined;
    // get status
    {
        const inode = file.getInode();
        inode.lock();
        defer inode.release();
        status = inode.getStatus();
    }

    const process = execution.Process.getCurrentForce();
    try mem.copyOut(process.pageTable, destination_address, std.mem.asBytes(&status));
}

// Read from file f.
// addr is a user virtual address.
pub fn read(file: *File, address: ad.UserAddress, read_count: u32) !u32 {
    if (!file.is_readable) return error.FileNotReadable;

    var bytes_read: u32 = 0;

    switch (file.data) {
        .pipe => |pipe| {
            bytes_read = try pipe.read(address, read_count);
        },
        .device => |device| {
            if (device.device_id.major >= Device.deviceTable.len) return error.DeviceMajorCorrupted;
            if (Device.deviceTable[device.device_id.major].read) |deviceRead| {
                bytes_read = try deviceRead(.{ .user = address }, read_count);
            } else return error.DeviceCantRead;
        },
        .inode => |*inode_file| {
            inode_file.inode.lock();
            defer inode_file.inode.release();

            bytes_read = try inode_file.inode.read(.{ .user = address }, inode_file.offset, read_count);
            inode_file.offset += bytes_read;
        },
        .none => @panic("can't read from unallocated file"),
    }

    return bytes_read;
}

// Write to file f.
// addr is a user virtual address.
pub fn write(file: *File, address: ad.UserAddress, write_count: u32) !u32 {
    if (!file.is_writeable) return error.FileNotWriteable;

    var bytes_written: u32 = 0;

    switch (file.data) {
        .pipe => |pipe| {
            bytes_written = try pipe.write(address, write_count);
        },
        .device => |device| {
            if (device.device_id.major >= Device.deviceTable.len) return error.DeviceMajorCorrupted;
            if (Device.deviceTable[device.device_id.major].write) |deviceWrite| {
                bytes_written = try deviceWrite(.{ .user = address }, write_count);
            } else return error.DeviceCantWrite;
        },
        .inode => |*inode_file| {
            const inode = inode_file.inode;

            //  TODO:
            // write a few blocks at a time to avoid exceeding
            // the maximum log transaction size, including
            // i-node, indirect block, allocation blocks,
            // and 2 blocks of slop for non-aligned writes.
            // this really belongs lower down, since writei()
            // might be writing a device like the console.
            const max_bytes = (common.param.max_num_operation_blocks - 1 - 1 - 2) / 2 * fs.block_size;

            while (bytes_written < write_count) {
                const bytes_to_write = @min(write_count - bytes_written, max_bytes);

                {
                    log.beginOperation();
                    defer log.endOperation();

                    inode.lock();
                    defer inode.release();

                    const iteration_bytes_written = try inode.write(.{ .user = address.add(bytes_written) }, inode_file.offset, bytes_to_write);
                    inode_file.offset += iteration_bytes_written;

                    if (iteration_bytes_written != bytes_to_write) break; // error from inode write
                    bytes_written += iteration_bytes_written;
                }
            }
            if (bytes_written != write_count) return error.WriteToInodeFailed;
        },
        .none => @panic("can't write to unallocated file"),
    }

    return bytes_written;
}
