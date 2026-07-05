// Much of this code comes from https://github.com/binarycraft007/xv6-riscv-zig

const std = @import("std");
const builtin = @import("builtin");

const fs = @import("../src/kernel/filesystem/mod.zig");
const Inode = fs.Inode;
const Directory = fs.Directory;
const os = std.os;
const mem = std.mem;
const math = std.math;
const assert = std.debug.assert;
const MakeFilesystemStep = @This();

const Build = std.Build;
const InstallDir = Build.InstallDir;
const CompileStep = Build.Step.Compile;
const Step = Build.Step;

const stat = @import("../src/common/stat.zig");
const param = @import("../src/common/param.zig");

const NINODES = 200;

// Disk layout:
// [ boot block | sb block | log | inode blocks | free bit map | data blocks ]

const nbitmap: i32 = param.FSSIZE / (fs.block_size * 8) + 1;
const ninodeblocks: i32 = NINODES / Inode.inodes_per_block + 1;
const nlog: i32 = param.log_size;

const zeroes = [_]u8{0} ** fs.block_size;
var sb: fs.SuperBlock = undefined;
var freeinode: u32 = 1;
var freeblock: u32 = undefined;
var file: std.Io.File = undefined;

step: Step,
artifacts: std.ArrayList(*CompileStep),
dest_dir: InstallDir,
dest_filename: []const u8,
output_file: std.Build.GeneratedFile,

pub fn create(
    owner: *Build,
    artifacts: std.ArrayList(*CompileStep),
    dest_filename: []const u8,
) *MakeFilesystemStep {
    const self = owner.allocator.create(MakeFilesystemStep) catch @panic("OOM");
    self.* = MakeFilesystemStep{
        .step = Step.init(.{
            .id = .custom,
            .owner = owner,
            .name = owner.fmt("make filesystem image {s}", .{dest_filename}),
            .makeFn = make,
        }),
        .artifacts = artifacts,
        .dest_dir = .bin,
        .dest_filename = dest_filename,
        .output_file = std.Build.GeneratedFile{ .step = &self.step },
    };

    for (artifacts.items) |artifact| {
        self.step.dependOn(&artifact.step);
    }

    return self;
}

pub fn getOutputSource(self: *const MakeFilesystemStep) std.Build.LazyPath {
    return .{ .generated = .{ .file = &self.output_file } };
}

