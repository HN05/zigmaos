const kernel = @import("root");
const common = @import("common");
const std = @import("std");

const elf = @import("elf.zig");
const Inode = @import("inode.zig");
const log = @import("log.zig");

const execution = kernel.execution;
const mem = kernel.memory;
const ad = mem.address;
const param = common.param;
const Process = execution.Process;
const page_size = mem.pages.page_size;

// Load a program segment into pagetable at virtual address va.
// va must be page-aligned
// and the pages from va to va+sz must already be mapped.
// Returns 0 on success, -1 on failure.
fn loadSegment(pageTable: mem.pages.PageTablePtr, virtualAddress: ad.UserAddress, inode: *Inode, offset: u32, size: u32) !void {
    var currentPage: u32 = 0;
    while (currentPage < size) : (currentPage += page_size) {
        const physicalAddress = mem.user.translateAddress(pageTable, virtualAddress.add(currentPage)) catch @panic("loadSegment: address should exist");

        // check if on last page
        const readCount = if (size - currentPage < page_size) size - currentPage else page_size;

        const readResult = try inode.read(.{ .kernel = physicalAddress }, offset + currentPage, readCount);

        if (readResult != readCount) return error.CouldNotRead;
    }
}

pub fn exec(path: []const u8, argv: [][]const u8) !usize {
    if (argv.len > param.MAXARG) return error.TooManyArguments;

    const process = Process.getCurrentForce();

    const pageTable = try mem.user.createPagetable(.fromPtr(process.trapFrame));
    var programSize: usize = 0;
    errdefer mem.user.freePageTable(pageTable, programSize);

    var inode: *Inode = undefined;
    var entry: usize = undefined;

    // load program into memory
    {
        log.beginOperation();
        defer log.endOperation();

        inode = Inode.resolvePath(path) orelse return error.CouldNotResolvePath;
        inode.lock();
        defer inode.releasePut();

        // Check ELF header
        var elfHeader: elf.ElfHeader = undefined;
        {
            const readBytes = try inode.read(.fromPtr(&elfHeader), 0, @sizeOf(elf.ElfHeader));
            if (readBytes != @sizeOf(elf.ElfHeader)) return error.CouldNotReadElfHeader;
            if (!elfHeader.elfIdentifier.isValid()) return error.CorruptedElfHeader;
        }
        entry = elfHeader.entry;

        // Load program into memory.
        var programHeader: elf.ProgramHeader = undefined;
        const programHeaderSize = @sizeOf(elf.ProgramHeader);

        for (0..elfHeader.programHeaderEntryNum) |programHeaderEntryIndex| {
            const offset = elfHeader.programHeaderOffset + programHeaderEntryIndex * programHeaderSize;
            const readBytes = try inode.read(.fromPtr(&programHeader), @intCast(offset), programHeaderSize);
            if (readBytes != programHeaderSize) return error.CouldNotReadProgramHeader;

            if (programHeader.type != .load) continue;
            if (programHeader.memorySize < programHeader.fileSize) return error.NotEnoughMemory;
            const newSize = @addWithOverflow(programHeader.virtualAddress, programHeader.memorySize);
            if (newSize[1] == 1) return error.MemoryAddressOverflow;

            const virtualAddress: ad.UserAddress = .fromInt(programHeader.virtualAddress);
            if (!virtualAddress.isPageAligned()) return error.MemoryNotPageAligned;

            const newProgramSize = try mem.user.alloc(pageTable, programSize, newSize[0], programHeader.flags.toPagePermissions());
            programSize = newProgramSize;

            try loadSegment(pageTable, virtualAddress, inode, @intCast(programHeader.offset), @intCast(programHeader.fileSize));
        }
    }

    const oldSize = process.size;

    // Allocate two pages at the next page boundary.
    // Make the first inaccessible as a stack guard.
    // Use the second as the user stack.
    const alignedProgramSize = mem.pages.pageRoundUp(programSize);
    programSize = try mem.user.alloc(pageTable, alignedProgramSize, alignedProgramSize + 2 * page_size, .{ .read = true, .write = true });

    mem.user.clearUser(pageTable, .fromInt(programSize - 2 * page_size));
    var stackPointer = programSize;
    const stackBase = stackPointer - page_size;

    var userStack: [param.MAXARG + 1]usize = undefined;

    // Push argument strings, prepare rest of stack in ustack.
    for (argv, 0..) |arg, index| {
        stackPointer -= arg.len + 1; // make room for terminator as well
        stackPointer -= stackPointer % 16; // riscv sp must be 16-byte aligned

        if (stackPointer < stackBase) return error.OutOfArgumentSpace;

        try mem.boundry.copyOutTerminated(pageTable, .fromInt(stackPointer), arg);
        userStack[index] = stackPointer;
    }
    userStack[argv.len] = 0;

    // push the array of argv[] pointers.
    stackPointer -= (argv.len + 1) * @sizeOf(usize); // make room for pointers and terminator
    stackPointer -= stackPointer % 16;
    if (stackPointer < stackBase) return error.OutOfArgumentPointerSpace;

    try mem.boundry.copyOut(pageTable, .fromInt(stackPointer), std.mem.sliceAsBytes(userStack[0..(argv.len + 1)]));

    // arguments to user main(argc, argv)
    // argc is returned via the system call return
    // value, which goes in a0.
    process.trapFrame.a1 = stackPointer;

    // Save program name for debugging.
    var last: usize = 0; // index of first char of program name
    for (path, 0..) |char, index| {
        if (char == '/') { // finds word after last /
            last = index + 1;
        }
    }
    const name = path[last..];

    const len = @min(name.len, process.nameBuffer.len);
    @memcpy(process.nameBuffer[0..len], name[0..len]);
    process.nameLength = len;

    // Commit to the user image.
    const oldPageTable = process.pageTable;
    process.pageTable = pageTable;
    process.size = programSize;
    process.trapFrame.epc = entry; // initial program counter = main
    process.trapFrame.sp = stackPointer;

    mem.user.freePageTable(oldPageTable, oldSize);

    return argv.len; // this ends up in a0, the first argument to main(argc, argv)
}
