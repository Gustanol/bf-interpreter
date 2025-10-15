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
    tape_index_code: .quad 0
    current_cell: .quad 0
    cell_mmap_size: .quad 4096 # it will be necessary to call `munmap`

# instructions section
.section .text
    .globl _start

# section used to declare a memory segment to a uninitialized static data
.section .bss
    stat_buf: .space 144 # reserve 144 bytes
    buf_char: .space 1

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
    call create_cell_mmap # call label to create a mmap to store all cells of the program
    call interpret_loop # call label to interpret the code stored
    call end_program # call label to end the program execution

load_file:
    movq $2, %rax # sys_open
    movq $filename, %rdi # loads the memory address of `filename` into rdi
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

    leaq stat_buf(%rip), %rax
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
    # MAP_ANONYMOUS = 0x20: not a file, just memory (malloc)

    movq %r12, %r8 # define file descriptor that will be passed in mmap
    xor %r9, %r9 # offset = 0
    syscall

    testq %rax, %rax
    js error

    movq %rax, %r14 # %r14 = mapped code address

    movq $3, %rax # sys_close
    movq %r12, %rdi # file descriptor that will be closed
    syscall
    ret

create_cell_mmap:
    movq $9, %rax # sys_mmap
    xor %rdi, %rdi # kernel chooses address
    movq $cell_mmap_size, %rsi # mmap size
    movq $1, %rdx # read protection
    movq $0x20, %r10 # MAP_ANONYMOUS: not associate to a file
    movq $-1, %r2 # no file descriptor
    xor %r9, %r9 # offset = 0
    syscall

    testq %rax, %rax
    js error

    movq %rax, %r2 # %r2 = mapped cells address
    ret

interpret_loop:
    movq tape_index_code(%rip), %r15 # loads the current code index into %r15 register
    leaq %r14(%rip), %rdx # gets the base address value of the code storage mmap
    movzbl (%rdx, %r15, 1), %rax # copies the sum between %rdx and %r15 (current symbol) into %rax

    leaq jmp_table(%rip), %rbp # gets the base value of the jmp_table (to call labels)
    movq (%rbp, %rax, 8), %rbp # gets the symbol handle label stored in jmp_table
    incq %r15 # increases %r15

    leaq %r2(%rip), %rdx # loads the base address of the cells mmap
    call calculate_cell_index # call a label to calculate the current cell
    movq (%rax, %rdx, 1), %rax # sums (offset + index = current cell)

    call *%rbp # call label (indirect register)

    movq %r15, tape_index_code(%rip)

    incq %r15
    cmpq %r13, %r15 # verifies if the the file limit was reached
    jl interpret_loop # if lower, call interpret_loop to make a loop
    ret

# operations labels
cmd_plus:
    incq (%rax) # increases the value stored in %rax address
    ret

cmd_minus:
    decq (%rax) # decreases the value stored in %rax address
    ret

cmd_dot:
    movq %rax, %rsi # pointer to character
    movq $1, %rax # sys_write
    movq $1, %rdi # file descriptor: stdout
    movq $1, %rdx # it will always have 1 byte
    syscall
    ret

calculate_cell_index:
    movq $2, %rax
    movq $cell_mmap_size, %rbx # loads the stored cell mmap size
    divq %rbx # %rbx / %rax (middle of the mmap)

    movq current_cell(%rip), %rcx # loads the current cell index
    movq (%rax, %rcx, 1), %rax # sums it to the %rax
    ret

# end program labels
clean_mmaps:
    movq $11, %rax # sys_munmap
    movq %r14, %rdi # mmap address
    movq %r13, %rsi # mmap size
    syscall
    
    movq $11, %rax
    movq %r2, %rdi
    movq $cell_mmap_size, %rsi
    syscall
    ret

error:
    call clean_mmaps
    movq $60, %rax # sys_exit
    movq $1, %rdi # exit code (fail)
    syscall

end_program:
    call clean_mmaps
    movq $60, %rax # sys_exit
    movq $0,  %rdi # exit code (successful)
    syscall
