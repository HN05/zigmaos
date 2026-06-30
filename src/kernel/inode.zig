const SleepLock = @import("sleeplock.zig");
const Device = @import("device.zig");
const fs = @import("filesystem.zig");
const SpinLock = @import("spinlock.zig");
const common = @import("common");
const Buffer = @import("buffer.zig");
const std = @import("std");
const log = @import("log.zig");
const ad = @import("address.zig");
const mem = @import("memory.zig");
const Process = @import("process.zig");
const Directory = @import("directory.zig");

// Inodes.
//
// An inode describes a single unnamed file.
// The inode disk structure holds metadata: the file's type,
// its size, the number of links referring to it, and the
// list of blocks holding the file's content.
//
// The inodes are laid out sequentially on disk at block
// sb.inodestart. Each inode has a number, indicating its
// position on the disk.
//
// The kernel keeps a table of in-use inodes in memory
// to provide a place for synchronizing access
// to inodes used by multiple processes. The in-memory
// inodes include book-keeping information that is
// not stored on disk: ip->ref and ip->valid.
//
// An inode and its in-memory representation go through a
// sequence of states before they can be used by the
// rest of the file system code.
//
// * Allocation: an inode is allocated if its type (on disk)
//   is non-zero. ialloc() allocates, and iput() frees if
//   the reference and link counts have fallen to zero.
//
// * Referencing in table: an entry in the inode table
//   is free if ip->ref is zero. Otherwise ip->ref tracks
//   the number of in-memory pointers to the entry (open
//   files and current directories). iget() finds or
//   creates a table entry and increments its ref; iput()
//   decrements ref.
//
// * Valid: the information (type, size, &c) in an inode
//   table entry is only correct when ip->valid is 1.
//   ilock() reads the inode from
//   the disk and sets ip->valid, while iput() clears
//   ip->valid if ip->ref has fallen to zero.
//
// * Locked: file system code may only examine and modify
//   the information in an inode and its content if it
//   has first locked the inode.
//
// Thus a typical sequence is:
//   ip = iget(dev, inum)
//   ilock(ip)
//   ... examine and modify ip->xxx ...
//   iunlock(ip)
//   iput(ip)
//
// ilock() is separate from iget() so that system calls can
// get a long-term reference to an inode (as for an open file)
// and only lock it for short periods (e.g., in read()).
// The separation also helps avoid deadlock and races during
// pathname lookup. iget() increments ip->ref so that the inode
// stays in the table and pointers to it remain valid.
//
// Many internal file system functions expect the caller to
// have locked the inodes involved; this lets callers create
// multi-step atomic operations.
//
// The itable.lock spin-lock protects the allocation of itable
// entries. Since ip->ref indicates whether an entry is free,
// and ip->dev and ip->inum indicate which i-node an entry
// holds, one must hold itable.lock while using any of those fields.
//
// An ip->lock sleep-lock protects all ip-> fields other than ref,
// dev, and inum.  One must hold ip->lock in order to
// read or write that inode's ip->valid, ip->size, ip->type, &c.

const Inode = @This();

pub const root_inode_number = 1; // root i-number
pub const max_path_size = common.param.MAXPATH;

pub const direct_pointer_count = 12;
pub const indirect_pointer_block_index = direct_pointer_count;
pub const indirect_pointer_count = fs.block_size / @sizeOf(u32);
pub const inode_address_count = direct_pointer_count + 1;
pub const inodes_per_block = fs.block_size / @sizeOf(DiskInode);
pub const max_file_block_count = direct_pointer_count + indirect_pointer_count;

// Block containing inode i
fn getInodeBlock(inode_number: u32) u32 {
    return inode_number / inodes_per_block + fs.superBlock.inodestart;
}

// in-memory inode identity
filesystem_device: Device.ID = .zero,
inode_number: u32 = 0,
reference_count: u32 = 0,

sleep_lock: SleepLock = .{ .name = "inode" },
is_valid: bool = false,

disk_inode: DiskInode = .{},

// On-disk inode structure
pub const DiskInode = extern struct {
    type: fs.FileType = .free, // File type
    device: Device.ID = .zero,
    link_count: u16 = 0, // Number of links to inode in file system
    size: u32 = 0, // Size of file (bytes)
    addrs: [inode_address_count]u32 = [_]u32{0} ** inode_address_count, // Data block addresses
};

const DiskInodeBlock = [inodes_per_block]DiskInode;

pub fn reset(self: *Inode) void {
    self.* = .{};
    self.disk_inode.reset();
}

