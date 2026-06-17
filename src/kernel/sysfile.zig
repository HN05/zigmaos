//
// File-system system calls.
// Mostly argument checking, since we don't trust
// user code, and calls into file.c and fs.c.
//

const std = @import("std");

const sysargs = @import("sysargs.zig");
const c = sysargs.c;
const log = @import("klog.zig");
const common = @import("common");
const params = common.param;
const kalloc = @import("kalloc.zig");
const pagesize = common.riscv.pagesize;

pub fn sys_dup() u64 {
    const file = sysargs.getFile(.a0) catch |err| {
        log.print("could not get file: {s}", .{@errorName(err)});
        return sysargs.errorVal;
    };

    const fd = sysargs.fileDescriptorAllocate(file) catch |err| {
        log.print("could not allocate new file descriptor: {s}", .{@errorName(err)});
        return sysargs.errorVal;
    };

    _ = c.filedup(file);
    return fd;
}

pub fn sys_read() u64 {
    const destination = sysargs.getAddress(.a1);
    const number = sysargs.getInt(.a2);

    const file = sysargs.getFile(.a0) catch |err| {
        log.print("could not get file: {s}", .{@errorName(err)});
        return sysargs.errorVal;
    };

    const result = c.fileread(file, @intFromPtr(destination), @intCast(number));
    if (result < 0) {
        return sysargs.errorVal;
    } else {
        return @intCast(result);
    }
}

pub fn sys_write() u64 {
    const source = sysargs.getAddress(.a1);
    const number = sysargs.getInt(.a2);

    const file = sysargs.getFile(.a0) catch |err| {
        log.print("could not get file: {s}", .{@errorName(err)});
        return sysargs.errorVal;
    };

    const result = c.filewrite(file, @intFromPtr(source), @intCast(number));
    if (result < 0) {
        return sysargs.errorVal;
    } else {
        return @intCast(result);
    }
}

pub fn sys_close() u64 {
    var file: *c.struct_file = undefined;
    const fd = sysargs.getFileAndDescriptor(.a0, &file) catch |err| {
        log.print("could not get file: {s}", .{@errorName(err)});
        return sysargs.errorVal;
    };

    var files = c.myproc().*.ofile;
    files[fd] = null;
    c.fileclose(file);
    return 0;
}

pub fn sys_fstat() u64 {
    const stat = sysargs.getAddress(.a1);

    const file = sysargs.getFile(.a0) catch |err| {
        log.print("could not get file: {s}", .{@errorName(err)});
        return sysargs.errorVal;
    };

    const result = c.filestat(file, @intFromPtr(stat));
    if (result < 0) {
        return sysargs.errorVal;
    } else {
        return @intCast(result);
    }
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
    var old: [c.MAXPATH]u8 = undefined;
    _ = sysargs.getString(.a0, &old) catch return LinkErrors.FailedGetOldPath;

    var new: [c.MAXPATH]u8 = undefined;
    _ = sysargs.getString(.a1, &new) catch return LinkErrors.FailedGetNewPath;

    c.begin_op();
    defer c.end_op();

    const inode = c.namei(&old) orelse return LinkErrors.FailedGetInode;
    defer c.iput(inode);

    // increment references to inode
    {
        c.ilock(inode);
        defer c.iunlock(inode);

        if (inode.*.type == c.T_DIR) return LinkErrors.IsDirectory;

        inode.*.nlink += 1;
        c.iupdate(inode);
    }

    // Roll back increment if it fails
    errdefer {
        c.ilock(inode);
        inode.*.nlink -= 1;
        c.iupdate(inode);
        c.iunlock(inode);
    }

    // update directory
    {
        var name: [c.DIRSIZ]u8 = undefined;
        const directory = c.nameiparent(&new, &name) orelse return LinkErrors.FailedGetParentDir;

        c.ilock(directory);
        defer c.iunlockput(directory);

        if (directory.*.dev != inode.*.dev) return LinkErrors.NotSameDevice;

        const result = c.dirlink(directory, &name, inode.*.inum);
        if (result < 0) return LinkErrors.FailedUpdateNewParDir;
    }
}

