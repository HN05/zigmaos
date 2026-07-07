const std = @import("std");

const Inode = @import("inode.zig");
const blocks = @import("blocks");

const Directory = @This();

pub const entry_size = 32;
pub const max_entry_name_length = entry_size - @sizeOf(u32) - @sizeOf(u8);

inode: *Inode,

// Directory is a file containing a sequence of dirent structures.
pub const DirectoryEntry = extern struct {
    inode_number: u32 = 0,
    name_length: u8 = 0,
    name_buffer: [max_name_length]u8 = undefined,

    pub const max_name_length = max_entry_name_length;

    pub fn nameSlice(entry: *const DirectoryEntry) []const u8 {
        return entry.name_buffer[0..entry.name_length];
    }

    pub fn matchesName(entry: *const DirectoryEntry, name: []const u8) bool {
        return std.mem.eql(u8, name, entry.nameSlice());
    }
};

pub fn init(inode: *Inode) Directory {
    if (inode.disk_inode.type != .directory) {
        @panic("Directory.init: inode is not a directory");
    }

    return .{ .inode = inode };
}

// Look for a directory entry in a directory.
// If found, set *poff to byte offset of entry.
pub fn lookupChild(directory: *const Directory, name: []const u8, entry_offset: ?*u32) ?*Inode {
    var current_offset: u32 = 0;
    var entry: DirectoryEntry = undefined;

    while (current_offset < directory.inode.disk_inode.size) : (current_offset += entry_size) {
        const read_bytes = directory.inode.read(.fromPtr(&entry), current_offset, entry_size) catch @panic("dirlookup read failed");
        if (read_bytes != entry_size) @panic("did not read enough bytes dirlookup");

        if (entry.inode_number == 0) continue;

        if (entry.matchesName(name)) {
            // entry matches path element
            if (entry_offset) |destination| {
                destination.* = current_offset;
            }
            return .get(directory.inode.filesystem_device, entry.inode_number);
        }
    }
    return null;
}

// Write a new directory entry (name, inum) into the directory dp.
pub fn linkEntry(directory: *const Directory, name: []const u8, inode_number: u32) !void {
    if (name.len > DirectoryEntry.max_name_length) return error.NameToLong;

    // Check that name is not present.
    const existing_inode = directory.lookupChild(name, null);
    if (existing_inode) |inode| {
        inode.put();
        return error.AlreadyExists;
    }

    // Look for an empty dirent.
    var current_offset: u32 = 0;
    var entry: DirectoryEntry = .{};

    while (current_offset < directory.inode.disk_inode.size) : (current_offset += entry_size) {
        const read_bytes = directory.inode.read(.fromPtr(&entry), current_offset, entry_size) catch @panic("linkEntry: could not read directory");
        if (read_bytes != entry_size) @panic("did not read enough bytes dirlookup");

        if (entry.inode_number == 0) break;
    }

    @memcpy(&entry.name_buffer, name);
    entry.name_length = @intCast(name.len);
    entry.inode_number = inode_number;

    const written_bytes = try directory.inode.write(.fromPtr(&entry), current_offset, entry_size);
    if (written_bytes != entry_size) return error.WriteMalformed;
}

pub fn isEmpty(directory: *const Directory) bool {
    const directory_offset = @sizeOf(DirectoryEntry);
    var index: usize = 2; // skip past . and ..
    var directory_entry: DirectoryEntry = undefined;

    while (index * directory_offset < directory.inode.disk_inode.size) : (index += 1) {
        const read_bytes = directory.inode.read(.fromPtr(&directory_entry), @intCast(index * directory_offset), directory_offset) catch @panic("can't read directory");
        if (read_bytes != directory_offset) {
            @panic("isDirectoryEmpty: readi");
        }

        if (directory_entry.inode_number != 0) {
            return false;
        }
    }

    return true;
}
