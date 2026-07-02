const common = @import("common");

const ad = @import("address.zig");

const riscv = common.riscv;
const param = common.param;

pub const kernel_stack_page_count = param.kernel_stack_page_count;

// qemu -machine virt is set up like this,
// based on qemu's hw/riscv/virt.c:

// 00001000 -- boot ROM, provided by qemu
// 02000000 -- CLINT
// 0C000000 -- PLIC
// 10000000 -- uart0
// 10001000 -- virtio disk
// 80000000 -- boot ROM jumps here in machine mode
//             -kernel loads the kernel here
// unused RAM after 80000000.

// the kernel uses physical memory thus:
// 80000000 -- entry.S, then kernel text and data
// end -- start of kernel page allocation area
// PHYSTOP -- end RAM used by the kernel

// qemu puts UART registers here in physical memory.
pub const uart0_base_address = ad.KernelAddress.fromInt(0x1000_0000);
pub const uart0_irq = 10;

// virtio mmio interface
pub const virtio0_base_address = ad.KernelAddress.fromInt(0x1000_1000);
pub const virtio0_irq = 1;

// core local interruptor (CLINT), which contains the timer.
pub const clint_base_address = ad.KernelAddress.fromInt(0x2000000);
pub inline fn clint_mtimecmp(hartid: usize) *usize {
    return clint_base_address.add(0x4000 + 8 * hartid).asPtr(*usize);
}
// cycles since boot.
pub const clint_mtime: *usize = clint_base_address.add(0xBFF8).asPtr(*usize);

// qemu puts platform-level interrupt controller (PLIC) here.
pub const plic = struct {
    pub const base_address = ad.KernelAddress.fromInt(0x0c00_0000);
    pub const size = 0x40_0000;

    pub inline fn priorityRegister(irq: usize) *volatile u32 {
        return base_address.add(irq * @sizeOf(u32)).asPtr(*volatile u32);
    }

    pub const pending = base_address.add(0x1000);

    pub inline fn machineEnableRegister(hartId: usize) *volatile u32 {
        return base_address.add(0x2000 + hartId * 0x100).asPtr(*volatile u32);
    }

    pub inline fn supervisorEnableRegister(hartId: usize) *volatile u32 {
        return base_address.add(0x2080 + hartId * 0x100).asPtr(*volatile u32);
    }

    pub inline fn machinePriorityThresholdRegister(hartId: usize) *volatile u32 {
        return base_address.add(0x200000 + hartId * 0x2000).asPtr(*volatile u32);
    }

    pub inline fn supervisorPriorityThresholdRegister(hartId: usize) *volatile u32 {
        return base_address.add(0x201000 + hartId * 0x2000).asPtr(*volatile u32);
    }

    pub inline fn machineClaimCompleteRegister(hartId: usize) *volatile u32 {
        return base_address.add(0x200004 + hartId * 0x2000).asPtr(*volatile u32);
    }

    pub inline fn supervisorClaimCompleteRegister(hartId: usize) *volatile u32 {
        return base_address.add(0x201004 + hartId * 0x2000).asPtr(*volatile u32);
    }
};

// the kernel expects there to be RAM
// for use by the kernel and user pages
// from physical address 0x80000000 to PHYSTOP.
pub const kernel_base_address = ad.KernelAddress.fromInt(0x80000000);
pub const physical_stop_address = kernel_base_address.add(128 * 1024 * 1024);

// map the trampoline page to the highest address,
// in both user and kernel space.
pub const trampoline_virtual_int = riscv.max_virtual_address - riscv.page_size;
pub const trampoline_virtual_address = ad.UserAddress.fromInt(trampoline_virtual_int);

extern const trampoline: anyopaque;
pub fn trampolinePhysicalAddress() ad.KernelAddress {
    return .fromPtr(&trampoline);
}

// map kernel stacks beneath the trampoline,
// each surrounded by invalid guard pages.
pub inline fn KSTACK(processId: usize) ad.UserAddress {
    return .fromInt(trampoline_virtual_int - (processId + 1) * (kernel_stack_page_count + 1) * riscv.page_size);
}

// User memory layout.
// Address zero first:
//   text
//   original data and bss
//   fixed-size stack
//   expandable heap
//   ...
//   TRAPFRAME (p->trapframe, used by the trampoline)
//   TRAMPOLINE (the same page as in the kernel)
pub const trapframe_virtual_address = trampoline_virtual_address.sub(riscv.page_size);

extern const etext: anyopaque; // kernel.ld sets this to end of kernel code.

pub fn etextAddress() ad.KernelAddress {
    return .fromPtr(&etext);
}

// first address after kernel.
extern const end: anyopaque;
pub fn kernelEndAddress() ad.KernelAddress {
    return .fromPtr(&end);
}