fn make(step: *Step, options: Step.MakeOptions) !void {
    _ = options;
    const self: *MakeFilesystemStep = @fieldParentPtr("step", step);
    const b = self.step.owner;
    const io = b.graph.io;

    var full_src_paths: std.ArrayList([]const u8) = .empty;
    try full_src_paths.append(b.allocator, "README.md");
    for (self.artifacts.items) |artifact| {
        try full_src_paths.append(b.allocator, artifact.getEmittedBin().getPath(b));
    }

    const full_dest_path = b.getInstallPath(self.dest_dir, self.dest_filename);
    self.output_file.path = full_dest_path;

    const cwd = std.Io.Dir.cwd();
    const install_path = b.getInstallPath(self.dest_dir, "");

    try cwd.createDirPath(io, install_path);

    var dir = try cwd.openDir(io, install_path, .{});
    defer dir.close(io);

    var de: Directory.DirectoryEntry = undefined;
    var buf: [fs.block_size]u8 = undefined;
    var din: Inode.DiskInode = undefined;

    assert(fs.block_size % @sizeOf(Inode.DiskInode) == 0);
    assert(fs.block_size % @sizeOf(Directory.DirectoryEntry) == 0);

    var flags = std.Io.Dir.CreateFileOptions{
        .read = true,
        .truncate = true,
    };
    if (builtin.os.tag != .windows) {
        flags.permissions = .fromMode(std.c.S.IRUSR | std.c.S.IWUSR |
            std.c.S.IRGRP | std.c.S.IWGRP |
            std.c.S.IROTH | std.c.S.IWOTH);
    }
    file = try dir.createFile(io, self.dest_filename, flags);
    defer file.close(io);

    const nmeta = 2 + nlog + ninodeblocks + nbitmap;
    const nblocks = param.FSSIZE - nmeta;

    sb = fs.SuperBlock{
        .magic = fs.SuperBlock.correct_magic,
        .size = param.FSSIZE,
        .nblocks = nblocks,
        .ninodes = NINODES,
        .nlog = nlog,
        .logstart = 2,
        .inodestart = 2 + nlog,
        .bmapstart = 2 + nlog + ninodeblocks,
    };

    freeblock = nmeta; // the first free block that we can allocate
    var i: usize = 0;
    while (i < param.FSSIZE) : (i += 1) {
        try wsect(io, i, &zeroes);
    }

    @memset(&buf, 0);
    const mem_bytes = mem.asBytes(&sb);
    @memcpy(buf[0..mem_bytes.len], mem_bytes);
    try wsect(io, 1, &buf);

    const rootino = @as(u16, @intCast(try ialloc(io, .dir)));
    std.debug.assert(rootino == Inode.root_inode_number);

    @memset(mem.asBytes(&de), 0);
    de.inode_number = mem.readVarInt(u16, mem.asBytes(&rootino), .little);
    @memcpy(de.name_buffer[0..1], ".");
    de.name_length = 1;
    try iappend(io, @as(u32, rootino), mem.asBytes(&de));

    @memset(mem.asBytes(&de), 0);
    de.inode_number = mem.readVarInt(u16, mem.asBytes(&rootino), .little);
    @memcpy(de.name_buffer[0..2], "..");
    de.name_length = 2;
    try iappend(io, @as(u32, rootino), mem.asBytes(&de));

    for (full_src_paths.items) |full_src_path| {
        const path = full_src_path;
        var shortname = std.fs.path.basename(path);

        const bin = try cwd.openFile(io, path, .{});
        defer bin.close(io);

        if (shortname[0] == '_') {
            shortname = shortname[1..];
        }

        var inode_number = @as(u16, @intCast(try ialloc(io, .file)));
        @memset(mem.asBytes(&de), 0);
        de.inode_number = mem.readVarInt(u16, mem.asBytes(&inode_number), .little);
        @memcpy(de.name_buffer[0..shortname.len], shortname);
        de.name_length = @intCast(shortname.len);
        try iappend(io, @as(u32, rootino), mem.asBytes(&de));

        const bufs = [_][]u8 {&buf};
        while (true) {
            const amt = bin.readStreaming(io, &bufs) catch |err| switch (err) {
                error.EndOfStream => break,
                else => return err,
            };
            if (amt == 0) break;
            try iappend(io, @as(u32, inode_number), buf[0..amt]);
        }
    }

    // fix size of root inode dir
    try rinode(io, @as(u32, rootino), &din);
    var off = mem.readVarInt(u32, mem.asBytes(&din.size), .little);
    off = ((off / fs.block_size) + 1) * fs.block_size;
    din.size = mem.readVarInt(u32, mem.asBytes(&off), .little);
    try winode(io, @as(u32, rootino), &din);

    try balloc(io, @as(usize, freeblock));
}

fn wsect(io: std.Io, sec: usize, buf: []const u8) !void {
    std.debug.assert(buf.len == fs.block_size);

    const off = sec * fs.block_size;
    try file.writePositionalAll(io, buf, off);
}

fn rsect(io: std.Io, sec: usize, buf: []u8) !void {
    std.debug.assert(buf.len == fs.block_size);

    const off = sec * fs.block_size;
    const bytes = try file.readPositionalAll(io, buf, off);
    std.debug.assert(bytes == buf.len);
}

fn winode(io: std.Io, inode_number: u32, ip: *Inode.DiskInode) !void {
    var buf: [fs.block_size]u8 = undefined;
    const block_number = sb.getInodeBlockNumber(inode_number);
    try rsect(io, block_number, &buf);
    const dip = buf[(inode_number % Inode.inodes_per_block) * @sizeOf(Inode.DiskInode) ..];
    const mem_bytes = mem.asBytes(ip);
    @memcpy(dip[0..mem_bytes.len], mem_bytes);
    try wsect(io, block_number, &buf);
}

