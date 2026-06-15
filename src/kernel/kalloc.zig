const std = @import("std");
const CSpinlock = @import("spinlock.zig").CSpinlock;
const memlayout = @import("../kernel/memlayout.zig");
const pagesize = @import("common").riscv.pagesize;
const assert = std.debug.assert;
const log = std.log.scoped(.kalloc);

// first address after kernel.
pub const end = @extern([*c]c_char, .{ .name = "end" });

const Block = extern struct {
    next: ?*Block,
};

var lock: CSpinlock = undefined;
var freelist: ?*Block = null;

pub export fn kinit() void {
    log.info("setting up page allocator", .{});
    lock.init("kalloc");
    freerange(@ptrCast(end), @ptrFromInt(memlayout.PHYSTOP));
}

pub export fn freerange(pa_start: *anyopaque, pa_end: *anyopaque) void {
    const p_start_offset: usize = @intFromPtr(pa_start);
    var p_offset = std.mem.alignForward(usize, p_start_offset, pagesize);
    const p_end_offset: usize = @intFromPtr(pa_end);
    while (p_offset + pagesize <= p_end_offset) : (p_offset += pagesize) {
        const ptr: [*]u8 = @ptrFromInt(p_offset);
        freePage(@alignCast(ptr[0..pagesize])) catch {
            @panic("freerange error");
        };
    }
}

pub export fn kfree(pa: *anyopaque) void {
    const ptr: [*]u8 = @ptrCast(pa);
    freePage(@alignCast(ptr[0..pagesize])) catch {
        @panic("kfree error");
    };
}

pub export fn kalloc() ?*anyopaque {
    const page_slice_o = allocPage();
    if (page_slice_o) |pg| {
        return pg.ptr;
    } else return null;
}

/// Frees page
/// Failures are in the case of a bad given address
pub fn freePage(pa: PagePtr) !void {
    const pa_u: usize = @intFromPtr(pa);
    if (pa_u % pagesize != 0) return error.AddressNotPageAligned;
    const end_u: usize = @intFromPtr(end);
    if (pa_u < end_u) return error.AddressTooLow;
    if (pa_u >= memlayout.PHYSTOP) return error.AddressTooHigh;
    // // Fill with junk to catch dangling refs.
    @memset(pa[0..pagesize], 1);
    const b: *Block = @alignCast(@ptrCast(pa));
    lock.acquireLock();
    defer lock.releaseLock();
    b.next = freelist;
    freelist = b;
}

pub const PagePtr = *align(pagesize) [pagesize]u8;

pub fn allocPage() ?PagePtr {
    lock.acquireLock();
    defer lock.releaseLock();
    const r_o = freelist;
    if (r_o) |r| {
        freelist = r.next;
    }
    if (r_o) |r| {
        const ptr: [*]u8 = @ptrCast(r);
        @memset(ptr[0..pagesize], 5);
    } else {
        // log.warn("out of memory", .{});
        return null;
    }
    const ptr: [*]align(pagesize) u8 = @alignCast(@ptrCast(r_o.?));
    return ptr[0..pagesize];
}

pub const page_allocator = std.mem.Allocator{
    .ptr = undefined,
    .vtable = &std.mem.Allocator.VTable{
        .alloc = alloc,
        .resize = resize,
        .free = free,
    },
};

fn alloc(_: *anyopaque, n: usize, log2_align: u8, ra: usize) ?[*]u8 {
    _ = ra;
    _ = log2_align;
    assert(n > 0);
    if (n > std.math.maxInt(usize) - (pagesize - 1)) return null;
    if (n > pagesize) @panic("Unimplemented: n > PGSIZE");
    const aligned_len = std.mem.alignForward(usize, n, pagesize);
    const page_count = aligned_len / pagesize;
    var start_slice = allocPage() orelse return null;
    for (1..page_count) |i| {
        const new_slice = allocPage() orelse {
            for (0..i) |j| {
                freePage(@alignCast(start_slice.ptr[j * pagesize ..][0..pagesize])) catch @panic("Alloc failed");
            }
            return null;
        };
        const start_ptr_u: usize = @ptrFromInt(start_slice.ptr);
        const new_ptr_u: usize = @ptrFromInt(new_slice.ptr);
        if (start_ptr_u + i * pagesize != new_ptr_u) {
            for (0..i) |j| {
                freePage(@alignCast(start_slice.ptr[j * pagesize ..][0..pagesize])) catch @panic("Freeing after alloc failure failed");
            }
            freePage(new_slice) catch @panic("Freeing after alloc failure failed");
            return null;
        }
    }
    assert(std.mem.isAligned(@intFromPtr(start_slice.ptr), pagesize));
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
    const new_size_aligned = std.mem.alignForward(usize, new_size, pagesize);
    const buf_aligned_len = std.mem.alignForward(usize, buf_unaligned.len, pagesize);
    if (new_size_aligned == buf_aligned_len) return true;
    if (new_size_aligned < buf_aligned_len) {
        for (0..(buf_aligned_len - new_size_aligned) / pagesize) |i| {
            freePage(@alignCast(buf_unaligned.ptr[i * pagesize ..][0..pagesize])) catch @panic("Could not free page");
        }
        return true;
    }
    return false;
}

fn free(_: *anyopaque, slice: []u8, log2_buf_align: u8, return_address: usize) void {
    _ = return_address;
    _ = log2_buf_align;
    const buf_aligned_len = std.mem.alignForward(usize, slice.len, pagesize);
    const page_count = buf_aligned_len / pagesize;
    for (0..page_count) |i| {
        freePage(@alignCast(slice.ptr[i * pagesize ..][0..pagesize])) catch @panic("Could not free page");
    }
}
