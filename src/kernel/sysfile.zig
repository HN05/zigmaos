//
// File-system system calls.
// Mostly argument checking, since we don't trust
// user code, and calls into file.c and fs.c.
//

const std = @import("std");
const kernel = @import("root");
const common = @import("common");

const sysargs = @import("sysargs.zig");
const log = @import("debuglog.zig");
const kalloc = @import("kalloc.zig");
const address = @import("address.zig");
const mem = @import("memory.zig");
const execFile = @import("exec.zig");
const Inode = @import("inode.zig");
const File = @import("file.zig");
const Device = @import("device.zig");
const fslog = @import("log.zig");
const Directory = @import("directory.zig");
const fs = @import("filesystem.zig");
const Pipe = @import("pipe.zig");
const ad = @import("address.zig");

const page_size = common.riscv.page_size;
const param = common.param;
const Process = kernel.execution.Process;

pub fn sys_dup() u64 {
    const file = sysargs.getFile(.a0) catch |err| {
        log.print("could not get file: {s}", .{@errorName(err)});
        return sysargs.errorVal;
    };

    const fd = sysargs.fileDescriptorAllocate(file) catch |err| {
        log.print("could not allocate new file descriptor: {s}", .{@errorName(err)});
        return sysargs.errorVal;
    };

    _ = file.duplicate();
    return fd;
}

pub fn sys_read() u64 {
    const destination = sysargs.getAddress(.a1) orelse return sysargs.errorVal;
    const number = sysargs.getInt(.a2);

    const file = sysargs.getFile(.a0) catch |err| {
        log.print("could not get file: {s}", .{@errorName(err)});
        return sysargs.errorVal;
    };

    return file.read(destination, @intCast(number)) catch sysargs.errorVal;
}

pub fn sys_write() u64 {
    const source = sysargs.getAddress(.a1) orelse return sysargs.errorVal;
    const number = sysargs.getInt(.a2);

    const file = sysargs.getFile(.a0) catch |err| {
        log.print("could not get file: {s}", .{@errorName(err)});
        return sysargs.errorVal;
    };

    return file.write(source, @intCast(number)) catch sysargs.errorVal;
}

pub fn sys_close() u64 {
    var file: *File = undefined;
    const fd = sysargs.getFileAndDescriptor(.a0, &file) catch |err| {
        log.print("could not get file: {s}", .{@errorName(err)});
        return sysargs.errorVal;
    };

    Process.getCurrentForce().openFiles[fd] = null;

    file.close();
    return 0;
}

pub fn sys_fstat() u64 {
    const stat = sysargs.getAddress(.a1) orelse return sysargs.errorVal;

    const file = sysargs.getFile(.a0) catch |err| {
        log.print("could not get file: {s}", .{@errorName(err)});
        return sysargs.errorVal;
    };

    file.getStatus(stat) catch return sysargs.errorVal;
    return 0;
}

pub fn sys_link() u64 {
    link() catch |err| {
        log.print("could not get link: {s}", .{@errorName(err)});
        return sysargs.errorVal;
    };
    return 0;
}

const LinkErrors = error{
    FailedGetOldPath,
    FailedGetNewPath,
    FailedGetInode,
    IsDirectory,
    FailedGetParentDir,
    NotSameDevice,
    FailedUpdateNewParDir,
};

// Create the path new as a link to the same inode as old.
pub fn link() LinkErrors!void {
    var old: [Inode.max_path_size]u8 = undefined;
    const old_length = sysargs.getString(.a0, &old) catch return LinkErrors.FailedGetOldPath;

    var new: [Inode.max_path_size]u8 = undefined;
    const new_length = sysargs.getString(.a1, &new) catch return LinkErrors.FailedGetNewPath;

    fslog.beginOperation();
    defer fslog.endOperation();

    const inode = Inode.resolvePath(old[0..old_length]) orelse return LinkErrors.FailedGetInode;
    defer inode.put();

    // increment references to inode
    {
        inode.lock();
        defer inode.release();

        if (inode.disk_inode.type == .directory) return LinkErrors.IsDirectory;

        inode.disk_inode.link_count += 1;
        inode.update();
    }

    // Roll back increment if it fails
    errdefer {
        inode.lock();
        inode.disk_inode.link_count -= 1;
        inode.update();
        inode.release();
    }

    // update directory
    {
        var name: []const u8 = undefined;
        const directory_inode = Inode.resolvePathParent(new[0..new_length], &name) orelse return LinkErrors.FailedGetParentDir;

        directory_inode.lock();
        defer directory_inode.releasePut();

        if (directory_inode.filesystem_device != inode.filesystem_device) return LinkErrors.NotSameDevice;

        const directory = Directory.init(directory_inode);
        directory.linkEntry(name, inode.inode_number) catch return LinkErrors.FailedUpdateNewParDir;
    }
}

