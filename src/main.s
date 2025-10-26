.section .data
    expand_error_message: .ascii "2MB cells amount reached"
    not_valid_symbol_error_message: .ascii "Not valid symbol. Exiting with 1 error."
    not_closed_bracket_error_message: .ascii "Not closed bracket. Exiting with 1 error."

    cell_mmap_size: .quad 4096 # it will be necessary to call `munmap`
    tape_index_code: .quad 0 # current code mmap index
    current_cell: .quad 0 # current cell index

    last_closed_square_bracket: .quad 0
    current_loop_depth: .quad 0

    # constants
    .equ MAX_CELL_MMAP_SIZE, 2097152
    newline: .byte 0x0A

# section used to declare a memory segment to a uninitialized static data
.section .bss
    # initialize a jump table with 256 bytes
    # therefore, the table will need 2048 bytes of memory (256*8)
    jmp_table: .space 2048
    stat_buf: .space 144 # reserve 144 bytes
    input_buffer: .byte 0
    filename: .quad 0 # it will store the name of the file it will be open
    code_mmap_size: .quad 0
    
    .align 8
    tape_base_code: .quad 0 # base address of the code mmap
    cell_mmap_base: .quad 0 # it will store the current address base of the cell mmap
    shift_left_expand: .quad 0 # stores the value of the shift to use in the copy loop

# instructions section
.section .text
.globl _start

_start:
    movq (%rsp), %rax # gets the stack pointer
    cmpq $2, %rax # compares with two
    jl .error # if lower, return an error (where's filename?)
    jg .error # if greater, return an error (too much arguments)

    movq 16(%rsp), %rax # gets the first argument - filename (argv[1])
    movq %rax, filename(%rip)

    # in here, it will define the valid entrances of BF in `jmp_table`
    # in each of the following value attribution, we will associate it to a label pointer

    # calculate the effective memory of jmp_table and pass it to %rax
    # the use of %rip register in here is complex and I will explain in the readme.md file of this project
    leaq jmp_table(%rip), %rdi
    leaq invalid_char(%rip), %rsi
    movq $256, %rcx # loop counter

.fill_loop:
    movq %rsi, (%rdi) # store `invalid_char` into the current quad
    addq $8, %rdi
    loop .fill_loop

    leaq jmp_table(%rip), %rax

    leaq cmd_plus(%rip), %rbx
    movq %rbx, 0x2B*8(%rax) # 0x2B (+) * 8 = 0x158 + jmp_table address -> offset representing the character within the table

    leaq cmd_minus(%rip), %rbx
    movq %rbx, 0x2D*8(%rax) # 0x2D (-)

    leaq cmd_right(%rip), %rbx
    movq %rbx, 0x3E*8(%rax) # 0x3E (>)

    leaq cmd_left(%rip), %rbx
    movq %rbx, 0x3C*8(%rax) # 0x3C (<)

    leaq cmd_comma(%rip), %rbx
    movq %rbx, 0x2C*8(%rax) # 0x2C (,)

    leaq cmd_dot(%rip), %rbx
    movq %rbx, 0x2E*8(%rax) # 0x2E (.)

    leaq cmd_osqbr(%rip), %rbx
    movq %rbx, 0x5B*8(%rax) # 0x5B ([)

    leaq cmd_csqbr(%rip), %rbx
    movq %rbx, 0x5D*8(%rax) # 0x5D (])

    # we must to do this 'cause memory is stored continuously
    # therefore, to access a value stored within the table, we need to get its value from the address of the table itself

