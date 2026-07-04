const kernel = @import("root");
const std = @import("std");
const common = @import("common");

const log = @import("klog.zig");

const mem = kernel.memory;
const UserAddress = mem.address.UserAddress;
const Process = kernel.execution.Process;
const param = common.param;
const fs = kernel.filesystem;
const File = fs.File;

const InputRegister = enum { a0, a1, a2, a3, a4, a5 };
pub const errorVal = ~@as(u64, 0);

pub fn getInt(register: InputRegister) u64 {
    const process = Process.getCurrentForce();
    const result = switch (register) {
        .a0 => process.trapFrame.a0,
        .a1 => process.trapFrame.a1,
        .a2 => process.trapFrame.a2,
        .a3 => process.trapFrame.a3,
        .a4 => process.trapFrame.a4,
        .a5 => process.trapFrame.a5,
    };
    return result;
}

const AddressNullErr = error{IsNull};

// Retrieve an argument as a pointer.
// Doesn't check for legality, since
// copyin/copyout will do that.
pub fn getAddress(register: InputRegister) ?UserAddress {
    const int = getInt(register);
    if (int == 0) return null;
    return .fromInt(int);
}

// Fetch the nth word-sized system call argument as a null-terminated string.
// Copies into buf, at most max.
// Returns string length if OK (including nul), -1 if error.
pub fn getString(register: InputRegister, buffer: []u8) !usize {
    const address = getAddress(register);
    if (address) |a| {
        return try getStringFromAddress(a, buffer);
    }
    return AddressNullErr.IsNull;
}

const GetFileErrors = error{ OutOfRange, NotCreated };

pub fn getFile(register: InputRegister) GetFileErrors!*File {
    var file: *File = undefined;
    _ = try getFileAndDescriptor(register, &file);
    return file;
}

// Fetch the nth word-sized system call argument as a file descriptor
// and return both the descriptor and the corresponding struct file.
pub fn getFileAndDescriptor(register: InputRegister, fileDestination: ?**File) GetFileErrors!usize {
    const fd = getInt(register);
    if (fd >= param.NOFILE) {
        return GetFileErrors.OutOfRange;
    }

    const process = Process.getCurrentForce();
    const file = process.openFiles[fd] orelse {
        return GetFileErrors.NotCreated;
    };

    if (fileDestination) |dest| {
        dest.* = file;
    }

    return fd;
}

const FileDescriptorAllocateErrors = error{OutOfSpace};

// Allocate a file descriptor for the given file.
// Takes over file reference from caller on success.
pub fn fileDescriptorAllocate(file: *File) FileDescriptorAllocateErrors!usize {
    const process = Process.getCurrentForce();

    var fd: usize = 0;
    while (fd < param.NOFILE) : (fd += 1) {
        if (process.openFiles[fd] == null) {
            process.openFiles[fd] = file;
            return fd;
        }
    }
    return FileDescriptorAllocateErrors.OutOfSpace;
}

const FetchAddressErrors = error{ AddressOutOfBounds, FailedCopyInToKernel };

// Fetch the pointer at addr from the current process.
pub fn fetchAddr(address: UserAddress, destination: *UserAddress) FetchAddressErrors!void {
    const process = Process.getCurrentForce();

    // double comparison in case of overflow
    if (address.toInt() >= process.size or address.toInt() + @sizeOf(*anyopaque) > process.size) {
        return FetchAddressErrors.AddressOutOfBounds;
    }

    mem.boundry.copyIn(process.pageTable, std.mem.asBytes(&destination.value), address) catch return FetchAddressErrors.FailedCopyInToKernel;
}

// Fetch the nul-terminated string at addr from the current process.
// Returns length of string, not including nul
// may not include null terminator
pub fn getStringFromAddress(address: UserAddress, buffer: []u8) !usize {
    const process = Process.getCurrentForce();
    return mem.boundry.copyInString(process.pageTable, buffer, address);
}
