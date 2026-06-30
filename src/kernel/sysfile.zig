//
// File-system system calls.
// Mostly argument checking, since we don't trust
// user code, and calls into file.c and fs.c.
//

const std = @import("std");

const sysargs = @import("sysargs.zig");
const log = @import("debuglog.zig");
const common = @import("common");
const param = common.param;
const kalloc = @import("kalloc.zig");
const address = @import("address.zig");
const page_size = common.riscv.page_size;
const mem = @import("memory.zig");
const execFile = @import("exec.zig");
const Inode = @import("inode.zig");
const File = @import("file.zig");
const Device = @import("device.zig");
const Process = @import("process.zig");
const fslog = @import("log.zig");
const Directory = @import("directory.zig");

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

    return file.getStatus(stat) catch sysargs.errorVal;
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
        const writtenBytes = directory_inode.write(.kernel, @intFromPtr(&directoryEntity), offset, Directory.entry_size);
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

fn create(path: []const u8, kind: Inode.Kind, device: Device.ID) CreateErrors!*Inode {
    var name: []const u8 = undefined;
    const parent_inode = Inode.resolvePathParent(path, &name) orelse return CreateErrors.FailedGetParentDir;

    parent_inode.lock();
    defer parent_inode.releasePut();

    const parent_directory = Directory.init(parent_inode);

    if (parent_directory.lookupChild(name, null)) |inode| {
        inode.lock();
        errdefer inode.releasePut();

        // already exists
        if (kind == .File and (inode.disk_inode.type == .file or inode.disk_inode.type == .device)) {
            return inode;
        }

        return CreateErrors.PathExistsWithWrongType;
    }

    const inode = c.ialloc(parent_inode.*.dev, kind.cShort()) orelse return CreateErrors.FailedAllocateInode;

    c.ilock(inode);
    errdefer {
        inode.*.nlink = 0;
        c.iupdate(inode);
        c.iunlockput(inode);
    }

    inode.*.major = device.major;
    inode.*.minor = @intCast(device.minor);
    inode.*.nlink = 1;
    c.iupdate(inode);

    if (kind == .Directory) {
        // create . and .. entries
        var dot = [_:0]u8{'.'};
        var dotdot = [_:0]u8{ '.', '.' };

        if (c.dirlink(inode, &dot, inode.*.inum) < 0) return CreateErrors.FailedCreateDot;
        if (c.dirlink(inode, &dotdot, parent_inode.*.inum) < 0) return CreateErrors.FailedCreateDotDot;
    }

    if (c.dirlink(parent_inode, &name, inode.*.inum) < 0) return CreateErrors.FailedLinkParentDir;
    if (kind == .Directory) {
        parent_inode.*.nlink += 1; // for ".."
        c.iupdate(parent_inode);
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
    var path: [c.MAXPATH]u8 = undefined;
    const pathLen = sysargs.getString(.a0, &path) catch return OpenErrors.FailedGetPath;

    const openMode = try OpenMode.fromUsize(sysargs.getInt(.a1));

    c.begin_op();
    defer c.end_op();

    const inode = if (openMode.create) try create(path[0..pathLen], .File, .{ .major = 0, .minor = 0 }) else blk: {
        const existingInode = c.namei(&path) orelse return OpenErrors.InvalidPath;

        c.ilock(existingInode);
        errdefer c.iunlockput(existingInode);

        if (existingInode.*.type == c.T_DIR and openMode.access != .read_only) return OpenErrors.OpenDirWithoutOnlyRead;

        break :blk existingInode;
    };
    errdefer c.iput(inode); // only iput on error
    defer c.iunlock(inode);

    if (inode.*.type == c.T_DEVICE and (inode.*.major < 0 or inode.*.major >= param.device_number)) return OpenErrors.InvalidDeviceMajor;

    const file = c.filealloc() orelse return OpenErrors.FailedAllocFile;
    errdefer c.fileclose(file);

    const fd = try sysargs.fileDescriptorAllocate(file);

    if (inode.*.type == c.T_DEVICE) {
        file.*.type = c.FD_DEVICE;
        file.*.major = inode.*.major;
    } else {
        file.*.type = c.FD_INODE;
        file.*.off = 0;
    }
    file.*.ip = inode;
    file.*.writable = @intFromBool(openMode.access.isWritable());
    file.*.readable = @intFromBool(openMode.access.isReadable());

    if (openMode.trunc and inode.*.type == c.T_FILE) {
        c.itrunc(inode);
    }

    return fd;
}

pub fn sys_mkdir() u64 {
    var path: [c.MAXPATH]u8 = undefined;
    const pathLen = sysargs.getString(.a0, &path) catch |err| {
        log.print("could not get path: {s}", .{@errorName(err)});
        return sysargs.errorVal;
    };

    c.begin_op();
    defer c.end_op();

    const inode = create(path[0..pathLen], .Directory, .{ .major = 0, .minor = 0 }) catch |err| {
        log.print("could not create dir: {s}", .{@errorName(err)});
        return sysargs.errorVal;
    };
    defer c.iunlockput(inode);

    return 0;
}

pub fn sys_mknod() u64 {
    var path: [c.MAXPATH]u8 = undefined;
    const pathLen = sysargs.getString(.a0, &path) catch |err| {
        log.print("could not get path: {s}", .{@errorName(err)});
        return sysargs.errorVal;
    };

    const major = sysargs.getInt(.a1);
    const minor = sysargs.getInt(.a2);

    if (major >= param.device_number) {
        log.print("major out of range", .{});
        return sysargs.errorVal;
    }

    const Minor = @FieldType(Device.ID, "minor");
    if (minor >= std.math.maxInt(Minor)) {
        log.print("minor out of range", .{});
        return sysargs.errorVal;
    }

    c.begin_op();
    defer c.end_op();

    const inode = create(path[0..pathLen], .Device, .{ .major = @intCast(major), .minor = @intCast(minor) }) catch |err| {
        log.print("could not create node: {s}", .{@errorName(err)});
        return sysargs.errorVal;
    };
    defer c.iunlockput(inode);

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
    var path: [c.MAXPATH]u8 = undefined;
    _ = sysargs.getString(.a0, &path) catch return ChdirErrors.FailedGetDestPath;

    const process = c.myproc();

    c.begin_op();
    defer c.end_op();

    const inode = c.namei(&path) orelse return ChdirErrors.InvalidDestPath;

    {
        c.ilock(inode);
        errdefer c.iput(inode);
        defer c.iunlock(inode);

        if (inode.*.type != c.T_DIR) return ChdirErrors.NotADirectory;
    }

    c.iput(process.*.cwd);
    process.*.cwd = inode;
}

pub fn sys_exec() u64 {
    return exec() catch |err| {
        log.print("could not exec: {s}", .{@errorName(err)});
        return sysargs.errorVal;
    };
}

const ExecErrors = error{ FailedGetProgPath, FailedGetArgv, TooManyArgs, FailedGetArgAddr, FailedGetMem, FailedGetArgData, ExecFail };

pub fn exec() !u64 {
    var path: [c.MAXPATH]u8 = undefined;
    const pathLen = sysargs.getString(.a0, &path) catch return ExecErrors.FailedGetProgPath;

    const userArgArray = sysargs.getAddress(.a1) orelse return ExecErrors.FailedGetArgv;

    var buffers: [c.MAXARG]?address.PagePointer = undefined;
    @memset(&buffers, null);

    defer {
        for (buffers) |val| {
            if (val) |page| {
                kalloc.freePage(page) catch @panic("could not free memory");
            } else break;
        }
    }

    var argv: [c.MAXARG][]const u8 = undefined;
    var index: usize = 0;
    var userArg: address.UserAddress = .fromInt(0);
    while (true) : (index += 1) {
        if (index >= buffers.len) return ExecErrors.TooManyArgs;

        sysargs.fetchAddr(userArgArray.add(index * @sizeOf(usize)), &userArg) catch return ExecErrors.FailedGetArgAddr;

        if (userArg.toInt() == 0) {
            buffers[index] = null;
            break;
        }

        buffers[index] = kalloc.allocPage() orelse return ExecErrors.FailedGetMem;

        const argLength = sysargs.getStringFromAddres(userArg, buffers[index].?[0..page_size]) catch return ExecErrors.FailedGetArgData;
        argv[index] = buffers[index].?[0..argLength];
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

    var readFile: [*c]c.struct_file = undefined;
    var writeFile: [*c]c.struct_file = undefined;
    if (c.pipealloc(&readFile, &writeFile) < 0) return PipeErrors.FailedToAllocPipe;

    errdefer c.fileclose(writeFile);
    errdefer c.fileclose(readFile);

    const process = c.myproc();
    const files: *[c.NOFILE][*c]c.struct_file = &c.myproc().*.ofile;

    var readFileDescriptor = try sysargs.fileDescriptorAllocate(readFile);
    errdefer files.*[readFileDescriptor] = null;

    var writeFileDescriptor = try sysargs.fileDescriptorAllocate(writeFile);
    errdefer files.*[writeFileDescriptor] = null;

    const pageTable: address.PageTablePtr = @ptrCast(@alignCast(process.*.pagetable));

    mem.copyOut(pageTable, fileDescArray, std.mem.asBytes(&readFileDescriptor)) catch return PipeErrors.FailedToOutputFirstFd;
    mem.copyOut(pageTable, fileDescArray.add(@sizeOf(c_int)), std.mem.asBytes(&writeFileDescriptor)) catch return PipeErrors.FailedToOutputSecondFd;
}
