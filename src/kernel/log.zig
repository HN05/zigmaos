// Simple logging that allows concurrent FS system calls.
//
// A log transaction contains the updates of multiple FS system
// calls. The logging system only commits when there are
// no FS system calls active. Thus there is never
// any reasoning required about whether a commit might
// write an uncommitted system call's updates to disk.
//
// A system call should call begin_op()/end_op() to mark
// its start and end. Usually begin_op() just increments
// the count of in-progress FS system calls and returns.
// But if it thinks the log is close to running out, it
// sleeps until the last outstanding end_op() commits.
//
// The log is a physical re-do log containing disk blocks.
// The on-disk log format:
//   header block, containing block #s for block A, B, C, ...
//   block A
//   block B
//   block C
//   ...
// Log appends are synchronous.

const common = @import("common");
const Device = @import("device.zig");
const fs = @import("filesystem.zig");
const Buffer = @import("buffer.zig");
const execution = @import("execution.zig");
const conc = @import("concurrency.zig");

// Contents of the header block, used for both the on-disk header block
// and to keep track in memory of logged block# before commit.
const Header = struct {
    length: u32,
    block: [common.param.log_size]u32,

    pub fn copyFrom(destination: *Header, source: *const Header) void {
        destination.length = source.length;
        for (0..destination.length) |index| {
            destination.block[index] = source.block[index];
        }
    }
};

comptime {
    if (@sizeOf(Header) > fs.block_size) @compileError("too big logheader");
}

const Log = struct {
    lock: conc.Mutex,
    start: u32,
    size: u32,
    outstanding: u32, // how many FS sys calls are executing.
    is_commiting: bool, // in commit(), please wait.
    device: Device.ID,
    header: Header,
};

var log: Log = undefined;

pub fn init(device: Device.ID, superblock: fs.SuperBlock) void {
    log = .{
        .lock = .init(.spin, "log"),
        .start = superblock.logstart,
        .size = superblock.nlog,
        .outstanding = 0,
        .is_commiting = false,
        .device = device,
        .header = .{ .length = undefined, .block = undefined },
    };
    recoverFromLog();
}

// Copy committed blocks from log to their home location
fn installTransaction(is_recovering: bool) void {
    for (0..log.header.length) |tail| {
        const log_buffer = Buffer.read(log.device, @intCast(log.start + tail + 1));
        defer log_buffer.release();

        const destination_buffer = Buffer.read(log.device, log.header.block[tail]);
        defer destination_buffer.release();

        @memmove(&destination_buffer.data, &log_buffer.data);

        destination_buffer.write(); // write destination to disk
        if (!is_recovering) {
            destination_buffer.unpin();
        }
    }
}

// Read the log header from disk into the in-memory log header
fn readHead() void {
    const buffer = Buffer.read(log.device, log.start);
    defer buffer.release();

    const disk_header: *Header = buffer.castData(Header);

    log.header.copyFrom(disk_header);
}
// Write in-memory log header to disk.
// This is the true point at which the
// current transaction commits.
fn writeHead() void {
    const buffer = Buffer.read(log.device, log.start);
    defer buffer.release();

    const disk_header: *Header = buffer.castData(Header);
    disk_header.copyFrom(&log.header);

    buffer.write();
}

fn recoverFromLog() void {
    readHead();
    installTransaction(true); // if committed, copy from log to disk
    log.header.length = 0;
    writeHead(); // clear the log
}

// called at the start of each FS system call.
pub fn beginOperation() void {
    log.lock.acquire();
    defer log.lock.release();

    while (true) {
        const possible_log_size = log.header.length + (log.outstanding + 1) * common.param.max_num_operation_blocks;

        if (log.is_commiting or possible_log_size > common.param.log_size) {
            log.lock.sleepWithLock(&log);
        } else {
            log.outstanding += 1;
            break;
        }
    }
}
// called at the end of each FS system call.
// commits if this was the last outstanding operation.
pub fn endOperation() void {
    var do_commit = false;
    {
        log.lock.acquire();
        defer log.lock.release();

        log.outstanding -= 1;
        if (log.is_commiting) @panic("log commiting");

        if (log.outstanding == 0) {
            do_commit = true;
            log.is_commiting = true;
        } else {
            // begin_op() may be waiting for log space,
            // and decrementing log.outstanding has decreased
            // the amount of reserved space.
            execution.scheduler.wakeup(&log);
        }
    }
    if (do_commit) {
        // call commit w/o holding locks, since not allowed
        // to sleep with locks.
        commit();
        log.lock.acquire();
        defer log.lock.release();
        log.is_commiting = false;
        execution.scheduler.wakeup(&log);
    }
}

// Copy modified blocks from cache to log.
fn writeLog() void {
    for (0..log.header.length) |tail| {
        const buffer_destination = Buffer.read(log.device, @intCast(log.start + tail + 1)); // log block
        defer buffer_destination.release();

        const buffer_source = Buffer.read(log.device, log.header.block[tail]); // cache block
        defer buffer_source.release();

        @memmove(&buffer_destination.data, &buffer_source.data);

        buffer_destination.write(); // write the log
    }
}

fn commit() void {
    if (log.header.length > 0) {
        writeLog();// Write modified blocks from cache to log
        writeHead();// Write header to disk -- the real commit
        installTransaction(false); // Now install writes to home locations
        log.header.length = 0;
        writeHead();// Erase the transaction from the log
    }

}

// Caller has modified b->data and is done with the buffer.
// Record the block number and pin in the cache by increasing refcnt.
// commit()/write_log() will do the disk write.
//
// log_write() replaces bwrite(); a typical use is:
//   bp = bread(...)
//   modify bp->data[]
//   log_write(bp)
//   brelse(bp)
pub fn write(buffer: *Buffer) void {
    log.lock.acquire();
    defer log.lock.release();

    if (log.header.length >= common.param.log_size or log.header.length >= log.size - 1) @panic("too big a transaction");
    if (log.outstanding < 1) @panic("log_write outside of trans");

    var index: usize = 0;
    while (index < log.header.length) : (index += 1) {
        if (log.header.block[index] == buffer.block_number) {
            break;// log absorption
        }
    }
    log.header.block[index] = buffer.block_number;
    if (index == log.header.length) {// Add new block to log?
        buffer.pin();
        log.header.length += 1;
    }
}
