const kernel = @import("root");

const pg = @import("pages.zig");
const ad = @import("address.zig");
const uvm = @import("user_memory.zig");

const execution = kernel.execution;
const page_size = pg.page_size;
const PageTablePointer = pg.PageTablePtr;

// Copy from kernel to user.
pub fn copyOut(pgTable: PageTablePointer, destVirtualAddress: ad.UserAddress, source: []const u8) !void {
    var destination = destVirtualAddress;
    var remaining = source;

    while (remaining.len > 0) {
        const virtualAligned = destination.pageAlignDown();
        const physicalPage = try uvm.translateAddress(pgTable, virtualAligned);
        const physicalDestination = physicalPage.add(destination.pageOffset());

        const byteWriteCount = @min(page_size - destination.pageOffset(), remaining.len);

        @memcpy(physicalDestination.asPtr([*]u8), remaining[0..byteWriteCount]);

        remaining = remaining[byteWriteCount..];
        destination = destination.add(byteWriteCount);
    }
}

// Copy from user to kernel. fills up destination
pub fn copyIn(pgTable: PageTablePointer, destination: []u8, sourceVirtualAddress: ad.UserAddress) !void {
    var source = sourceVirtualAddress;
    var remaining = destination;

    while (remaining.len > 0) {
        const virtualAligned = source.pageAlignDown();
        const physicalPage = try uvm.translateAddress(pgTable, virtualAligned);
        const physicalSource = physicalPage.add(source.pageOffset());

        const byteWriteCount = @min(page_size - source.pageOffset(), remaining.len);

        @memcpy(remaining[0..byteWriteCount], physicalSource.asPtr([*]u8));

        remaining = remaining[byteWriteCount..];
        source = source.add(byteWriteCount);
    }
}

// Copy a null-terminated string from user to kernel.
// Copy bytes to dst from virtual address srcva in a given page table,
// until a '\0', or fills destination.
// Not guaranteed to include '\0' and returns str length without it
pub fn copyInString(pgTable: PageTablePointer, destination: []u8, sourceVirtualAddress: ad.UserAddress) !usize {
    var length: usize = 0;
    var remaining = destination;
    var source = sourceVirtualAddress;

    while (remaining.len > 0) {
        const virtualAligned = source.pageAlignDown();
        const physicalPage = try uvm.translateAddress(pgTable, virtualAligned);

        const byteWriteCount = @min(page_size - source.pageOffset(), remaining.len);

        const physicalSource = physicalPage.add(source.pageOffset());
        const charSource = physicalSource.asPtr([*]u8);

        for (0..byteWriteCount) |i| {
            remaining[i] = charSource[i];

            // check for '\0'
            if (charSource[i] == 0) return length + i; // not +1 since '\0' does not count
        }
        remaining = remaining[byteWriteCount..];
        source = source.add(byteWriteCount);
        length += byteWriteCount;
    }
    return error.RanOutOfSpace;
}

pub fn copyOutTerminated(pgTable: PageTablePointer, destVirtualAddress: ad.UserAddress, source: []const u8) !void {
    try copyOut(pgTable, destVirtualAddress, source);
    const terminator: [1]u8 = .{0};
    try copyOut(pgTable, destVirtualAddress.add(source.len), &terminator);
}

// Copy to either a user address, or kernel address,
pub fn eitherCopyOut(address: ad.AnyAddress, source: []const u8) !void {
    const process = try execution.Process.getCurrentThrows();

    switch (address) {
        .user => |user_addr| {
            try copyOut(process.pageTable, user_addr, source);
        },
        .kernel => |kern_addr| {
            @memmove(kern_addr.asPtr([*]u8), source);
        },
    }
}

// Copy from either a user address, or kernel address,
pub fn eitherCopyIn(address: ad.AnyAddress, destination: []u8) !void {
    const process = try execution.Process.getCurrentThrows();

    switch (address) {
        .user => |user_addr| {
            try copyIn(process.pageTable, destination, user_addr);
        },
        .kernel => |kern_addr| {
            @memmove(destination, kern_addr.asPtr([*]u8));
        },
    }
}
