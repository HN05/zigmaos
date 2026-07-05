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
const receive_holding_register = 0; // receive holding register (for input bytes)
const transmit_holding_register = 0; // transmit holding register (for output bytes)
const interrupt_enable_register = 1; // interrupt enable register
const interrupt_enable_receive = 1 << 0;
const interrupt_enable_transmit = 1 << 1;
const fifo_control_register = 2; // FIFO control register
const fifo_enable = 1 << 0;
const fifo_clear = 3 << 1; // clear the content of the two FIFOs
const interrupt_status_register = 2; // interrupt status register
const line_control_register = 3; // line control register
const line_control_eight_bits = 3 << 0;
const line_control_baud_latch = 1 << 7; // special mode to set baud rate
const line_status_register = 5; // line status register
const line_status_receive_ready = 1 << 0; // input is waiting to be read from RHR
const line_status_transmit_idle = 1 << 5; // THR can accept another character to send

const Transmit = struct {
    const buffer_size = 32;

    lock: conc.Mutex = .init(.spin, "uart transmit lock"),
    buffer: [buffer_size]u8 = [_]u8{0} ** buffer_size,
    write_count: u64 = 0, // write next to uart_tx_buf[uart_tx_w % UART_TX_BUF_SIZE]
    read_count: u64 = 0, // read next from uart_tx_buf[uart_tx_r % UART_TX_BUF_SIZE]

    pub fn isFull(self: *Transmit) bool {
        return self.write_count == (self.read_count + buffer_size);
    }

    pub fn isEmpty(self: *Transmit) bool {
        return self.write_count == self.read_count;
    }

    pub fn sleep(self: *Transmit) void {
        self.lock.sleepOn(&self.read_count);
    }

    pub fn transmitChar(self: *Transmit, char: u8) void {
        self.buffer[self.write_count % buffer_size] = char;
        self.write_count += 1;
    }

    pub fn readChar(self: *Transmit) u8 {
        const character = self.buffer[self.read_count % buffer_size];
        self.read_count += 1;

        // maybe uartputc() is waiting for space in the buffer.
        execution.scheduler.wakeup(&self.read_count);
        return character;
    }
};
var transmit = Transmit{};

pub fn init() void {
    // disable interrupts.
    writeReg(interrupt_enable_register, 0x00);

    // special mode to set baud rate.
    writeReg(line_control_register, line_control_baud_latch);

    // LSB for baud rate of 38.4K.
    writeReg(0, 0x03);

    // MSB for baud rate of 38.4K.
    writeReg(1, 0x00);

    // leave set-baud mode,
    // and set word length to 8 bits, no parity.
    writeReg(line_control_register, line_control_eight_bits);

    // reset and enable FIFOs.
    writeReg(fifo_control_register, fifo_enable | fifo_clear);

    // enable transmit and receive interrupts.
    writeReg(interrupt_enable_register, interrupt_enable_receive | interrupt_enable_transmit);
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
    while ((readReg(line_status_register) & line_status_transmit_idle) == 0) {}
    writeReg(transmit_holding_register, ch);
}

/// if the UART is idle, and a character is waiting
/// in the transmit buffer, send it.
/// caller must hold uart_tx_lock.
/// called from both the top- and bottom-half.
pub fn start() void {
    while (true) {
        if (transmit.isEmpty()) {
            // transmit buffer is empty.
            return;
        }

        if ((readReg(line_status_register) & line_status_transmit_idle) == 0) {
            // the UART transmit holding register is full,
            // so we cannot give it another byte.
            // it will interrupt when it's ready for a new byte.
            return;
        }

        const character = transmit.readChar();

        writeReg(transmit_holding_register, character);
    }
}

/// read one input character from the UART.
/// return NotReady if none is waiting.
pub fn getCharacter() !u8 {
    if ((readReg(line_status_register) & line_status_receive_ready) != 0) {
        // input data is ready.
        return readReg(receive_holding_register);
    } else {
        return error.NotReady;
    }
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

fn getRegPtr(register_offset: usize) *volatile u8 {
    return memlayout.uart0_base_address.add(register_offset).asPtr(*volatile u8);
}

fn readReg(register_offset: usize) u8 {
    return getRegPtr(register_offset).*;
}

fn writeReg(register_offset: usize, value: u8) void {
    getRegPtr(register_offset).* = value;
}
