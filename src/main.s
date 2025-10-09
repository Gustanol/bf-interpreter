.section .data
    # initialize a jump table with 256 spaces pointing to invalid characters
    # quad = 8 bytes
    # therefore, the table will need 2048 bytes of memory (256*8)
    jmp_table:
        .rept 256 # repeat the operation 256 times
            .quad invalid_char
        .endr
    filename:
        .asciz "tests/main.bf" # initialize "filename" variable to store the name of the file it will be open

# instructions section
.section .text
    .global _start

# section used to declare a memory segment to a uninitialized static data
.section .bss
    stat_buf: .space 144 # reserve 144 bytes

_start:
    # in here, it will define the valid entrances of BF in `jmp_table`
    # in each of the following value attribution, we will associate it to a label pointer

    # calculate the effective memory of jmp_table and pass it to %rax
    # the use of %rip register in here is complex and I will explain in the readme.md file of this project
    leaq jmp_table(%rip), %rax
    movq $cmd_plus, 0x2B*8(%rax) # 0x2B (+) * 8 = 0x158 + jmp_table address -> offset representing the character within the table
    movq $cmd_minus, 0x2D*8(%rax) # 0x2D (-)
    movq $cmd_right, 0x3E*8(%rax) # 0x3E (>)
    movq $cmd_left, 0x3C*8(%rax) # 0x3C (<)
    movq $cmd_apos, 0x27*8(%rax) # 0x27 (')
    movq $cmd_dot, 0x2E*8(%rax) # 0x2E (.)
    movq $cmd_osqbr, 0x5B*8(%rax) # 0x5B ([)
    movq $cmd_csqbr, 0x5D*8(%rax) # 0x5D (])

    # we must to do this 'cause memory is stored continuously
    # therefore, to access a value stored within the table, we need to get its value from the address of the table itself

    call load_file # call label to open the file (filename)
    call interpret # call label to interpret the code stored
    call end_program # call label to end the program execution

load_file:
    movq $2, %rax # sys_open
    # leaq filename, %rdi # uses lea (load effective address) to load the memory address of `filename` into rdi
    xor %rsi, %rsi # make rsi null to represents zero flag (read only)
    xor %rdx, %rdx
    syscall # used to call kernel to execute the given syscall

    testq %rax, %rax # AND operation to determine if the file was correct opened

    # JS (jump if sign) jumps to a specific label if the result of an operation (in this case, test) is negative
    # in here, it will jump to the `error` label
    js error
    movq %rax, %r12 # stores file descriptor into `r12` register

    movq $5, %rax # sys_fstat
    movq %r12, %rdi # uses the stored file descriptor
    leaq stat_buf, %rsi # copies `stat_buf` variable pointer into rsi
    syscall
    testq %rax, %rax
    js error

    movq stat_buf(%rip), %rax
    movq 48(%rax), %r13 # r13 will store the file size
    # size is stored at offset 48 of the buffer because of the struct he populates

    # C implementation (not all):
    # struct stat {
    #   dev_t st_dev
    #   ino_t st_ino
    #   // ...
    #   off_t st_size // offset 48
    # }
    
    # mmap maps something into the virtual memory of the program
    # instead of reading a file and copy data into a buffer, mmap will only pointer to a map
    movq $9, %rax # sys_mmap

    # in here, we make a xor operation to make RDI (register destination index) null
    # therefore, the kernel itself will determine the address to allocate the file (in this case)
    # if we would need to allocate at a specific memory address, we could do this by using:
    # mov rdi, <memory_address>
    xor %rdi, %rdi

    # allocates memory to mmap according to file length
    movq %r13, %rsi # stores the file size into %rsi register
    movq $1, %rdx

    # Protection:
    # PROT_READ = 1: read
    # PROT_WRITE = 2: write
    # PROT_EXEC = 4: execute
    # ...

    movq $2, %r10

    # Flags:
    # MAP_SHARED = 1: changes affect the file (shared)
    # MAP_PRIVATE = 2: changes does not affect the file, it's kept only in memory (copy-on-write)
    # MAP_PRIVATE = 0x20: not a file, just memory (malloc)

    movq %r12, %r8 # define file descriptor that will be passed in mmap
    xor %r9, %r9 # offset = 0
    syscall

    testq %rax, %rax
    js error

    movq %rax, %r14 # %r14 = mapped code address

    movq $3, %rax # sys_close
    movq %r12, %rdi # file descriptor that will be closed
    syscall

interpret:

clean_mmap:
    movq $11, %rax # sys_munmap
    movq %r14, %rdi # mmap address
    movq %r13, %rsi # mmap size
    syscall

error:
    movq $60, %rax # sys_exit
    movq $1, %rdi # exit code (fail)
    syscall

end_program:
    call clean_mmap
    movq $60, %rax # sys_exit
    movq $0,  %rdi # exit code (successful)
    syscall
