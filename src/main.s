.section .data
    expand_error_message: .ascii "2MB cells amount reached"
    not_valid_symbol_error_message: .ascii "Not valid symbol. Exiting with 1 error."

    # initialize a jump table with 256 spaces pointing to invalid characters
    # quad = 8 bytes
    # therefore, the table will need 2048 bytes of memory (256*8)
    jmp_table:
        .rept 256 # repeat the operation 256 times
            .quad not_valid_symbol_error
        .endr
    
    cell_mmap_size: .quad 4096 # it will be necessary to call `munmap`

    # constants
    .equ MAX_CELL_MMAP_SIZE, 2097152

# instructions section
.section .text
    .globl _start

# section used to declare a memory segment to a uninitialized static data
.section .bss
    stat_buf: .space 144 # reserve 144 bytes
    input_buffer: .byte 0
    filename: .quad 0 # it will store the name of the file it will be open
    
    .align 8
    tape_base_code: .quad 0 # base address of the code mmap
    tape_index_code: .quad 0 # current code mmap index
    current_cell: .quad 0 # current cell index
    cell_mmap_base: .quad 0 # it will store the current address base of the cell mmap
    shift_left_expand: .quad 0 # stores the value of the shift to use in the copy loop

_start:
    movq (%rsp), %rax # gets the stack pointer
    cmpq $2, %rax # compares with two
    jl error # if lower, return an error (where's filename?)
    jg error # if greater, return an error (too much arguments)

    movq 16(%rsp), %rax # gets the first argument - filename (argv[1])
    movq %rax, filename(%rip)

    # in here, it will define the valid entrances of BF in `jmp_table`
    # in each of the following value attribution, we will associate it to a label pointer

    # calculate the effective memory of jmp_table and pass it to %rax
    # the use of %rip register in here is complex and I will explain in the readme.md file of this project
    leaq jmp_table(%rip), %rax
    movq $cmd_plus, 0x2B*8(%rax) # 0x2B (+) * 8 = 0x158 + jmp_table address -> offset representing the character within the table
    movq $cmd_minus, 0x2D*8(%rax) # 0x2D (-)
    movq $cmd_right, 0x3E*8(%rax) # 0x3E (>)
    movq $cmd_left, 0x3C*8(%rax) # 0x3C (<)
    movq $cmd_comma, 0x2C*8(%rax) # 0x2C (,)
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
    leaq filename(%rip), %rdi # loads the memory address of `filename` into rdi
    xorq %rsi, %rsi # make rsi null to represents zero flag (read only)
    xorq %rdx, %rdx
    syscall # used to call kernel to execute the given syscall

    testq %rax, %rax # AND operation to determine if the file was correct opened

    # JS (jump if sign) jumps to a specific label if the result of an operation (in this case, test) is negative
    # in here, it will jump to the `error` label
    js error
    movq %rax, %r12 # stores file descriptor into `r12` register

    movq $5, %rax # sys_fstat
    movq %r12, %rdi # uses the stored file descriptor
    leaq stat_buf(%rip), %rsi # copies `stat_buf` variable pointer into rsi
    syscall

    testq %rax, %rax
    js error

    leaq stat_buf(%rip), %rax
    movq 48(%rax), %r13 # r13 will store the file size
    # size is stored at offset 48 of buffer because of the struct he populates

    # C implementation (not complete):
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
    ## if was needed to allocate at a specific memory address, we could do this by using:
    # mov rdi, <memory_address>
    xorq %rdi, %rdi

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
    xorq %r9, %r9 # offset = 0
    syscall

    testq %rax, %rax
    js error

    movq %rax, tape_base_code(%rip) # mapped code address

    movq $3, %rax # sys_close
    movq %r12, %rdi # file descriptor that will be closed
    syscall
    ret

create_cell_mmap:
    movq $9, %rax # sys_mmap
    xorq %rdi, %rdi # kernel chooses address
    movq cell_mmap_size(%rip), %rsi # mmap size
    movq $1, %rdx # read protection
    movq $0x20, %r10 # MAP_ANONYMOUS: not associated to a file
    movq $-1, %r8 # no file descriptor
    xorq %r9, %r9 # offset = 0
    syscall

    testq %rax, %rax
    js error

    movq %rax, cell_mmap_base(%rip) # mapped cells address
    ret

interpret_loop:
    movq tape_index_code(%rip), %r15 # loads the current code index into %r15 register
    leaq tape_base_code(%rip), %rdx # gets the base address value of the code storage mmap
    movq (%rdx, %r15, 1), %rax # copies the sum between %rdx and %r15 (current symbol) into %ra

    leaq jmp_table(%rip), %rbp # gets the base value of the jmp_table (to call labels)
    movq (%rbp, %rax, 8), %rbp # gets the symbol handle label stored in jmp_table
    incq %r15 # increases %r15

    leaq cell_mmap_base(%rip), %rdx # loads the base address of the cells mmap
    call calculate_cell_index # call a label to calculate the current cell
    addq %rdx, %rax # sums (offset + index = current cell)

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

cmd_right:
    movq current_cell(%rip), %rax # gets the current cell

    cmpq $MAX_CELL_MMAP_SIZE, %rax # compares it to 2MB
    jz expand_error # if equal, jump to a label to handle the error

    cmpq cell_mmap_size(%rip), %rax # compares the current cell with the size of the mmap
    jz expand_right # if they're equal, jump to a label to expand the mmap to right

    incq %rax # increases the current cell
    movq %rax, current_cell(%rip) # update current_cell global variable
    ret