pub const InodeTable = struct {
    lock: SpinLock = .{ .name = "inode_table" },
    inodes: [common.param.NINODE]Inode = [_]Inode{.{}} ** common.param.NINODE,
};

var inode_table: InodeTable = .{};

fn getDiskInode(buffer: *Buffer, inode_number: u32) *DiskInode {
    const disk_inodes = buffer.castData(DiskInodeBlock);
    const inode_index = inode_number % inodes_per_block;
    return &disk_inodes.*[inode_index];
}

// Allocate an inode on device dev.
// Mark it as allocated by  giving it type type.
// Returns an unlocked but allocated and referenced inode,
// or NULL if there is no free inode.
pub fn alloc(device: Device.ID, file_type: fs.FileType) !*Inode {
    for (0..fs.superBlock.ninodes) |inode_number| {
        const buffer = Buffer.read(device, getInodeBlock(inode_number));
        defer buffer.release();

        const disk_inode = getDiskInode(buffer, inode_number);

        if (disk_inode.type == .free) { // free inode
            disk_inode = .{}; // reset it
            disk_inode.type = file_type;
            log.write(buffer); // mark it allocated on the disk
            return get(device, inode_number);
        }
    }
    return error.OutOfInodes;
}

// Copy a modified in-memory inode to disk.
// Must be called after every change to an ip->xxx field
// that lives on disk.
// Caller must hold ip->lock.
pub fn update(inode: *Inode) void {
    const buffer = Buffer.read(inode.filesystem_device, getInodeBlock(inode.inode_number));
    defer buffer.release();

    const disk_inode = getDiskInode(buffer, inode.inode_number);
    disk_inode.* = inode.disk_inode;
    log.write(buffer);
}

// Find the inode with number inum on device dev
// and return the in-memory copy. Does not lock
// the inode and does not read it from disk.
fn get(device: Device.ID, inode_number: u32) *Inode {
    inode_table.lock.acquire();
    defer inode_table.lock.release();

    // Is the inode already in the table?
    var empty_inode: ?*Inode = null;
    for (inode_table.inodes) |inode| {
        if (inode.reference_count > 0 and inode.filesystem_device == device and inode.inode_number == inode_number) {
            inode.reference_count += 1;
            return inode;
        }
        if (empty_inode == null and inode.reference_count == 0) {
            empty_inode = inode; // remember empty slot
        }
    }

    if (empty_inode == null) @panic("no inodes available");

    // Recycle an inode entry.
    const found_inode = empty_inode.?;
    found_inode.filesystem_device = device;
    found_inode.inode_number = inode_number;
    found_inode.reference_count = 1;
    found_inode.is_valid = false;
    return found_inode;
}

// Increment reference count for ip.
// Returns ip to enable ip = idup(ip1) idiom.
pub fn duplicate(inode: *Inode) *Inode {
    inode_table.lock.acquire();
    defer inode_table.lock.release();

    inode.reference_count += 1;
    return inode;
}

// Lock the given inode.
// Reads the inode from disk if necessary.
pub fn lock(inode: *Inode) void {
    if (inode.reference_count < 1) @panic("can't lock unused inode");

    inode.sleep_lock.acquire();

    if (!inode.is_valid) {
        const buffer = Buffer.read(inode.filesystem_device, getInodeBlock(inode.inode_number));
        defer buffer.release();

        const disk_inode = getDiskInode(buffer, inode.inode_number);
        inode.disk_inode = disk_inode.*;
        inode.is_valid = true;
        if (inode.disk_inode.type == .free) @panic("ilock: no type");
    }
}

// Unlock the given inode.
pub fn release(inode: *Inode) void {
    if (!inode.sleep_lock.isHolding()) @panic("not holding inode lock");
    if (inode.reference_count < 1) @panic("can't unlock unused inode");

    inode.sleep_lock.release();
}

// Drop a reference to an in-memory inode.
// If that was the last reference, the inode table entry can
// be recycled.
// If that was the last reference and the inode has no links
// to it, free the inode (and its content) on disk.
// All calls to iput() must be inside a transaction in
// case it has to free the inode.
pub fn put(inode: *Inode) void {
    inode_table.lock.acquire();
    defer inode_table.lock.release();

    if (inode.reference_count == 1 and inode.is_valid and inode.disk_inode.link_count == 0) {
        // inode has no links and no other references: truncate and free.
        inode_table.lock.release();
        defer inode_table.lock.acquire();

        // ip->ref == 1 means no other process can have ip locked,
        // so this acquiresleep() won't block (or deadlock).
        inode.sleep_lock.acquire();
        defer inode.sleep_lock.release();

        inode.truncate();
        inode.disk_inode.type = .free;
        inode.update();
        inode.is_valid = false;
    }

    inode.reference_count -= 1;
}