pub fn sys_unlink() u64 {
    unlink() catch |err| {
        log.print("could not get link: {s}", .{@errorName(err)});
        return sysargs.errorVal;
    };
    return 0;
}

const UnlinkErrors = error{ FailedGetPath, FailedGetParentDir, IsDot, IsDotDot, FailedDirLookup, DirectoryNotEmpty };

pub fn unlink() UnlinkErrors!void {
    var path: [Inode.max_path_size]u8 = undefined;
    const path_length = sysargs.getString(.a0, &path) catch return UnlinkErrors.FailedGetPath;

    fslog.beginOperation();
    defer fslog.endOperation();

    var name: []const u8 = undefined;
    const directory_inode = Inode.resolvePathParent(path[0..path_length], &name) orelse return UnlinkErrors.FailedGetParentDir;

    directory_inode.lock();
    defer directory_inode.releasePut();

    if (std.mem.eql(u8, name, ".")) return UnlinkErrors.IsDot;
    if (std.mem.eql(u8, name, "..")) return UnlinkErrors.IsDotDot;

    const directory = Directory.init(directory_inode);

    var offset: u32 = undefined;
    const inode = directory.lookupChild(name, &offset) orelse return UnlinkErrors.FailedDirLookup;

    inode.lock();
    defer inode.releasePut();

    if (inode.disk_inode.link_count < 1) {
        @panic("unlink: nlink < 1");
    }

    if (inode.disk_inode.type == .directory) {
        const unlink_director = Directory.init(inode);
        if (!unlink_director.isEmpty()) return UnlinkErrors.DirectoryNotEmpty;
    }

    // remove directory entry
    {
        var directoryEntity = Directory.DirectoryEntry{};
        const directory_address = ad.AnyAddress{ .kernel = .fromPtr(&directoryEntity) };

        const writtenBytes = directory_inode.write(directory_address, offset, Directory.entry_size) catch @panic("unlink: could not read directory");
        if (writtenBytes != Directory.entry_size) {
            @panic("unlink: writei");
        }
    }

    if (inode.disk_inode.type == .directory) {
        directory_inode.disk_inode.link_count -= 1;
        directory_inode.update();
    }

    inode.disk_inode.link_count -= 1;
    inode.update();
}

const CreateErrors = error{ FailedGetParentDir, PathExistsWithWrongType, FailedAllocateInode, FailedCreateDot, FailedCreateDotDot, FailedLinkParentDir };

fn create(path: []const u8, kind: fs.FileType, device: Device.ID) CreateErrors!*Inode {
    var name: []const u8 = undefined;
    const parent_inode = Inode.resolvePathParent(path, &name) orelse return CreateErrors.FailedGetParentDir;

    parent_inode.lock();
    defer parent_inode.releasePut();

    const parent_directory = Directory.init(parent_inode);

    if (parent_directory.lookupChild(name, null)) |inode| {
        inode.lock();
        errdefer inode.releasePut();

        // already exists
        if (kind == .file and (inode.disk_inode.type == .file or inode.disk_inode.type == .device)) {
            return inode;
        }

        return CreateErrors.PathExistsWithWrongType;
    }

    const inode = Inode.alloc(parent_inode.filesystem_device, kind) catch return CreateErrors.FailedAllocateInode;

    inode.lock();
    errdefer {
        inode.disk_inode.link_count = 0;
        inode.update();
        inode.releasePut();
    }

    inode.disk_inode.device = device;
    inode.disk_inode.link_count = 1;
    inode.update();

    if (kind == .directory) {
        const directory = Directory.init(inode);

        // create . and .. entries
        directory.linkEntry(".", inode.inode_number) catch return CreateErrors.FailedCreateDot;
        directory.linkEntry("..", parent_inode.inode_number) catch return CreateErrors.FailedCreateDotDot;
    }

    parent_directory.linkEntry(name, inode.inode_number) catch return CreateErrors.FailedLinkParentDir;
    if (kind == .directory) {
        parent_inode.disk_inode.link_count += 1; // for ".."
        parent_inode.update();
    }

    return inode;
}

