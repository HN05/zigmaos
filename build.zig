// Much of this code comes from https://github.com/binarycraft007/xv6-riscv-zig

const std = @import("std");
const mem = std.mem;
const RunStep = std.Build.Step.Run;
const CompileStep = std.Build.Step.Compile;
const InstallFileStep = std.Build.Step.InstallFile;
const MakeFilesystemStep = @import("build/MakeFilesystemStep.zig");
const SyscallGenStep = @import("build/SyscallGenStep.zig");
const QemuRunStep = @import("build/QemuRunStep.zig");

const kernel_src = [_][]const u8{
    "src/kernel/startup/entry.S", // Very first boot instructions.
    "src/kernel/execution/switchcontext.S", // Thread switching.
    "src/kernel/traps/trampoline.S", // Assembly code to switch between user and kernel.
    "src/kernel/traps/kernelvec.S", // Handle traps from kernel, and timer interrupts.
};

const cflags = [_][]const u8{
    "-Wall",
    "-Werror",
    "-Wno-gnu-designator", // workaround for compiler error
    "-fno-omit-frame-pointer",
    "-gdwarf-4",
    "-MD",
    "-ggdb",
    "-ffreestanding",
    "-fno-common",
    "-nostdlib",
    "-mno-relax",
    "-fno-pie",
    "-fno-stack-protector",
    "-Wno-unused-but-set-variable", // workaround for compiler error
    "-g",
};

const ProgType = enum {
    zig,
    c,
};

const Prog = struct {
    type: ProgType,
    name: []const u8,
};

const user_progs = [_]Prog{
    // "src/user/forktest.c", // ToDo: build forktest
    .{ .type = .zig, .name = "rbz" },
    .{ .type = .zig, .name = "rbz_failtest" },
    .{ .type = .zig, .name = "pbz" },
    .{ .type = .c, .name = "rb_basic" },
    .{ .type = .c, .name = "rb_failtest" },
    .{ .type = .c, .name = "rb_spsc_test" },
    .{ .type = .c, .name = "rb_wipe" },
    .{ .type = .c, .name = "rb_open_close" },
    .{ .type = .c, .name = "rb" },
    .{ .type = .c, .name = "pb" },
    .{ .type = .c, .name = "cat" },
    .{ .type = .c, .name = "echo" },
    .{ .type = .c, .name = "grep" },
    .{ .type = .c, .name = "init" },
    .{ .type = .c, .name = "kill" },
    .{ .type = .c, .name = "ln" },
    .{ .type = .c, .name = "ls" },
    .{ .type = .c, .name = "mkdir" },
    .{ .type = .c, .name = "rm" },
    .{ .type = .c, .name = "sh" },
    .{ .type = .c, .name = "stressfs" },
    .{ .type = .c, .name = "usertests" },
    .{ .type = .c, .name = "grind" },
    .{ .type = .c, .name = "wc" },
    .{ .type = .c, .name = "zombie" },
};

const ulib_c_src = [_][]const u8{
    "src/user/ulib/ulib.c",
    "src/user/ulib/printf.c",
    "src/user/ulib/umalloc.c",
};

const ulib_z_src = [_][]const u8{
    "src/user/ulib/ulib.c",
    // "src/user/ulib/printf.c",
    "src/user/ulib/umalloc.c",
};