fn isDirectoryEmpty(directory: *c.struct_inode) bool {
    const directoryOffset = @sizeOf(c.struct_dirent);
    var index: usize = 2; // skip past . and ..
    var directoryEntitiy: c.struct_dirent = undefined;

    while (index * directoryOffset < directory.*.size) : (index += 1) {
        const readBytes = c.readi(directory, 0, @intFromPtr(&directoryEntitiy), @intCast(index * directoryOffset), directoryOffset);
        if (readBytes != directoryOffset) {
            @panic("isDirectoryEmpty: readi");
        }

        if (directoryEntitiy.inum != 0) {
            return false;
        }
    }

    return true;
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
    var path: [c.MAXPATH]u8 = undefined;
    _ = sysargs.getString(.a0, &path) catch return UnlinkErrors.FailedGetPath;

    c.begin_op();
    defer c.end_op();

    var name: [c.DIRSIZ]u8 = undefined;
    const directory = c.nameiparent(&path, &name) orelse return UnlinkErrors.FailedGetParentDir;

    c.ilock(directory);
    defer c.iunlockput(directory);

    if (c.namecmp(&name, ".") == 0) return UnlinkErrors.IsDot;
    if (c.namecmp(&name, "..") == 0) return UnlinkErrors.IsDotDot;

    var offset: c.uint = undefined;
    const inode = c.dirlookup(directory, &name, &offset) orelse return UnlinkErrors.FailedDirLookup;

    c.ilock(inode);
    defer c.iunlockput(inode);

    if (inode.*.nlink < 1) {
        @panic("unlink: nlink < 1");
    }
    if (inode.*.type == c.T_DIR and !isDirectoryEmpty(inode)) return UnlinkErrors.DirectoryNotEmpty;

    // remove directory entry
    {
        var directoryEntity = std.mem.zeroes(c.struct_dirent);
        const writtenBytes = c.writei(directory, 0, @intFromPtr(&directoryEntity), offset, @sizeOf(c.struct_dirent));
        if (writtenBytes != @sizeOf(c.struct_dirent)) {
            @panic("unlink: writei");
        }
    }

    if (inode.*.type == c.T_DIR) {
        directory.*.nlink -= 1;
        c.iupdate(directory);
    }

    inode.*.nlink -= 1;
    c.iupdate(inode);
}

pub const InodeKind = enum { Directory, Device, File };

fn MakeDeviceID(comptime ndev: comptime_int) type {
    const total_bits = @bitSizeOf(usize);
    const major_bits = std.math.log2_int_ceil(usize, ndev);
    const minor_bits = total_bits - major_bits;

    return packed struct(usize) {
        minor: std.meta.Int(.unsigned, minor_bits),
        major: std.meta.Int(.unsigned, major_bits),
    };
}

pub const DeviceID = MakeDeviceID(params.NDEV);

const CreateErrors = error{ FailedGetParentDir, PathExistsWithWrongType, FailedAllocateInode, FailedCreateDot, FailedCreateDotDot, FailedLinkParentDir };