const AccessMode = enum(u2) {
    read_only = 0,
    write_only = 1,
    read_write = 2,
    invalid = 3, // need to check when you create that it is not that!!!

    pub fn isWritable(self: AccessMode) bool {
        return self != .read_only;
    }

    pub fn isReadable(self: AccessMode) bool {
        return self != .write_only;
    }
};

pub const OpenMode = packed struct {
    access: AccessMode,

    _reserved: u7 = 0,

    create: bool = false, // 0x200
    trunc: bool = false, // 0x400

    pub fn fromUsize(input: usize) !OpenMode {
        const size = @bitSizeOf(OpenMode);
        if (input >> size != 0) {
            return error.InvalidOpenMode;
        }

        const raw: std.meta.Int(.unsigned, size) = @intCast(input);
        const mode: OpenMode = @bitCast(raw);
        if (mode.access == .invalid) return error.InvalidAccessMode;
        return mode;
    }
};

pub fn sys_open() u64 {
    const fd = open() catch |err| {
        log.print("could not open path: {s}", .{@errorName(err)});
        return sysargs.errorVal;
    };
    return fd;
}

const OpenErrors = error{ FailedGetPath, InvalidPath, OpenDirWithoutOnlyRead, InvalidDeviceMajor, FailedAllocFile };
pub fn open() !usize {
    var path: [Inode.max_path_size]u8 = undefined;
    const pathLen = sysargs.getString(.a0, &path) catch return OpenErrors.FailedGetPath;

    const openMode = try OpenMode.fromUsize(sysargs.getInt(.a1));

    fslog.beginOperation();
    defer fslog.endOperation();

    const inode = if (openMode.create) try create(path[0..pathLen], .file, .{ .major = 0, .minor = 0 }) else blk: {
        const existingInode = Inode.resolvePath(path[0..pathLen]) orelse return OpenErrors.InvalidPath;

        existingInode.lock();
        errdefer existingInode.releasePut();

        if (existingInode.disk_inode.type == .directory and openMode.access != .read_only) return OpenErrors.OpenDirWithoutOnlyRead;

        break :blk existingInode;
    };
    errdefer inode.put(); // only iput on error
    defer inode.release();

    if (inode.disk_inode.type == .device and (inode.disk_inode.device.major >= Device.max_device_count)) return OpenErrors.InvalidDeviceMajor;

    const file = File.alloc() orelse return OpenErrors.FailedAllocFile;
    errdefer file.close();

    if (inode.disk_inode.type == .device) {
        file.data = .{ .device = .{
            .device_id = inode.disk_inode.device,
            .inode = inode,
        } };
    } else {
        file.data = .{ .inode = .{
            .offset = 0,
            .inode = inode,
        } };
    }
    file.is_writeable = openMode.access.isWritable();
    file.is_readable = openMode.access.isReadable();

    if (openMode.trunc and inode.disk_inode.type == .file) {
        inode.truncate();
    }

    return sysargs.fileDescriptorAllocate(file);
}

pub fn sys_mkdir() u64 {
    var path: [Inode.max_path_size]u8 = undefined;
    const pathLen = sysargs.getString(.a0, &path) catch |err| {
        log.print("could not get path: {s}", .{@errorName(err)});
        return sysargs.errorVal;
    };

    fslog.beginOperation();
    defer fslog.endOperation();

    const inode = create(path[0..pathLen], .directory, .{ .major = 0, .minor = 0 }) catch |err| {
        log.print("could not create dir: {s}", .{@errorName(err)});
        return sysargs.errorVal;
    };
    inode.releasePut();

    return 0;
}

pub fn sys_mknod() u64 {
    var path: [Inode.max_path_size]u8 = undefined;
    const pathLen = sysargs.getString(.a0, &path) catch |err| {
        log.print("could not get path: {s}", .{@errorName(err)});
        return sysargs.errorVal;
    };

    const major = sysargs.getInt(.a1);
    const minor = sysargs.getInt(.a2);

    if (major >= Device.max_device_count) {
        log.print("major out of range", .{});
        return sysargs.errorVal;
    }

    const Minor = @FieldType(Device.ID, "minor");
    if (minor >= std.math.maxInt(Minor)) {
        log.print("minor out of range", .{});
        return sysargs.errorVal;
    }

    fslog.beginOperation();
    defer fslog.endOperation();

    const inode = create(path[0..pathLen], .device, .{ .major = @intCast(major), .minor = @intCast(minor) }) catch |err| {
        log.print("could not create node: {s}", .{@errorName(err)});
        return sysargs.errorVal;
    };
    inode.releasePut();

    return 0;
}

