const std = @import("std");
const com = @import("common");
const page_size = com.riscv.page_size;
const SpinLock = @import("spinlock.zig");
const kalloc = @import("kalloc.zig");
const PagePointer = @import("address.zig").PagePointer;
const Book = com.ringbuf.Book;
const MagicBuf = com.ringbuf.MagicBuf;
const Rb = com.ringbuf;
const mem = @import("memory.zig");
const execution = @import("execution.zig");
const Process = execution.Process;
const fslog = @import("log.zig");
const ad = @import("address.zig");

// we expose these in common because they will be usIed by the user lib
const RINGBUF_SIZE = com.ringbuf.RINGBUF_SIZE;
const MAX_NAME_LEN = com.ringbuf.MAX_NAME_LEN;
const MAX_RINGBUFS = com.ringbuf.MAX_RINGBUFS;

const RingbufManager = @This();

/// Global spinlock to protect the ringbuf's array
var spinlock: SpinLock = .{ .name = "ringbuf_man" };
/// Global array of ringbufs
var ringbufs: [MAX_RINGBUFS]Ringbuf = [_]Ringbuf{.{}} ** MAX_RINGBUFS;

const Owner = extern struct {
    proc: ?*Process = null,
    vbuf: usize = 0,
    vbook: usize = 0,
};

const Ringbuf = extern struct {
    const Self = @This();

    refcount: u32 = 0,
    owners: [2]Owner = [_]Owner{.{}} ** 2,
    name_buf: [MAX_NAME_LEN]u8 = [_]u8{0} ** MAX_NAME_LEN,
    buf_pages: [RINGBUF_SIZE]?PagePointer = [_]?PagePointer{null} ** 16,
    book_page: ?PagePointer = null,

    /// Activates this ringbuf
    /// Refcount should be 0 (deactivated)
    /// Must be holding the lock
    pub fn activate(self: *Self, name: []const u8) !void {
        if (self.refcount > 0) return error.AlreadyActive;
        if (name.len > MAX_NAME_LEN or name.len == 0) return error.BadNameLength;
        @memcpy(&self.name_buf, name);

        // allocate all the buf pages
        const alloced_page_count = blk: {
            for (&self.buf_pages, 0..) |*buf_pg_ptr, i| {
                const page = kalloc.allocPage() orelse break :blk i;
                buf_pg_ptr.* = page;
            }
            break :blk self.buf_pages.len;
        };
        self.book_page = kalloc.allocPage();
        // undo all allocations if we failed to allocate any of the pages
        if (alloced_page_count < self.buf_pages.len or self.book_page == null) {
            if (self.book_page != null) {
                kalloc.freePage(self.book_page.?) catch @panic("failed to free page");
                self.book_page = null;
            }
            for (self.buf_pages[0..alloced_page_count]) |*buf_pg_ptr| {
                const buf: PagePointer = buf_pg_ptr.*.?;
                kalloc.freePage(buf) catch @panic("failed to free page");
                buf_pg_ptr.* = null;
            }
            return error.OutOfMemory;
        } else {
            // set up bookkeeping
            const book_p: *Book = @ptrCast(self.book_page.?);
            book_p.* = .{};
        }
    }
    /// Deactivates this ring buffer and frees its resources
    /// Must be holding a lock
    pub fn deactivate(self: *Self) void {
        for (&self.buf_pages) |*pg_o_p| {
            if (pg_o_p.*) |pg| {
                kalloc.freePage(pg) catch @panic("failed to free page");
                pg_o_p.* = null;
            }
        }
        if (self.book_page == null) @panic("deactivate: book page is already null");
        const book_p: *Book = @ptrCast(self.book_page.?);
        book_p.* = .{};
        kalloc.freePage(self.book_page.?) catch @panic("failed to free page");
        if (self.owners[0].proc != null or self.owners[1].proc != null) @panic("ringbuf has owners");
        self.* = .{};
    }

    /// Disowns a ringbuf from a process
    /// If the ringbuf is not owned by the process, do nothing
    /// Decrements the refcount and deactivates the ringbuf if the refcount is 0
    pub fn disownIfOwned(self: *Self, proc: *Process) void {
        const owner: *Owner = brk: {
            if (self.owners[0].proc == proc) {
                break :brk &self.owners[0];
            } else if (self.owners[1].proc == proc) {
                break :brk &self.owners[1];
            } else {
                return;
            }
        };
        owner.proc = null;
        if (owner.vbuf != 0) {
            mem.uvmUnmap(proc.pageTable, .fromInt(owner.vbuf), RINGBUF_SIZE * 2, false);
            owner.vbuf = 0;
        } else @panic("disowning a ringbuf without a vbuf");
        if (owner.vbook != 0) {
            mem.uvmUnmap(proc.pageTable, .fromInt(owner.vbook), 1, false);
            owner.vbook = 0;
        } else @panic("disowning a ringbuf without a vbook");
        self.refcount -= 1;
        proc.ownedRingbufsCount -= 1;
        // we choose to free the physical memory in deactivate, not in uvmunmap
        if (self.refcount == 0) self.deactivate();
    }
};

