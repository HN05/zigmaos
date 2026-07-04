const std = @import("std");
const kernel = @import("root");

const memlayout = @import("layout.zig");
const ad = @import("address.zig");
const pg = @import("pages.zig");

const conc = kernel.concurrency;
const page_size = pg.page_size;
const assert = std.debug.assert;
const log = std.log.scoped(.kalloc);

const Block = extern struct {
    next: ?*Block,
};

pub const InitialValue = enum {
    zeroed, garbage, 
};

var lock: conc.Mutex = .init(.spin, "memory allocation");
var freelist: ?*Block = null;

pub fn init() void {
    log.info("setting up page allocator", .{});
    freerange(memlayout.kernelEndAddress(), memlayout.physical_stop_address);
}

fn freerange(pa_start: ad.KernelAddress, pa_end: ad.KernelAddress) void {
    var p_offset = std.mem.alignForward(usize, pa_start.toInt(), page_size);
    while (p_offset + page_size <= pa_end.toInt()) : (p_offset += page_size) {
        const ptr: [*]u8 = @ptrFromInt(p_offset);
        freePage(@alignCast(ptr[0..page_size])) catch {
            @panic("freerange error");
        };
    }
}

/// Frees page
/// Failures are in the case of a bad given address
pub fn freePage(page: pg.PagePointer) !void {
    const pa = ad.KernelAddress.fromPtr(page);
    if (pa.isOutOfRange()) {
        return error.AddressOutOfRange;
    }

    // Fill with junk to catch dangling refs.
    @memset(page, 1);
    const b: *Block = @ptrCast(@alignCast(page));

    lock.acquire();
    defer lock.release();

    b.next = freelist;
    freelist = b;
}

pub fn allocPage(value: InitialValue) ?pg.PagePointer {
    lock.acquire();
    defer lock.release();

    const r_o = freelist;
    if (r_o) |r| {
        freelist = r.next;
    }
    if (r_o) |r| {
        const ptr: [*]u8 = @ptrCast(r);
        @memset(ptr[0..page_size], 5);
    } else {
        // log.warn("out of memory", .{});
        return null;
    }
    const ptr: [*]align(page_size) u8 = @ptrCast(@alignCast(r_o.?));
    const page = ptr[0..page_size];
    if (value == .zeroed) {
        @memset(page, 0);
    }
    return page;
}

pub fn allocPageForce(value: InitialValue) pg.PagePointer {
    return allocPage(value) orelse @panic("could not allocate memory");
}

pub const page_allocator = std.mem.Allocator{
    .ptr = undefined,
    .vtable = &std.mem.Allocator.VTable{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    },
};

fn alloc(_: *anyopaque, n: usize, log2_align: u8, ra: usize) ?[*]u8 {
    _ = ra;
    _ = log2_align;
    assert(n > 0);
    if (n > std.math.maxInt(usize) - (page_size - 1)) return null;
    if (n > page_size) @panic("Unimplemented: n > PGSIZE");
    const aligned_len = std.mem.alignForward(usize, n, page_size);
    const page_count = aligned_len / page_size;
    var start_slice = allocPage(.garbage) orelse return null;
    for (1..page_count) |i| {
        const new_slice = allocPage(.garbage) orelse {
            for (0..i) |j| {
                freePage(@alignCast(start_slice.ptr[j * page_size ..][0..page_size])) catch @panic("Alloc failed");
            }
            return null;
        };
        const start_ptr_u: usize = @ptrFromInt(start_slice.ptr);
        const new_ptr_u: usize = @ptrFromInt(new_slice.ptr);
        if (start_ptr_u + i * page_size != new_ptr_u) {
            for (0..i) |j| {
                freePage(@alignCast(start_slice.ptr[j * page_size ..][0..page_size])) catch @panic("Freeing after alloc failure failed");
            }
            freePage(new_slice) catch @panic("Freeing after alloc failure failed");
            return null;
        }
    }
    assert(std.mem.isAligned(@intFromPtr(start_slice.ptr), page_size));
    return start_slice.ptr;
}

fn resize(
    _: *anyopaque,
    buf_unaligned: []u8,
    log2_buf_align: u8,
    new_size: usize,
    return_address: usize,
) bool {
    _ = return_address;
    _ = log2_buf_align;
    const new_size_aligned = std.mem.alignForward(usize, new_size, page_size);
    const buf_aligned_len = std.mem.alignForward(usize, buf_unaligned.len, page_size);
    if (new_size_aligned == buf_aligned_len) return true;
    if (new_size_aligned < buf_aligned_len) {
        for (0..(buf_aligned_len - new_size_aligned) / page_size) |i| {
            freePage(@alignCast(buf_unaligned.ptr[i * page_size ..][0..page_size])) catch @panic("Could not free page");
        }
        return true;
    }
    return false;
}

fn free(_: *anyopaque, slice: []u8, log2_buf_align: u8, return_address: usize) void {
    _ = return_address;
    _ = log2_buf_align;
    const buf_aligned_len = std.mem.alignForward(usize, slice.len, page_size);
    const page_count = buf_aligned_len / page_size;
    for (0..page_count) |i| {
        freePage(@alignCast(slice.ptr[i * page_size ..][0..page_size])) catch @panic("Could not free page");
    }
}

fn remap(_: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
    //  TODO: implement
    _ = memory;
    _ = alignment;
    _ = new_len;
    _ = ret_addr;
}