cmd_left:
    movq current_cell(%rip), %rax # current cell index
    cmpq $0, %rax # compares the current cell index with 0

    # in the case it is equal, it means the start limit was reached
    # therefore, it is needed to expand to the left
    jz expand_left

    movq current_cell(%rip), %rax # updated current cell index
    decq %rax # decreases the current cell
    movq %rax, current_cell(%rip) # update the current cell index
    ret

cmd_comma:
    xorq %rax, %rax # sys_read
    xorq %rdi, %rdi # stdin
    leaq input_buffer(%rip), %rsi # buffer
    movq $1, %rdx # 1 byte
    syscall

    movq cell_mmap_base(%rip), %rax # loads the base memory address of the cell mmap
    movq current_cell(%rip), %rdi # loads the current cell
    movb input_buffer(%rip), %dl
    movb %dl, (%rax, %rdi, 1) # saves the read buffer into the current cell value
    ret

calculate_cell_index:
    xorq %rdx, %rdx
    movq cell_mmap_size(%rip), %rax # loads the stored cell mmap size
    movq $2, %rbx
    divq %rbx # RDX:RAX / RBX (middle of the mmap)

    movq current_cell(%rip), %rcx # loads the current cell index
    addq %rcx, %rax # sums it to the %rax
    ret

expand_right:
    xorq %rdx, %rdx # first 64 bits
    movq cell_mmap_size(%rip), %rax # old mmap size (last 64 bits)
    movq $2, %rsi
    divq %rsi # get half of the mmap

    addq cell_mmap_size(%rip), %rax # new mmap size (current size + half size)

    movq %rax, %rsi # new mmap size (copy)
    cmpq $MAX_CELL_MMAP_SIZE, %rsi # verifies if the new size reached 2MB
    jg expand_error # if so, jump to the handle label

    movq $25, %rax # sys_mremap
    leaq cell_mmap_base(%rip), %rdi # old mmap address
    movq %rsi, %rdi # old mmap size
    # %rsi = new size: addq %rax (old size), 'current' %rsi (value to be increased)
    movq $1, %r10 # MREMAP_MAYMOVE: relocate the mapping to a new virtual address, if necessary
    syscall

    testq %rax, %rax
    js error

    movq %rax, cell_mmap_base(%rip)
    movq %rbx, cell_mmap_size(%rip)
    ret

expand_left:
    xorq %rdx, %rdx
    movq cell_mmap_size(%rip), %rax
    movq $2, %rdi
    divq %rdi # RDX:RAX / RDI (half of the mmap)

    movq %rax, shift_left_expand(%rip)
    addq cell_mmap_size(%rip), %rax # size of the new mmap
    movq %rax, %rsi # copy

    cmpq $MAX_CELL_MMAP_SIZE, %rsi # verify if the limit was reached
    jg expand_error # if so, calls the error handler label
    
    movq $9, %rax # sys_mmap
    xorq %rdi, %rdi
    # %rsi = copy of the new mmap size
    movq $3, %rdx # PROT_READ | PROT_WRITE
    movq $0x22, %r10 # MAP_ANONYMOUS
    movq $-1, %r8 # no file descriptor
    xorq %r9, %r9 # offset = 0
    syscall

    testq %rax, %rax
    js error

    movq %rax, %r15 # new mmap base
    movq %rsi, %r14 # new mmap size

    call items_mmap_copy_loop # call label to copy values into the new mmap, in correct offset
 
    movq $11, %rax # sys_munmap
    movq cell_mmap_base(%rip), %rdi
    movq cell_mmap_size(%rip), %rsi
    syscall

    # updates
    movq %r14, cell_mmap_size(%rip)
    movq %r15, cell_mmap_base(%rip)
    movq shift_left_expand(%rip), %rax
    addq %rax, current_cell(%rip)
    ret

items_mmap_copy_loop:
    movq %rax, %r8 # base of the new mmap (not updated yet), coming from "expand_left" label
    movq cell_mmap_base(%rip), %rax # base of the old mmap
    movq shift_left_expand(%rip), %rdi
    
    leaq (%rdi, %r13, 1), %r9 # current index (cell) + offset

    movq current_cell(%rip), %r13
    movq (%rax, %r13, 1), %rax # current index in the old mmap
    movq %rax, (%r8, %r9, 1) # current index in the new mmap
    
    addq $8, %r13
    cmpq %r13, cell_mmap_size(%rip)
    jl items_mmap_copy_loop

    ret

# end program labels
clean_mmaps:
    # code mmap
    movq $11, %rax # sys_munmap
    leaq tape_base_code(%rip), %rdi # mmap address
    movq %r13, %rsi # mmap size
    syscall
    
    # cells mmap
    movq $11, %rax
    leaq cell_mmap_base(%rip), %rdi
    movq cell_mmap_size(%rip), %rsi
    syscall
    ret

error:
    call clean_mmaps
    movq $60, %rax # sys_exit
    movq $1, %rdi # exit code (fail)
    syscall

expand_error:
    call clean_mmaps

    movq $1, %rax # sys_write
    movq $1, %rdi # fd: stdout
    leaq expand_error_message(%rip), %rsi
    movq $40, %rdx # 40 bytes
    syscall

    movq $60, %rax
    movq $1, %rdi
    syscall

not_valid_symbol_error:
    movq $1, %rax #sys_write
    movq $1, %rdi
    leaq not_valid_symbol_error_message(%rip), %rsi
    movq $50, %rdx
    syscall

    jmp error
    ret

end_program:
    call clean_mmaps
    movq $60, %rax # sys_exit
    movq $0,  %rdi # exit code (successful)
    syscall
