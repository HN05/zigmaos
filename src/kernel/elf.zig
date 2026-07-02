// Format of an ELF executable file
const ad = @import("address.zig");

const ElfIdentifier = extern struct {
    pub const correctMagic: u32 = 0x464C457F; // "\x7FELF" in little endian

    magic: u32, // must equal ELF_MAGIC
    rest: [12]u8, // don't care

    pub fn isValid(self: *ElfIdentifier) bool {
        return self.magic == correctMagic;
    }
};

// File header
pub const ElfHeader = extern struct {
    elfIdentifier: ElfIdentifier,
    type: u16,
    machine: u16,
    version: u32,
    entry: usize,
    programHeaderOffset: u64,
    sectionHeaderOffset: u64,
    flags: u32,
    elfHeaderSize: u16, // size of this header
    programHeaderEntrySize: u16,
    programHeaderEntryNum: u16,
    sectionHeaderEntrySize: u16,
    sectionHeaderEntryNum: u16,
    sectionHeaderStringTableIndex: u16,
};

const ProgramType = enum(u32) {
    load = 1,
};

const ProgramHeaderFlags = packed struct(u32) {
    execute: bool = false,
    write: bool = false,
    read: bool = false,
    reserved: u29 = 0,

    pub fn toPagePermissions(self: *ProgramHeaderFlags) ad.PagePermissions {
        return .{ .execute = self.execute, .read = self.read, .write = self.write };
    }
};

// Program section header
pub const ProgramHeader = extern struct {
    type: ProgramType,
    flags: ProgramHeaderFlags,
    offset: u64,
    virtualAddress: usize,
    physicalAddress: usize,
    fileSize: u64,
    memorySize: u64,
    alignment: u64,
};