// Common idiom: unlock, then put.
pub fn releasePut(inode: *Inode) void {
    inode.release();
    inode.put();
}

// Inode content
//
// The content (data) associated with each inode is stored
// in blocks on the disk. The first NDIRECT block numbers
// are listed in ip->addrs[].  The next NINDIRECT blocks are
// listed in block ip->addrs[NDIRECT].

// Return the disk block address of the nth block in inode ip.
// If there is no such block, bmap allocates one.
pub fn getBlockAddress(inode: *Inode, block_number: u32) !u32 {
    // try to find direct
    if (block_number < direct_pointer_count) {
        var address = inode.disk_inode.addrs[block_number];
        if (address == 0) {
            // allocate block
            address = try fs.blockAllocate(inode.filesystem_device);
            inode.disk_inode.addrs[block_number] = address;
        }
        return address;
    }

    const block_number_indirect = block_number - indirect_pointer_block_index;
    if (block_number_indirect >= indirect_pointer_count) @panic("block number out of range");

    // Load indirect block, allocating if necessary.
    var pointer_block = inode.disk_inode.addrs[indirect_pointer_block_index];
    if (pointer_block == 0) {
        // allocate block
        pointer_block = try fs.blockAllocate(inode.filesystem_device);
        inode.disk_inode.addrs[block_number] = pointer_block;
    }
    const buffer = Buffer.read(inode.filesystem_device, pointer_block);
    defer buffer.release();

    const addresses = buffer.castData([indirect_pointer_count]u32);
    var address = addresses[block_number];
    if (address == 0) {
        // alloc block
        address = try fs.blockAllocate(inode.filesystem_device);
        addresses[address] = address;
        log.write(buffer);
    }
    return address;
}

// Truncate inode (discard contents).
// Caller must hold ip->lock.
pub fn truncate(inode: *Inode) void {
    defer inode.update(); // update the inode last after changes

    for (0..direct_pointer_count) |direct_pointer| {
        if (inode.disk_inode.addrs[direct_pointer] != 0) {
            fs.blockFree(inode.filesystem_device, inode.disk_inode.addrs[direct_pointer]);
            inode.disk_inode.addrs[direct_pointer] = 0;
        }
    }
    const indirect_address = inode.disk_inode.addrs[indirect_pointer_block_index];
    if (indirect_address != 0) {
        // Free all pointed to blocks
        {
            const buffer = Buffer.read(inode.filesystem_device, indirect_address);
            defer buffer.release();

            const addresses = buffer.castData([indirect_pointer_count]u32);
            for (addresses.*) |address| {
                if (address != 0) {
                    fs.blockFree(inode.filesystem_device, address);
                }
            }
        }
        fs.blockFree(inode.filesystem_device, indirect_address);
        inode.disk_inode.addrs[indirect_pointer_block_index] = 0;
    }
    inode.disk_inode.size = 0;
}

// Copy stat information from inode.
// Caller must hold ip->lock.
pub fn getStatus(inode: *Inode) fs.FileStatus {
    return .{ .device = inode.filesystem_device, .inode_number = inode.inode_number, .type = inode.disk_inode.type, .link_count = inode.disk_inode.link_count, .size = inode.disk_inode.size };
}

// Read data from inode.
// Caller must hold ip->lock.
pub fn read(inode: *Inode, comptime address_kind: ad.AddressKind, destination: usize, offset: u32, count: u32) !u32 {
    if (offset > inode.disk_inode.size) return error.OutOfInodeRange;
    if (@addWithOverflow(offset, count)[1] == 1) return error.OffsetOverflows;

    var bytes_to_read = count;
    if (offset + count > inode.disk_inode.size) {
        bytes_to_read = inode.disk_inode.size - offset;
    }

    var bytes_read = 0;
    var current_offset = offset;
    var current_destination = destination;

    while (bytes_read < bytes_to_read) {
        const address = inode.getBlockAddress(current_offset / fs.block_size) catch break;
        const buffer = Buffer.read(inode.filesystem_device, address);
        defer buffer.release();

        const block_offset = current_offset % fs.block_size;
        const bytes_this_block = @min(bytes_to_read - bytes_read, fs.block_size - block_offset);
        try mem.eitherCopyOut(address_kind, current_destination, buffer.data[block_offset .. block_offset + bytes_this_block]);

        bytes_read += bytes_this_block;
        current_offset += bytes_this_block;
        current_destination += bytes_this_block;
    }

    return bytes_read;
}

