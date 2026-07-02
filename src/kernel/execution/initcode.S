# Initial process that execs /init.
# This code runs in user space.

.equ SYS_exec, 7
.equ SYS_exit, 2

.globl start
# exec
start:
        la a0, init
        la a1, argv
        li a7, SYS_exec
        ecall

# for(;;) exit();
exit:
        li a7, SYS_exit
        ecall
        jal exit

# char init[] = "/init\0";
init:
  .string "/init\0"

# char *argv[] = { init, 0 };
.p2align 3
argv:
  .quad init
  .quad 0