load_file:
    movq $2, %rax # sys_open
    movq filename(%rip), %rdi # loads the memory address of `filename` into rdi
    xorq %rsi, %rsi # read only
    xorq %rdx, %rdx
    syscall # used to call kernel to execute the given syscall

    testq %rax, %rax # AND operation to determine if the file was correct opened
    js .error
    # JS (jump if sign) jumps to a specific label if the result of an operation (in this case, test) is negative
    # in here, it will jump to the `error` label

    movq %rax, %r12 # stores file descriptor into `r12` register

    movq $5, %rax # sys_fstat
    movq %r12, %rdi # uses the stored file descriptor
    leaq stat_buf(%rip), %rsi # copies `stat_buf` variable pointer into rsi
    syscall

    testq %rax, %rax
    js .error

    movq stat_buf+48(%rip), %r13 # r13 will store the file size
    # size is stored at offset 48 of buffer because of the struct he populates

    # C implementation (not complete):
    # struct stat {
    #   dev_t st_dev
    #   ino_t st_ino
    #   // ...
    #   off_t st_size // offset 48
    # }

    testq %r13, %r13
    jz .error

    movq %r13, code_mmap_size(%rip)
    
    # mmap maps something into the virtual memory of the program
    # instead of reading a file and copy data into a buffer, mmap will only pointer to a map
    movq $9, %rax # sys_mmap

    # in here, we make a xor operation to make RDI (register destination index) null
    # therefore, the kernel itself will determine the address to allocate the file (in this case)
    ## if was needed to allocate at a specific memory address, we could do this by using:
    # mov rdi, <memory_address>
    xorq %rdi, %rdi

    # allocates memory to mmap according to file length
    movq code_mmap_size(%rip), %rsi # stores the file size into %rsi register
    movq $3, %rdx

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
    js .error

    movq %rax, tape_base_code(%rip) # mapped code address

    movq $3, %rax # sys_close
    movq %r12, %rdi # file descriptor that will be closed
    syscall

create_cell_mmap:
    movq $9, %rax # sys_mmap
    xorq %rdi, %rdi # kernel chooses address
    movq cell_mmap_size(%rip), %rsi # mmap size
    movq $3, %rdx # PROT_READ | PROT_WRITE
    movq $0x22, %r10 # MAP_ANONYMOUS
    movq $-1, %r8 # no file descriptor
    xorq %r9, %r9 # offset = 0
    syscall

    testq %rax, %rax
    js .error

    movq %rax, cell_mmap_base(%rip) # mapped cells address

interpret_loop:
    movq tape_index_code(%rip), %r15 # loads the current code index into %r15 register
    movq tape_base_code(%rip), %rdx # gets the base address value of the code storage mmap
    movzx (%rdx, %r15, 1), %rax # copies the sum between %rdx and %r15 (current symbol) into %rax

    testq %rax, %rax
    jz end_program

    leaq jmp_table(%rip), %rbp # gets the base value of the jmp_table (to call labels)
    movq (%rbp, %rax, 8), %rbp # gets the symbol handler label stored in jmp_table

    call calculate_cell_index # call a label to calculate the current cell
    movq %rax, %rdi

    jmp *%rbp # call label (indirect register)

continue_loop:
    incq %r15 # increases %r15
    movq %r15, tape_index_code(%rip)

    incq %r15
    cmpq code_mmap_size(%rip), %r15 # verifies if the the file limit was reached
    jl interpret_loop # if lower, call interpret_loop to make a loop
    jz end_program

# operations labels
cmd_plus:
    incb (%rdi) # increases the value stored in %rax address
    jmp continue_loop

cmd_minus:
    decb (%rdi) # decreases the value stored in %rax address
    jmp continue_loop

cmd_dot:
    movq $1, %rax # sys_write
    pushq %rdi
    movq $1, %rdi # file descriptor: stdout
    movq (%rsp), %rsi
    movq $1, %rdx # it will always have 1 byte
    syscall

    popq %rdi

    jmp continue_loop

cmd_right:
    movq current_cell(%rip), %rax # gets the current cell

    cmpq $MAX_CELL_MMAP_SIZE, %rax # compares it to 2MB
    jz .expand_error # if equal, jump to a label to handle the error

    incq %rax # increases the current cell
    movq %rax, current_cell(%rip) # update current_cell global variable

    cmpq cell_mmap_size(%rip), %rax # compares the current cell with the size of the mmap
    jge expand_right # if they're equal, jump to a label to expand the mmap to right
  
    jmp continue_loop

