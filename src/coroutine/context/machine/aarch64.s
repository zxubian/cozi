.global _machine_context_init
.global _machine_context_switch_to

_machine_context_init:
    # X0 is stack bottom
    # X1 is ptr to trampoline function
    # X2 is ptr to trampoline impl (ptr to "self"/"this", to be passed to trampoline function when calling)

    # switch to provided stack
    mov x3, sp
    mov sp, x0

    # leave some space at the bottom, just in case
    sub sp, sp, #64

    # switch_to will try to load callee-saved registers from
    # the stack. So, we push empty data.

    # special registers

    # pass the ptr to trampoline as the 9th argument
    str x2, [sp, #16]!

    # special registers
    # during switch, we want the following:
    # lp -> ptr to trampoline function (x1)
    # fp -> 0
    str x1, [sp, #-16]!

    # general purpose registers
    mov x9, #0
    stp x9, x9, [sp, #-16]!
    stp x9, x9, [sp, #-16]!
    stp x9, x9, [sp, #-16]!
    stp x9, x9, [sp, #-16]!
    stp x9, x9, [sp, #-16]!

    # floating point registers
    fmov d7, #0
    stp d7, d7, [sp, #-16]!
    stp d7, d7, [sp, #-16]!
    stp d7, d7, [sp, #-16]!
    stp d7, d7, [sp, #-16]!
    stp d7, d7, [sp, #-16]!
    stp d7, d7, [sp, #-16]!
    stp d7, d7, [sp, #-16]!
    stp d7, d7, [sp, #-16]!
    stp d7, d7, [sp, #-16]!
    stp d7, d7, [sp, #-16]!
    stp d7, d7, [sp, #-16]!
    stp d7, d7, [sp, #-16]!

    # prepare to return new stack
    mov x0, sp

    # move back to original stack
    mov sp, x3

    ret

_machine_context_switch_to:
    # X0 is stack pointer for self context
    # X1 is stack pointer for other context

    # 1. save current state to current context stack

    # return address & frame pointer
    stp lr, fp, [sp, #-16]!

    # general purpose registers
    stp x28, x27, [sp, #-16]!
    stp x26, x25, [sp, #-16]!
    stp x24, x23, [sp, #-16]!
    stp x22, x21, [sp, #-16]!
    stp x20, x19, [sp, #-16]!

    # floating point registers:
    stp d31, d30, [sp, #-16]!
    stp d29, d28, [sp, #-16]!
    stp d27, d26, [sp, #-16]!
    stp d25, d24, [sp, #-16]!
    stp d23, d22, [sp, #-16]!
    stp d21, d20, [sp, #-16]!
    stp d19, d18, [sp, #-16]!
    stp d17, d16, [sp, #-16]!
    stp d15, d14, [sp, #-16]!
    stp d13, d12, [sp, #-16]!
    stp d11, d10, [sp, #-16]!
    stp d9, d8, [sp, #-16]!

    # save current stack to self.rsp
    mov x2, sp
    str x2, [x0]

    # switch to new stack
    ldr x2, [x1]
    mov sp, x2

    # 2. restore other state

    # floating point registers
    stp d9, d8, [sp], #16
    stp d11, d10, [sp], #16
    stp d13, d12, [sp], #16
    stp d15, d14, [sp], #16
    stp d17, d16, [sp], #16
    stp d19, d18, [sp], #16
    stp d21, d20, [sp], #16
    stp d23, d22, [sp], #16
    stp d25, d24, [sp], #16
    stp d27, d26, [sp], #16
    stp d29, d28, [sp], #16
    stp d31, d30, [sp], #16

    # general purpose registers
    ldp x20, x19, [sp], #16
    ldp x22, x21, [sp], #16
    ldp x24, x23, [sp], #16
    ldp x26, x25, [sp], #16
    ldp x28, x27, [sp], #16

    # special registers
    ldp lr, fp,  [sp], #16

    ret