fn findFreeRingbuf() ?*Ringbuf {
    for (&ringbufs) |*rb| {
        if (rb.refcount == 0) return rb;
    }
    return null;
}

fn findRingbufByName(name: []const u8) ?*Ringbuf {
    for (&ringbufs) |*rb| {
        if (rb.refcount == 0) continue;
        const name_str: [*:0]const u8 = @ptrCast(&rb.name_buf);
        const rb_name = std.mem.span(name_str);
        if (std.mem.eql(u8, name, rb_name)) return rb;
    }
    return null;
}

/// Ringbuf system call
/// - name_str: name of the ringbuf
/// - op: open or close
/// - addr_va: pointer to the address of the ringbuf.
///   On open, the address of the ringbuf is written out.
///   On close, the address of the ringbuf is read in.
///
///  We use the process's top_free_uvm_pg to find a slot in the userspace.
///  We map the ringbuf twice contiguously, and the book page right under it.
fn ringbuf(name: []const u8, op: Rb.Op, addr_va: ad.UserAddress) Rb.RingbufError!void {
    spinlock.acquire();
    defer spinlock.release();

    if (name.len > MAX_NAME_LEN or name.len == 0) return error.BadNameLength;

    var proc: *Process = Process.getCurrent() orelse @panic("myproc is null");

    switch (op) {
        .open => {
            // find the named ringbuf or activate a free slot
            var owner: *Owner = undefined;
            const rb: *Ringbuf = blk: {
                if (findRingbufByName(name)) |rb| {
                    if (rb.refcount == 0) @panic("inactive ringbuf found by name");
                    const owner_count = blk2: {
                        var oc: u8 = 0;
                        for (&rb.owners) |o| {
                            if (o.proc) |p| {
                                oc += 1;
                                if (p == proc) return error.AlreadyIsOwner;
                            }
                        }
                        break :blk2 oc;
                    };
                    if (owner_count == 0) @panic("orphaned ringbuf found by name");
                    if (owner_count == 2) return error.AlreadyTwoOwners;

                    owner = if (rb.owners[1].proc == null) &rb.owners[1] else &rb.owners[0];
                    break :blk rb;
                } else if (findFreeRingbuf()) |rb| {
                    try rb.activate(name);
                    if (rb.owners[0].proc != null or rb.owners[1].proc != null) @panic("free ringbuf should not have any owners");
                    owner = &rb.owners[0];
                    break :blk rb;
                } else {
                    return error.NoFreeRingbuf;
                }
            };
            owner.proc = proc;
            proc.ownedRingbufsCount += 1;
            rb.refcount += 1;
            errdefer {
                owner.proc = null;
                rb.refcount -= 1;
                rb.deactivate();
            }
            // map all physical pages into the process twice contiguously
            for (0..2) |_| {
                for (&rb.buf_pages) |pg| {
                    // TODO: undo all mappings if we fail to map a page
                    if (pg == null) @panic("buf page is null");
                    mem.userVirtualMap(proc.pageTable, proc.topFreeVirtualPage, .fromInt(@intFromPtr(pg.?)), page_size, .{ .read = true, .write = true }) catch return Rb.RingbufError.MapPagesFailed;
                    proc.topFreeVirtualPage = proc.topFreeVirtualPage.sub(page_size);
                }
            }
            // map the book page right under the ringbuf
            if (rb.book_page == null) @panic("book page is null");
            mem.userVirtualMap(proc.pageTable, proc.topFreeVirtualPage, .fromInt(@intFromPtr(rb.book_page.?)), page_size, .{ .read = true, .write = true }) catch return Rb.RingbufError.MapPagesFailed;
            proc.topFreeVirtualPage = proc.topFreeVirtualPage.sub(page_size);
            // | btm of ringbuf    |
            // | book              |
            // | top_free_uvm_pg   |
            const book_vaddr = proc.topFreeVirtualPage.add(1 * page_size);
            var ringbuf_loc = proc.topFreeVirtualPage.add(2 * page_size);
            // store the mapped addresses
            owner.vbook = book_vaddr.toInt();
            owner.vbuf = ringbuf_loc.toInt();

            // copy the address of the ringbuf into userspace
            // TODO: undo everything if we fail to copyout
            mem.copyOut(proc.pageTable, addr_va, std.mem.asBytes(&ringbuf_loc)) catch return Rb.RingbufError.CopyOutFailed;

            // leave a guard page
            proc.topFreeVirtualPage = proc.topFreeVirtualPage.sub(page_size);
        },
        .close => {
            var vaddr: ?*anyopaque = null;
            // copy the address of the ringbuf into kernel space
            mem.copyIn(proc.pageTable, std.mem.asBytes(&vaddr), addr_va) catch return Rb.RingbufError.CopyInFailed;

            const rb = findRingbufByName(name) orelse return error.NameNotFound;
            const ringbuf_vaddr: usize = @intFromPtr(vaddr orelse return error.NoAddrGiven);

            const owner: *Owner = blk: {
                if (proc == rb.owners[0].proc) {
                    break :blk &rb.owners[0];
                } else if (proc == rb.owners[1].proc) {
                    break :blk &rb.owners[1];
                } else return error.NotOwner;
            };
            const vbuf_u: usize = owner.vbuf;
            const vbook_u: usize = owner.vbook;
            if (vbuf_u != ringbuf_vaddr) return error.BadAddr;
            if (vbook_u != ringbuf_vaddr - page_size) return error.BadAddr;

            if (rb.refcount == 0) return error.AlreadyInactive;
            if (rb.book_page == null) @panic("book page is null");

            // disown the ringbuf from the process
            // disown also unmaps the pages and frees the physical memory if the refcount is 0
            rb.disownIfOwned(proc);

            // To help us avoid *some* fragmentation for the top_free_uvm_pg,
            // we'll bump up the top_free_uvm_pg if this is the lowest ringbuf.
            // | guard page        | <- new proc.top_free_uvm_pg
            //  ....   rb.buf_pages.len * 2 pages
            // | btm of ringbuf    | <- ringbuf_vaddr
            // | book              |
            // | guard pg          |
            // | top_free_uvm_pg   | <- old proc.top_free_uvm_pg
            if (proc.topFreeVirtualPage.toInt() == ringbuf_vaddr - 3 * page_size) {
                // move up by guard page + book + double mapped ringbuf
                proc.topFreeVirtualPage = proc.topFreeVirtualPage.add(page_size * (1 + 1 + 2 * rb.buf_pages.len));
            }
        },
    }
}