fn rinode(io: std.Io, inode_number: u32, ip: *Inode.DiskInode) !void {
    var buf: [fs.block_size]u8 = undefined;
    const block_number = sb.getInodeBlockNumber(inode_number);
    try rsect(io, block_number, &buf);
    var dip = buf[(inode_number % Inode.inodes_per_block) * @sizeOf(Inode.DiskInode) ..];
    @memcpy(mem.asBytes(ip), dip[0..@sizeOf(Inode.DiskInode)]);
}

fn ialloc(io: std.Io, file_type: stat.FileType) !u32 {
    const inode_number = freeinode;
    defer freeinode += 1;

    var din: Inode.DiskInode = undefined;
    @memset(mem.asBytes(&din), 0);
    var din_bytes = mem.toBytes(@intFromEnum(file_type));
    din.type = @enumFromInt(mem.readVarInt(u16, &din_bytes, .little));
    din.link_count = mem.readVarInt(u16, &[_]u8{1}, .little);
    din.size = mem.readVarInt(u32, &[_]u8{0}, .little);

    try winode(io, inode_number, &din);
    return inode_number;
}

fn balloc(io: std.Io, used: usize) !void {
    var buf: [fs.block_size]u8 = undefined;
    @memset(&buf, 0);

    std.debug.assert(used < fs.block_size * 8);

    for (0..used) |i| {
        buf[i / 8] |= @as(u8, 0x1) << @as(u3, @intCast((i % 8)));
    }

    try wsect(io, sb.bmapstart, &buf);
}

fn iappend(io: std.Io, inode_number: u32, data: []const u8) !void {
    var din: Inode.DiskInode = undefined;
    var buf: [fs.block_size]u8 = undefined;
    var n: usize = data.len;
    var n1: usize = undefined;
    var idx: usize = 0;
    var indirect: [Inode.indirect_pointer_count]u32 = undefined;

    try rinode(io, inode_number, &din);
    var off = mem.readVarInt(u32, mem.asBytes(&din.size), .little);

    while (n > 0) : ({
        n -= n1;
        off += @as(u32, @intCast(n1));
        idx += n1;
    }) {
        const fbn = off / fs.block_size;
        std.debug.assert(fbn < Inode.max_file_block_count);
        const x = if (fbn < Inode.direct_pointer_count) blk: {
            if (mem.readVarInt(u32, mem.asBytes(&din.addrs[fbn]), .little) == 0) {
                const fblk = mem.readVarInt(u32, mem.asBytes(&freeblock), .little);
                defer freeblock += 1;
                din.addrs[fbn] = fblk;
            }
            break :blk mem.readVarInt(usize, mem.asBytes(&din.addrs[fbn]), .little);
        } else blk: {
            if (mem.readVarInt(u32, mem.asBytes(&din.addrs[Inode.direct_pointer_count]), .little) == 0) {
                const fblk = mem.readVarInt(u32, mem.asBytes(&freeblock), .little);
                defer freeblock += 1;
                din.addrs[Inode.direct_pointer_count] = fblk;
            }
            const num = mem.readVarInt(usize, mem.asBytes(&din.addrs[Inode.direct_pointer_count]), .little);
            try rsect(io, num, mem.sliceAsBytes(&indirect));
            if (indirect[fbn - Inode.direct_pointer_count] == 0) {
                const fblk = mem.readVarInt(u32, mem.asBytes(&freeblock), .little);
                defer freeblock += 1;
                indirect[fbn - Inode.direct_pointer_count] = fblk;
                try wsect(io, num, mem.sliceAsBytes(&indirect));
            }
            break :blk mem.readVarInt(usize, mem.asBytes(&indirect[fbn - Inode.direct_pointer_count]), .little);
        };
        n1 = @min(n, (fbn + 1) * fs.block_size - off);
        try rsect(io, x, &buf);
        @memcpy(buf[off - (fbn * fs.block_size) ..][0..n1], data[idx..][0..n1]);
        try wsect(io, x, &buf);
    }
    din.size = mem.readVarInt(u32, mem.asBytes(&off), .little);
    try winode(io, inode_number, &din);
}