cmd_left:
    movq current_cell(%rip), %rax # current cell index
    cmpq $0, %rax # compares the current cell index with 0

    # in the case it is equal, it means the start limit was reached
    # therefore, it is needed to expand to the left
    jz expand_left

    movq current_cell(%rip), %rax # updated current cell index
    decq %rax # decreases the current cell
    movq %rax, current_cell(%rip) # update the current cell index
    
    jmp continue_loop

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
    
    jmp continue_loop

cmd_osqbr:
    call calculate_cell_index # call a label to calculate the current cell

    movzx (%rax), %rcx # current cell value

    cmpq $0, %rcx
    jz .jmp_to_final_of_loop

    pushq tape_index_code(%rip) # push current symbol memory address ([) into stack memory

    jmp continue_loop

.jmp_to_final_of_loop:
    movq last_closed_square_bracket(%rip), %rax
    cmpq $0, %rax
    jnz .jmp_with_ease

    jmp .jmp_with_loop

.jmp_with_ease:
    movq last_closed_square_bracket(%rip), %rax
    incq %rax

    cmpq code_mmap_size(%rip), %rax
    jz end_program

    movq %rax, tape_index_code(%rip)
    jmp interpret_loop

.jmp_with_loop:
    movq tape_index_code(%rip), %rdi
    movq tape_base_code(%rip), %rsi # gets the base of the code mmap
    addq %rdi, %rsi # sums current index code (%rdi) with mmap base to get
    # the memory address of the current symbol

    cmpq $0x5B, (%rsi) # [
    incb current_loop_depth(%rip)
    
    cmpq $0x5D, (%rsi) # compares 0x5D (]) with the value of the current symbol
    jz .verify_depth # if equal, verify the depth of loop

    incq %rdi # if not, increases %rdi (index)

    cmpq code_mmap_size(%rip), %rdi
    jz .not_closed_bracket_error

    movq %rdi, tape_index_code(%rip) # updates variable
    jmp .jmp_with_loop

.verify_depth:
    cmpq $0, current_loop_depth(%rip)
    jz interpret_loop
    incb current_loop_depth(%rip)

    decb current_loop_depth(%rip)
    ret

cmd_csqbr:
    movq (%rsp), %rax # gets the index of the current open square bracket (in stack memory)
    movq tape_index_code(%rip), %rdi # moves the current symbol index to %rdi
    movq %rdi, last_closed_square_bracket(%rip) # stores it into a variable (it will be used to jump)

    movq %rax, tape_index_code(%rip) # moves the opening index of the loop into code index

    popq %rbx # pops the top value from stack memory
    jmp interpret_loop

expand_right:
    xorq %rdx, %rdx # first 64 bits
    movq cell_mmap_size(%rip), %rax # old mmap size (last 64 bits)
    movq $2, %rsi
    divq %rsi # get half of the mmap

    addq cell_mmap_size(%rip), %rax # new mmap size (current size + half size)

    movq %rax, %rcx # new mmap size (copy)
    cmpq $MAX_CELL_MMAP_SIZE, %rcx # verifies if the new size reached 2MB
    jg .expand_error # if so, jump to the handle label

    movq $25, %rax # sys_mremap
    movq cell_mmap_base(%rip), %rdi # old mmap address
    movq cell_mmap_size(%rip), %rsi # old mmap size
    movq %rcx, %rdx # new mmap size
    movq $1, %r10 # MREMAP_MAYMOVE: relocate the mapping to a new virtual address, if necessary
    syscall

    testq %rax, %rax
    js .error

    movq %rax, cell_mmap_base(%rip)
    movq %rbx, cell_mmap_size(%rip)
    
    jmp continue_loop