pub fn sys_chdir() u64 {
    chdir() catch |err| {
        log.print("could not get link: {s}", .{@errorName(err)});
        return sysargs.errorVal;
    };
    return 0;
}

const ChdirErrors = error{ FailedGetDestPath, InvalidDestPath, NotADirectory };

pub fn chdir() ChdirErrors!void {
    var path: [Inode.max_path_size]u8 = undefined;
    const path_size = sysargs.getString(.a0, &path) catch return ChdirErrors.FailedGetDestPath;

    const process = Process.getCurrentForce();

    fslog.beginOperation();
    defer fslog.endOperation();

    const inode = Inode.resolvePath(path[0..path_size]) orelse return ChdirErrors.InvalidDestPath;
    {
        inode.lock();
        errdefer inode.put();
        defer inode.release();

        if (inode.disk_inode.type != .directory) return ChdirErrors.NotADirectory;
    }

    process.currentWorkingDirectory.put();
    process.currentWorkingDirectory = inode;
}

pub fn sys_exec() u64 {
    return exec() catch |err| {
        log.print("could not exec: {s}", .{@errorName(err)});
        return sysargs.errorVal;
    };
}

const ExecErrors = error{ FailedGetProgPath, FailedGetArgv, TooManyArgs, FailedGetArgAddr, FailedGetMem, FailedGetArgData, ExecFail };

pub fn exec() !u64 {
    var path: [Inode.max_path_size]u8 = undefined;
    const pathLen = sysargs.getString(.a0, &path) catch return ExecErrors.FailedGetProgPath;

    const userArgArray = sysargs.getAddress(.a1) orelse return ExecErrors.FailedGetArgv;

    var buffers: [common.param.MAXARG]?address.PagePointer = undefined;
    @memset(&buffers, null);

    defer {
        for (buffers) |val| {
            if (val) |page| {
                kalloc.freePage(page) catch @panic("could not free memory");
            } else break;
        }
    }

    var argv: [common.param.MAXARG][]const u8 = undefined;
    var index: usize = 0;
    var userArg: address.UserAddress = .fromInt(0);
    while (true) : (index += 1) {
        if (index >= buffers.len) return ExecErrors.TooManyArgs;

        sysargs.fetchAddr(userArgArray.add(index * @sizeOf(usize)), &userArg) catch return ExecErrors.FailedGetArgAddr;

        if (userArg.toInt() == 0) {
            buffers[index] = null;
            break;
        }

        const page = kalloc.allocPage() orelse return ExecErrors.FailedGetMem;
        buffers[index] = page;

        const argLength = sysargs.getStringFromAddress(userArg, page[0..page_size]) catch return ExecErrors.FailedGetArgData;
        argv[index] = page[0..argLength];
    }

    return execFile.exec(path[0..pathLen], argv[0..index]);
}

pub fn sys_pipe() u64 {
    pipe() catch |err| {
        log.print("could not pipe: {s}", .{@errorName(err)});
        return sysargs.errorVal;
    };
    return 0;
}

const PipeErrors = error{ FailedGetFdArray, FailedToAllocPipe, FailedToOutputFirstFd, FailedToOutputSecondFd };

pub fn pipe() !void {
    const fileDescArray = sysargs.getAddress(.a0) orelse return PipeErrors.FailedGetFdArray;

    var readFile: *File = undefined;
    var writeFile: *File = undefined;
    Pipe.alloc(&readFile, &writeFile) catch return PipeErrors.FailedToAllocPipe;

    errdefer writeFile.close();
    errdefer readFile.close();

    const process = Process.getCurrentForce();

    var readFileDescriptor = try sysargs.fileDescriptorAllocate(readFile);
    errdefer process.openFiles[readFileDescriptor] = null;

    var writeFileDescriptor = try sysargs.fileDescriptorAllocate(writeFile);
    errdefer process.openFiles[writeFileDescriptor] = null;

    mem.copyOut(process.pageTable, fileDescArray, std.mem.asBytes(&readFileDescriptor)) catch return PipeErrors.FailedToOutputFirstFd;
    mem.copyOut(process.pageTable, fileDescArray.add(@sizeOf(c_int)), std.mem.asBytes(&writeFileDescriptor)) catch return PipeErrors.FailedToOutputSecondFd;
}