pub fn build(b: *std.Build) !void {
    const target_query = std.Target.Query{
        .os_tag = .freestanding,
        .cpu_arch = .riscv64,
        .abi = .none,
    };
    const target = b.resolveTargetQuery(target_query);

    const opts = b.addOptions();
    const use_gdb = b.option(bool, "gdb", "Use gdb") orelse false;
    opts.addOption(bool, "gdb", use_gdb);

    const kernel_linker = "build/linker/kernel.ld";
    const user_linker = "build/linker/user.ld";

    const kernel_mod = b.createModule(.{
        .root_source_file = b.path("src/kernel/kernel.zig"),
        .target = target,
        .optimize = .ReleaseSmall,
    });

    kernel_mod.addCSourceFiles(.{ .files = &kernel_src, .flags = &cflags });
    kernel_mod.addIncludePath(b.path("src"));
    kernel_mod.addAnonymousImport("common", .{ .root_source_file = b.path("src/common/mod.zig") });
    kernel_mod.strip = false;
    kernel_mod.single_threaded = true;
    kernel_mod.code_model = .medium;

    const kernel = b.addExecutable(.{ .name = "kernel", .root_module = kernel_mod });
    kernel.setLinkerScript(b.path(kernel_linker));
    kernel.entry = .{ .symbol_name = "_entry" };
    kernel.lto = .none;

    b.installArtifact(kernel);

    const syscall_gen_step = addSyscallGen(b);

    const ulib_mod = b.createModule(.{
        .root_source_file = b.path("src/user/ulib/ulib.zig"),
        .optimize = .ReleaseSafe,
        .target = target,
    });
    ulib_mod.addCSourceFile(.{ .file = syscall_gen_step.getLazyPath(), .flags = &cflags });
    ulib_mod.addIncludePath(b.path("src"));
    ulib_mod.single_threaded = true;
    ulib_mod.addAnonymousImport("common", .{ .root_source_file = b.path("src/common/mod.zig") });

    const ulib = b.addLibrary(.{
        .name = "ulib",
        .root_module = ulib_mod,
    });

    var artifacts: std.ArrayList(*CompileStep) = .empty;
    inline for (user_progs) |prog| {
        const user_prog_mod = blk: {
            if (prog.type == .zig) {
                const src = "src/user/" ++ prog.name ++ ".zig";

                const user_prog_mod = b.createModule(.{
                    .root_source_file = b.path(src),
                    .optimize = .ReleaseSmall,
                    .target = target,
                });

                user_prog_mod.addAnonymousImport("common", .{ .root_source_file = b.path("src/common/mod.zig") });
                user_prog_mod.addCSourceFiles(.{ .files = &ulib_z_src, .flags = &cflags });
                break :blk user_prog_mod;
            } else {
                const src = "src/user/" ++ prog.name ++ ".c";
                const src_files = &[_][]const u8{src} ++ ulib_c_src;

                const user_prog_mod = b.createModule(.{
                    .target = target,
                    .optimize = .ReleaseSmall,
                });

                user_prog_mod.addCSourceFiles(.{ .files = src_files, .flags = &cflags });
                break :blk user_prog_mod;
            }
        };
        user_prog_mod.linkLibrary(ulib);
        user_prog_mod.single_threaded = true;
        user_prog_mod.code_model = .medium;
        user_prog_mod.addIncludePath(b.path("src"));

        const exe_name = if (prog.type == .c) "_" ++ prog.name else prog.name;
        const user_prog = b.addExecutable(.{
            .name = exe_name,
            .root_module = user_prog_mod,
        });

        user_prog.step.dependOn(&ulib.step);
        user_prog.setLinkerScript(b.path(user_linker));
        user_prog.entry = .{ .symbol_name = "_main" };
        // user_prog.root_module.strip = false;
        user_prog.step.dependOn(&syscall_gen_step.step);
        b.installArtifact(user_prog);
        try artifacts.append(b.allocator, user_prog);
    }

    const image = installFilesystem(b, artifacts, "fs.img");
    qemuRun(b, kernel, image, use_gdb);
}

/// Output filesystem image determined by filename
pub fn installFilesystem(
    b: *std.Build,
    artifacts: std.ArrayList(*CompileStep),
    dest_filename: []const u8,
) *MakeFilesystemStep {
    const img = addMakeFilesystem(b, artifacts, dest_filename);
    b.getInstallStep().dependOn(&img.step);
    return img;
}

pub fn addMakeFilesystem(
    b: *std.Build,
    artifacts: std.ArrayList(*CompileStep),
    dest_filename: []const u8,
) *MakeFilesystemStep {
    return MakeFilesystemStep.create(b, artifacts, dest_filename);
}

pub fn addSyscallGen(
    b: *std.Build,
) *SyscallGenStep {
    return SyscallGenStep.create(b);
}

pub fn qemuRun(
    b: *std.Build,
    kernel: *CompileStep,
    image: *MakeFilesystemStep,
    use_gdb: bool,
) void {
    if (!b.enable_qemu) return;

    const run_step = RunStep.create(b, "run xv6 step");
    b.getInstallStep().dependOn(&run_step.step);

    const qemu_run_step = QemuRunStep.create(b, kernel, .{
        .image = image,
        .run_step = run_step,
        .use_gdb = use_gdb,
    });
    b.getInstallStep().dependOn(&qemu_run_step.step);
}