expand_left:
    xorq %rdx, %rdx
    movq cell_mmap_size(%rip), %rax
    movq $2, %rdi
    divq %rdi # RDX:RAX / RDI (half of the mmap)

    movq %rax, shift_left_expand(%rip)
    addq cell_mmap_size(%rip), %rax # size of the new mmap
    movq %rax, %r14 # copy

    cmpq $MAX_CELL_MMAP_SIZE, %rsi # verify if the limit was reached
    jg .expand_error # if so, calls the error handler label
    
    movq $9, %rax # sys_mmap
    xorq %rdi, %rdi
    movq %r14, %rsi # mmap size
    movq $3, %rdx # PROT_READ | PROT_WRITE
    movq $0x22, %r10 # MAP_ANONYMOUS
    movq $-1, %r8 # no file descriptor
    xorq %r9, %r9 # offset = 0
    syscall

    testq %rax, %rax
    js .error

    movq %rax, %r15 # new mmap base

    movq %r15, %rdi # base of the new mmap (not updated yet), coming from "expand_left" label
    movq cell_mmap_base(%rip), %rsi # base of the old mmap
    addq shift_left_expand(%rip), %rdi # base + offset
    movq cell_mmap_size(%rip), %rcx # current cell mmap size

    call copy_memory # call label to copy values into the new mmap, in correct offset
 
    movq $11, %rax # sys_munmap
    movq cell_mmap_base(%rip), %rdi
    movq cell_mmap_size(%rip), %rsi
    syscall

    # updates
    movq %r14, cell_mmap_size(%rip)
    movq %r15, cell_mmap_base(%rip)
    movq shift_left_expand(%rip), %rax
    addq %rax, current_cell(%rip)
    
    jmp continue_loop

copy_memory:
    testq %rcx, %rcx
    jz .copy_done

.copy_loop:
    movb (%rsi), %al # old mmap base
    movb %al, (%rdi) # base of the new mmap + shift
    incq %rsi
    incq %rdi
    decq %rcx
    jnz .copy_loop

.copy_done:
    ret

calculate_cell_index:
    xorq %rdx, %rdx
    movq cell_mmap_size(%rip), %rax # loads the stored cell mmap size
    movq $2, %rbx
    divq %rbx # RDX:RAX / RBX (middle of the mmap)

    addq current_cell(%rip), %rax # sums it to the %rax
    addq cell_mmap_base(%rip), %rax # current cell address
    ret

# end program labels
clean_mmaps:
    # code mmap
    movq $11, %rax # sys_munmap
    leaq tape_base_code(%rip), %rdi # mmap address
    movq code_mmap_size(%rip), %rsi # mmap size
    syscall
    
    # cells mmap
    movq $11, %rax
    leaq cell_mmap_base(%rip), %rdi
    movq cell_mmap_size(%rip), %rsi
    syscall
    ret

invalid_char:
    jmp continue_loop

.error:
    call clean_mmaps
    movq $60, %rax # sys_exit
    movq $1, %rdi # exit code (fail)
    syscall

.expand_error:
    movq $1, %rax # sys_write
    movq $1, %rdi # fd: stdout
    leaq expand_error_message(%rip), %rsi
    movq $40, %rdx # 40 bytes
    syscall

    jmp .error

.not_valid_symbol_error:
    movq $1, %rax #sys_write
    movq $1, %rdi
    leaq not_valid_symbol_error_message(%rip), %rsi
    movq $50, %rdx
    syscall

    jmp .error

.not_closed_bracket_error:
    movq $1, %rax #sys_write
    movq $1, %rdi
    leaq not_closed_bracket_error_message(%rip), %rsi
    movq $50, %rdx
    syscall

    jmp .error

end_program:
    call clean_mmaps

    movq $1, %rax #sys_write
    movq $1, %rdi
    lea newline(%rip), %rsi
    movq $1, %rdx
    syscall

    movq $60, %rax # sys_exit
    movq $0,  %rdi # exit code (successful)
    syscall