const sysargs = @import("sysargs.zig");
pub fn syscall() u64 {
    fslog.beginOperation();
    defer fslog.endOperation();

    var buffer: [MAX_NAME_LEN]u8 = undefined;

    const len = sysargs.getString(.a0, &buffer) catch {
        // sys_FOO C functions return a uint64 yet return -1 on errors
        // Zig has stricter rules about implicit casts + overflow and underflow,
        // so we'll need to return a bitcasted negative on errors
        return @bitCast(com.ringbuf.intFromErr(com.ringbuf.RingbufError, error.BadNameLength));
    };

    const name: []const u8 = buffer[0..len];
    const open = sysargs.getInt(.a1);
    const addr = sysargs.getAddress(.a2) orelse {
        return @bitCast(com.ringbuf.intFromErr(com.ringbuf.RingbufError, error.NoAddrGiven));
    };

    ringbuf(name, @enumFromInt(open), addr) catch |err| {
        return @bitCast(com.ringbuf.intFromErr(com.ringbuf.RingbufError, err));
    };
    return 0;
}

fn find_owned_ringbuf(proc: *Process) ?*Ringbuf {
    for (&ringbufs) |*rb| {
        if (rb.refcount > 0) {
            if (rb.owners[0].proc == proc or rb.owners[1].proc == proc) return rb;
        }
    }
    return null;
}

pub fn ringbuf_disown_all(proc: *Process) void {
    spinlock.acquire();
    defer spinlock.release();
    for (&ringbufs) |*rb| {
        rb.disownIfOwned(proc);
    }
}
