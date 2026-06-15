//
// Console input and output, to the uart.
// Reads are line at a time.
// Implements special input characters:
//   newline -- end of line
//   control-h -- backspace
//   control-u -- kill line
//   control-d -- end of file
//   control-p -- print process list
//

const std = @import("std");
const CSpinlock = @import("spinlock.zig").CSpinlock;
const uart = @import("uart.zig");

const c = @cImport({
    @cInclude("kernel/types.h");
    @cInclude("kernel/param.h");
    @cInclude("kernel/spinlock.h");
    @cInclude("kernel/sleeplock.h");
    @cInclude("kernel/fs.h");
    @cInclude("kernel/file.h");
    @cInclude("kernel/memlayout.h");
    @cInclude("kernel/riscv.h");
    @cInclude("kernel/defs.h");
    @cInclude("kernel/proc.h");
});

const console_backspace = 0x100;
const backspace = '\x08';
const delete = '\x7f';

fn control(char: u8) u8 {
    return char - '@';
}

const input_buf_size = 128;
const Console = struct {
    lock: CSpinlock = undefined,

    buffer: [input_buf_size]u8 = undefined,

    // Next buffered byte to return to consoleRead().
    // Advances as user read() consumes input.
    readIndex: usize = 0,

    // End of committed input.
    // Set to editIndex when Enter or Ctrl-D arrives; readers may consume up to this point.
    writeIndex: usize = 0,

    // End of the editable input line.
    // Advances as keyboard input arrives; moves backward on backspace/Ctrl-U.
    editIndex: usize = 0,
};

var console: Console = .{};

pub fn init() void {
    console.lock.init("console lock");

    uart.init();
    
    const consoleDevice = &c.devsw[c.CONSOLE];
    consoleDevice.read = &consoleRead;
    consoleDevice.write = &consoleWrite;
}

//
// user write()s to the console go here.
//
fn consoleWrite(user_src: c_int, src: c.uint64, n: c_int) callconv(.c) c_int {
    var i: c.uint64 = 0;

    while (i < n) : (i += 1) {
        var char: u8 = undefined;
        const res = c.either_copyin(&char, user_src, src + i, 1);

        if (res == -1) {
            break;
        }

        uart.putCharacter(char);
    }

    return @intCast(i);
}

//
// user read()s from the console go here.
// copy (up to) a whole input line to dst.
// user_dist indicates whether dst is a user
// or kernel address.
//
fn consoleRead(userDestination: c_int, start: c.uint64, n: c_int) callconv(.c) c_int {
    const target = n;
    var character: u8 = undefined;
    var characterBuffer: u8 = undefined;
    var destination = start;
    var charsLeft = n;

    console.lock.acquireLock();
    defer console.lock.releaseLock();

    while (charsLeft > 0) {
        // wait until interrupt handler has put some
        // input into cons.buffer.
        while (console.readIndex == console.writeIndex) {
            if (c.killed(c.myproc()) != 0) {
                return -1;
            }
            c.sleep(&console.readIndex, @ptrCast(&console.lock.lock));
        }

        character = console.buffer[console.readIndex % input_buf_size];
        console.readIndex += 1;

        if (character == control('D')) { // end of file
            if (charsLeft < target) {
                console.readIndex -= 1;
                // Save ^D for next time, to make sure
                // caller gets a 0-byte result.
            }
            break;
        }
        // copy the input byte to the user-space buffer.
        characterBuffer = character;
        const result = c.either_copyout(userDestination, destination, &characterBuffer, 1);
        if (result == -1) {
            break;
        }

        destination += 1;
        charsLeft -= 1;

        if (character == '\n') {
            // a whole line has arrived, return to
            // the user-level read().
            break;
        }
    }

    return target - charsLeft;
}

//
// the console input interrupt handler.
// uartintr() calls this for input character.
// do erase/kill processing, append to cons.buf,
// wake up consoleread() if a whole line has arrived.
//
//

pub fn consoleInterrupt(character: u8) void {
    console.lock.acquireLock();
    defer console.lock.releaseLock();

    switch (character) {
        control('P') => { // print process list
            c.procdump();
        },
        control('U') => { // kill line
            while (console.editIndex != console.writeIndex) {
                // go until newline
                if (console.buffer[(console.editIndex - 1) % input_buf_size] == '\n') {
                    break;
                }
                console.editIndex -= 1;
                putCharacter(console_backspace);
            }
        },
        delete, control('H') => {
            if (console.editIndex == console.writeIndex) {
                return;
            }
            console.editIndex -= 1;
            putCharacter(console_backspace);
        },
        else => {
            if (character == 0) {
                return;
            }
            if ((console.editIndex - console.readIndex) >= input_buf_size) {
                return;
            }
            // make '\r' into '\n'
            const converted_character = if (character == '\r') '\n' else character;
            putCharacter(converted_character);

            // store for consumption by consoleread().
            console.buffer[console.editIndex % input_buf_size] = converted_character;
            console.editIndex += 1;

            if (converted_character == '\n' or converted_character == control('D')) {
                // wake up consoleread() if a whole line (or end-of-file)
                // has arrived.
                console.writeIndex = console.editIndex;
                c.wakeup(&console.readIndex);
            }
        },
    }
}

//
// send one character to the uart.
// called by printf(), and to echo input characters,
// but not from write().
//
pub fn putCharacter(char: u9) void {
    // if the user typed backspace, overwrite with a space.
    if (char == console_backspace) {
        uart.putCharSync(backspace);
        uart.putCharSync(' ');
        uart.putCharSync(backspace);
    } else {
        uart.putCharSync(@intCast(char));
    }
}

export fn consputc(char: c_int) void {
    putCharacter(@intCast(char));
}