fn create(path: []u8, kind: InodeKind, device: DeviceID) CreateErrors!*c.struct_inode {
    var name: [c.DIRSIZ]u8 = undefined;
    const directory = c.nameiparent(path.ptr, &name) orelse return CreateErrors.FailedGetParentDir;

    c.ilock(directory);
    defer c.iunlockput(directory);

    if (c.dirlookup(directory, &name, 0)) |inode| {
        c.ilock(inode);
        errdefer c.iunlockput(inode);

        // already exists
        if (kind == .File and (inode.*.type == c.T_FILE or inode.*.type == c.T_DEVICE)) {
            return inode;
        }

        return CreateErrors.PathExistsWithWrongType;
    }

    const inode = c.ialloc(device.major, @intCast(device.minor)) orelse return CreateErrors.FailedAllocateInode;

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
        if (c.dirlink(inode, &dotdot, directory.*.inum) < 0) return CreateErrors.FailedCreateDotDot;
    }

    if (c.dirlink(directory, &name, inode.*.inum) < 0) return CreateErrors.FailedLinkParentDir;
    if (kind == .Directory) {
        directory.*.nlink += 1; // for ".."
        c.iupdate(directory);
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

    if (inode.*.type == c.T_DEVICE and (inode.*.major < 0 or inode.*.major >= params.NDEV)) return OpenErrors.InvalidDeviceMajor;

    const file = c.filealloc() orelse return OpenErrors.FailedAllocFile;
    defer c.fileclose(file);

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

    if (major >= params.NDEV) {
        log.print("major out of range", .{});
        return sysargs.errorVal;
    }

    const Minor = @FieldType(DeviceID, "minor");
    if (minor >= std.math.maxInt(Minor)){
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
    exec() catch |err| {
        log.print("could not exec: {s}", .{@errorName(err)});
        return sysargs.errorVal;
    };
    return 0;
}

const ExecErrors = error{ FailedGetProgPath, FailedGetArgv, TooManyArgs, FailedGetArgAddr, FailedGetMem, FailedGetArgData, ExecFail };

pub fn exec() ExecErrors!void {
    var path: [c.MAXPATH]u8 = undefined;
    _ = sysargs.getString(.a0, &path) catch return ExecErrors.FailedGetProgPath;

    const userArgArray: [*]*anyopaque = @alignCast(@ptrCast(sysargs.getAddress(.a1) orelse return ExecErrors.FailedGetArgv));

    var argv: [c.MAXARG]?[*:0]u8 = undefined;
    @memset(&argv, null);

    defer {
        for (argv, 0..) |val, i| {
            if (val != null) {
                kalloc.kfree(@ptrCast(argv[i]));
            }
        }
    }


    var index: usize = 0;
    var userArgBuf: ?*anyopaque = null;
    while (true) : (index += 1) {
        if (index >= argv.len) return ExecErrors.TooManyArgs;

        sysargs.fetchAddr(userArgArray[index], &userArgBuf) catch return ExecErrors.FailedGetArgAddr;

        const userArg = userArgBuf orelse {
            argv[index] = null;
            break;
        };

        argv[index] = @ptrCast(kalloc.kalloc() orelse return ExecErrors.FailedGetMem);

        _ = sysargs.getStringFromAddres(userArg, argv[index].?[0..pagesize]) catch return ExecErrors.FailedGetArgData;
    }

    const result = c.exec(&path, @ptrCast(&argv));
    if (result < 0) return ExecErrors.ExecFail;
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
    const fileDescArray: [*]c.struct_file = @alignCast(@ptrCast(sysargs.getAddress(.a0) orelse return PipeErrors.FailedGetFdArray));

    var readFile: [*c]c.struct_file = undefined;
    var writeFile: [*c]c.struct_file = undefined;
    if(c.pipealloc(&readFile, &writeFile) < 0) return PipeErrors.FailedToAllocPipe;

    errdefer c.fileclose(writeFile);
    errdefer c.fileclose(readFile);

    const process = c.myproc();
    var files = process.*.ofile;

    var readFileDescriptor = try sysargs.fileDescriptorAllocate(readFile);
    errdefer files[readFileDescriptor] = 0;

    var writeFileDescriptor = try sysargs.fileDescriptorAllocate(writeFile);
    errdefer files[writeFileDescriptor] = 0;

    const result1 = c.copyout(process.*.pagetable, @intFromPtr(fileDescArray), @ptrCast(&readFileDescriptor), @sizeOf(*c.struct_file));
    if (result1 < 0) return PipeErrors.FailedToOutputFirstFd;

    const result2 = c.copyout(process.*.pagetable, @intFromPtr(fileDescArray + 1), @ptrCast(&writeFileDescriptor), @sizeOf(*c.struct_file));
    if (result2 < 0) return PipeErrors.FailedToOutputSecondFd;
}

