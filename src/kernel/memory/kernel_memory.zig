const kernel = @import("root");

const ad = @import("address.zig");
const pg = @import("pages.zig");
const alloc = @import("allocation.zig");
const ml = @import("layout.zig");
const csr = @import("../csr.zig");
const vm = @import("virtual_memory.zig");

const execution = kernel.execution;

var kernel_pagetable: pg.PageTablePtr = undefined;

//  TODO: move
inline fn memoryFence() void {
    // the zero, zero means flush all TLB entries.
    asm volatile ("sfence.vma zero, zero");
}

fn kernelVirtualMap(
    virtualAddress: ad.UserAddress,
    physicalAddress: ad.KernelAddress,
    size: usize,
    mapping_kind: vm.MappingKind
) void {
    vm.map(kernel_pagetable, virtualAddress, physicalAddress, size, mapping_kind.permissions(), .kernel) catch @panic("could not kernel virtualmap");
}

fn kernelInitMap(physicalAddress: ad.KernelAddress, size: usize, mapping_kind: vm.MappingKind) void {
    kernelVirtualMap(.fromInt(physicalAddress.toInt()), physicalAddress, size, mapping_kind);
}

// Make a direct-map page table for the kernel.
pub fn initPageTable() void {
    const page = alloc.allocPageForce(.zeroed);
    kernel_pagetable = @ptrCast(page);

    // uart registers
    kernelInitMap(ml.uart0_base_address, pg.page_size, .data);

    // virtio mmio disk interface
    kernelInitMap(ml.virtio0_base_address, pg.page_size, .data);

    // PLIC
    kernelInitMap(ml.plic.base_address, ml.plic.size, .data);

    // map kernel text executable and read-only.
    kernelInitMap(ml.kernel_base_address, ml.etextAddress().offsetFrom(ml.kernel_base_address), .code);

    // map kernel data and the physical RAM we'll make use of.
    kernelInitMap(ml.etextAddress(), ml.physical_stop_address.offsetFrom(ml.etextAddress()), .data);

    // map the trampoline for trap entry/exit to
    // the highest virtual address in the kernel.
    kernelVirtualMap(ml.trampoline_virtual_address, ml.trampolinePhysicalAddress(), pg.page_size, .code);

    // allocate and map a kernel stack for each process.
    execution.Process.mapKernelStacks(&kernelVirtualMap);
}

// Switch h/w page table register to the kernel's page table,
// and enable paging.
pub fn enablePaging() void {
    // wait for any previous writes to the page table memory to finish.
    memoryFence();
    csr.Satp.write(kernel_pagetable);
    // flush stale entries from the TLB.
    memoryFence();
}

