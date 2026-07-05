const kernel = @import("root");

const console = @import("console.zig");

const execution = kernel.execution;
const log = kernel.logging;
const memlayout = kernel.memory.layout;
const conc = kernel.concurrency;

/// the UART control registers.
/// some have different meanings for
/// read vs write.
/// see http://byterunner.com/16550.html

// set baud rate to 38.4K
const baud_divisor = 0x0003;

pub fn init() void {
    interrupt_enable_register.disableInterrupts();

    line_control_register.startEditBaudRate();
    line_control_register.setBaudRate(baud_divisor);

    // set word length to 8 bits, no parity.
    line_control_register.endEditBaudRate(.eight_bits_no_parity);

    // reset and enable FIFOs.
    fifo_control_register.resetAndEnable();

    interrupt_enable_register.enableInterrupts();
}

// add a character to the output buffer and tell the
// UART to start sending if it isn't already.
// blocks if the output buffer is full.
// because it may block, it can't be called
// from interrupts; it's only suitable for use
// by write().
pub fn putCharacter(char: u8) void {
    transmit.lock.acquire();
    defer transmit.lock.release();

    if (log.panicked.*) while (true) {};

    while (transmit.isFull()) {
        // buffer is full.
        // wait for uartstart() to open up space in the buffer.
        transmit.sleep();
    }
    transmit.transmitChar(char);
    start();
}

// alternate version of putc() that doesn't
// use interrupts, for use by kernel printf() and
// to echo characters. it spins waiting for the uart's
// output register to be empty.
pub fn putCharSync(ch: u8) void {
    conc.interrupts.pushOff();
    defer conc.interrupts.popOff();

    if (log.panicked.*) while (true) {};

    // wait for Transmit Holding Empty to be set in LSR.
    while (!line_status_register.isTransmitReady()) {}
    holding_register.write(ch);
}

/// if the UART is idle, and a character is waiting
/// in the transmit buffer, send it.
/// caller must hold uart_tx_lock.
/// called from both the top- and bottom-half.
pub fn start() void {
    while (true) {
        // transmit buffer is empty.
        if (transmit.isEmpty()) return;

        // the UART transmit holding register is full,
        // so we cannot give it another byte.
        // it will interrupt when it's ready for a new byte.
        if (!line_status_register.isTransmitReady()) return;

        const character = transmit.readChar();
        holding_register.write(character);
    }
}

/// read one input character from the UART.
/// return NotReady if none is waiting.
pub fn getCharacter() !u8 {
    return if (line_status_register.isReceiveReady()) holding_register.read() else error.NotReady;
}

/// handle a uart interrupt, raised because input has
/// arrived, or the uart is ready for more output, or
/// both. called from devintr().
pub fn interrupt() void {
    // read and process incoming characters.
    while (true) {
        const character = getCharacter() catch break;
        console.interrupt(character);
    }

    // send buffered characters.
    transmit.lock.acquire();
    defer transmit.lock.release();

    start();
}

const transmit = struct {
    const buffer_size = 32;

    var lock: conc.Mutex = .init(.spin, "uart transmit lock");
    var buffer: [buffer_size]u8 = [_]u8{0} ** buffer_size;
    var write_count: u64 = 0;
    var read_count: u64 = 0;

    pub fn isFull() bool {
        return write_count == (read_count + buffer_size);
    }

    pub fn isEmpty() bool {
        return write_count == read_count;
    }

    pub fn sleep() void {
        lock.sleepOn(&read_count);
    }

    pub fn transmitChar(char: u8) void {
        buffer[write_count % buffer_size] = char;
        write_count += 1;
    }

    pub fn readChar() u8 {
        const character = buffer[read_count % buffer_size];
        read_count += 1;

        // maybe uartputc() is waiting for space in the buffer.
        execution.scheduler.wakeup(&read_count);
        return character;
    }
};

// for transfering bytes
// read goes to receive
// write goes to transmit
const holding_register = Register{ .offset = 0, .kind = .readwrite };

const interrupt_enable_register = struct {
    const register = Register{ .offset = 1, .kind = .write };
    const enable_receive = 1 << 0;
    const enable_transmit = 1 << 1;

    pub fn disableInterrupts() void {
        register.write(0);
    }

    // enable transmit and receive interrupts.
    pub fn enableInterrupts() void {
        register.write(enable_receive | enable_transmit);
    }
};

const fifo_control_register = struct {
    const enable_flag = 1 << 0;
    const clear_flag = 3 << 1; // clear the content of the two FIFOs
    const register = Register{ .offset = 2, .kind = .write };

    pub fn resetAndEnable() void {
        register.write(enable_flag | clear_flag);
    }
};

const line_control_register = struct {
    const BitMode = enum(u8) {
        eight_bits_no_parity = 3 << 0,
    };
    const baud_latch = 1 << 7; // special mode to set baud rate

    const register = Register{ .offset = 3, .kind = .write };
    const lsb_register = Register{ .offset = 0, .kind = .write };
    const msb_register = Register{ .offset = 1, .kind = .write };

    pub fn startEditBaudRate() void {
        // start to negotiate baud rate
        register.write(baud_latch);
    }

    pub fn setBaudRate(baud_div: u16) void {
        const lsb: u8 = @truncate(baud_div);
        const msb: u8 = @truncate(baud_div >> 8);
        lsb_register.write(lsb);
        msb_register.write(msb);
    }

    pub fn endEditBaudRate(bit_mode: BitMode) void {
        register.write(@intFromEnum(bit_mode));
    }
};

const line_status_register = struct {
    const line_status_receive_ready = 1 << 0; // input is waiting to be read from RHR
    const line_status_transmit_idle = 1 << 5; // THR can accept another character to send
    const register = Register{ .offset = 5, .kind = .read };

    pub fn isReceiveReady() bool {
        return (register.read() & line_status_receive_ready) != 0;
    }

    pub fn isTransmitReady() bool {
        return (register.read() & line_status_transmit_idle) != 0;
    }
};

const Register = struct {
    const RegisterKind = enum {
        read,
        write,
        readwrite,
    };
    offset: usize,
    kind: RegisterKind,

    fn getPtr(self: Register) *volatile u8 {
        return memlayout.uart0_base_address.add(self.offset).asPtr(*volatile u8);
    }

    pub fn read(self: Register) u8 {
        if (self.kind == .write) @panic("can't read for write only register uart");
        return self.getPtr().*;
    }

    pub fn write(self: Register, value: u8) void {
        if (self.kind == .read) @panic("can't write for read only register uart");
        self.getPtr().* = value;
    }
};

