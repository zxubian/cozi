.global machine_context_init
.global machine_context_switch_to
.global machine_context_trampoline

# extern fn machine_context_init(
#     stack_ceil: ?[*]u8,
#     stack_base: ?[*]u8,
#     machine_context_trampoline: TrampolineProto,
#     trampoline_ctx: *anyopaque,
#     trampoline_run: *anyopaque,
# ) callconv(.C) *anyopaque;
machine_context_init:
    # RCX:        stack_ceil: ?[*]u8 (low address)
    # RDX:        stack_base: u64 (high address)
    # R8:         machine_context_trampoline: &Trampoline.Run
    # R9:         trampoline_ctx: *anyopaque 
    # [rsp+0x20]: trampoline_run: *TrampolineProto

    # Trampoline.runC is the 5th argument to machine_context_init,
    # so it is located at (%rsp + 0x28)
    # put it into temp register
    # movq 0x28(%rsp), %r11

    # callee-saved info
    # save TIB to current stack
    pushq %gs:0x10
    pushq %gs:0x08
    # store frame pointer
    pushq %rbp

    #  --- prolog ---
    # 4 x 64-bit arguments = 32 bytes for args = 0x20
    subq $0x20, %rsp 
    movq %r9, 0x18(%rsp)
    movq %r8, 0x10(%rsp)
    movq %rdx, 0x8(%rsp)
    movq %rcx, (%rsp)
    # --- end prolog ---

    # save current stack to scratch register
    movq %rsp, %r10
    # switch to provided stack
    # rsp <- stack_top
    movq %rdx, %rsp

    # extra space for alignment
    subq $64, %rsp
    # trampoline stack must be 16-byte aligned
    andq $-16, %rsp
    addq $8, %rsp
    # set frame pointer
    movq %rsp, %rbp

    # update TIB
    # https://en.wikipedia.org/wiki/Win32_Thread_Information_Block
    # set low address (Stack Limit / Ceiling of stack)
    movq %rcx, %gs:0x10
    # set high address (Stack Base / Bottom of stack)
    movq %rbp, %gs:0x08

    # --- stack parameter area ---
    # # pass the ptr to Trampoline.runC as the 6th argument
    # pushq %r11
    # pass the ptr to trampoline as the 5th argument
    pushq %r9
    # ----------------------------

    # --- register home area ---
    # zero out scratch register
    xorq %r11, %r11
    pushq %r11 #r9 home
    pushq %r11 #r8 home
    pushq %r11 #rdx home
    pushq %r11 #rcx home
    # --------------------------
    # --- fake return address ---
    pushq %r11
    # --------------------------

    # return address -> trampoline_run
    pushq %r8

    # switch_to will try to load callee-saved registers from the stack. 
    # So, we push empty data.

    # prepare TIB info on new stack
    pushq %gs:0x10
    pushq %gs:0x08

    # store non-volatile registers
    pushq %r11 #rbx
    pushq %rbp #rbp
    pushq %r11 #rdi
    pushq %r11 #rsi
    pushq %r11 #r12
    pushq %r11 #r13
    pushq %r11 #r14
    pushq %r11 #r15

    # put stack pointer into RAX for function return
    # https://learn.microsoft.com/en-us/cpp/build/x64-calling-convention?view=msvc-170#return-values
    movq %rsp, %rax

    # move back to original stack
    movq %r10, %rsp

    #deallocate stack
    addq $0x20, %rsp

    # restore frame pointer
    popq %rbp
    # restore old TIB 
    popq %gs:0x08
    popq %gs:0x10

    retq


# extern fn machine_context_switch_to(
#     old_stack_pointer: **anyopaque,
#     new_stack_pointer: **anyopaque,
# ) callconv(.C) void;
machine_context_switch_to:
    # rcx: stack pointer for self context
    # rdx: stack pointer for other context

    # 1. save current state to current context stack
    # return address is [RSP + 0]

    # store stack base & limit
    # https://en.wkipedia.org/wiki/Win32_Thread_Information_Block
    pushq %gs:0x10
    pushq %gs:0x08
    
    # store non-volatile registers
    pushq %rbx
    pushq %rbp
    pushq %rdi
    pushq %rsi
    pushq %r12
    pushq %r13
    pushq %r14
    pushq %r15

    # save current stack pointer into old_stack_pointer
    # old_stack_pointer.* = rsp
    movq %rsp, (%rcx)

    # switch to new stack
    movq (%rdx), %rsp

    # 2. restore non-volatile registers
    popq %r15
    popq %r14
    popq %r13
    popq %r12
    popq %rsi
    popq %rdi
    popq %rbp
    popq %rbx

    popq %gs:0x08
    popq %gs:0x10

    retq


# extern fn machine_context_trampoline(
#     _: *anyopaque,
#     _: *anyopaque,
#     _: *anyopaque,
#     _: *anyopaque,
#     // passed on the stack
#     machine_ctx_self: *anyopaque,
#     // passed on the stack
#     trampoline_run: *const fn (self: *anyopaque) callconv(.C) noreturn,
# ) callconv(.C) noreturn;
machine_context_trampoline:
    # [rsp + machine_ctx_self: *anyopaque,
    #     trampoline_run: *const fn (self: *anyopaque) callconv(.C) noreturn,
    movq 0x28(%rsp), %rax 
    movq 0x20(%rsp), %rcx
    # allocate space for register homes
    subq $0x20, %rsp
    call *%rax