// Write data to inode.
// Caller must hold ip->lock.
// Returns the number of bytes successfully written.
pub fn write(inode: *Inode, address_kind: ad.AddressKind, source: usize, offset: u32, count: u32) !u32 {
    if (offset > inode.disk_inode.size) return error.OutOfInodeRange;
    if (@addWithOverflow(offset, count)[1] == 1) return error.OffsetOverflows;
    if (offset + count > fs.block_size * max_file_block_count) return error.FileOverflow;

    var bytes_written = 0;
    var current_offset = offset;
    var current_source = source;

    while (bytes_written < count) {
        const address = inode.getBlockAddress(current_offset / fs.block_size) catch break;
        const buffer = Buffer.read(inode.filesystem_device, address);
        defer buffer.release();

        const block_offset = current_offset % fs.block_size;
        const bytes_this_block = @min(count - bytes_written, fs.block_size - block_offset);
        try mem.eitherCopyIn(address_kind, current_source, buffer.data[block_offset .. block_offset + bytes_this_block]);

        log.write(buffer);

        bytes_written += bytes_this_block;
        current_offset += bytes_this_block;
        current_source += bytes_this_block;
    }

    if (current_offset > inode.disk_inode.size) {
        inode.disk_inode.size = current_offset;
    }

    // write the i-node back to disk even if the size didn't change
    // because the loop above might have called bmap() and added a new
    // block to ip->addrs[].
    inode.update();

    return bytes_written;
}

// Paths

// Copy the next path element from path into name.
// Return a pointer to the element following the copied one.
// The returned path has no leading slashes,
// so the caller can check path.len == 0 to see if the name is the last one.
// If no name to remove, return null.
//
// Examples:
//   skipelem("a/bb/c", name) = "bb/c", setting name = "a"
//   skipelem("///a//bb", name) = "bb", setting name = "a"
//   skipelem("a", name) = "", setting name = "a"
//   skipelem("", name) = skipelem("////", name) = 0
//
fn skipPathElement(path: []const u8, name: *[]const u8) ?[]const u8 {
    // Skip leading slashes.
    const start = std.mem.findNone(u8, path, "/") orelse return null;

    const first_slash_index = std.mem.findScalar(u8, path[start..], '/') orelse {
        // no slashes after name
        name.* = path[start..];
        return "";
    };

    const name_end = start + first_slash_index;
    name.* = path[start..name_end];

    const non_slash_index = std.mem.findNone(u8, path[name_end + 1 ..], "/") orelse return "";
    const path_start = name_end + 1 + non_slash_index;

    return path[path_start..];
}

// Look up and return the inode for a path name.
// If returnParent, return the inode for the parent and copy the final
// path element into name, which must have room for DIRSIZ bytes.
// Must be called inside a transaction since it calls iput().
fn resolvePathHelper(path: []const u8, returnParent: bool, name: *[]const u8) ?*Inode {
    if (path.len == 0) return null;

    var current_inode = if (path[0] == '/') get(.root_fs_device, root_inode_number) else duplicate(Process.getCurrentForce().currentWorkingDirectory);
    var possible_path: ?[]const u8 = skipPathElement(path, name);

    // loop updates name value on each iteration
    while (possible_path) |current_path| : (possible_path = skipPathElement(current_path, name)) {
        current_inode = next_inode: {
            var put_inode = true;

            current_inode.lock();
            defer {
                current_inode.release();
                if (put_inode) current_inode.put();
            }

            if (current_inode.disk_inode.type != .directory) return null;

            if (returnParent and current_path.len == 0) {
                // don't put here
                put_inode = false;
                return current_inode;
            }

            const directory = Directory.init(current_inode);
            break :next_inode directory.lookupChild(name.*, null) orelse return null;
        };
    }

    if (returnParent) {
        current_inode.put();
        return null;
    }

    return current_inode;
}

pub fn resolvePath(path: []const u8) ?*Inode {
    var name: []const u8 = undefined;
    return resolvePathHelper(path, false, &name);
}

// name points to data inside path slice
pub fn resolvePathParent(path: []const u8, name: *[]const u8) ?*Inode {
    return resolvePathHelper(path, true, name);
}
