.section .data
    # error messages
    expand_error_message: .ascii "Error: Maximum cells amount reached\n"
    mismatch_bracket_error_message: .ascii "Error: Mismatch bracket\n"
    missing_value_error_message: .ascii "Error: Flag with no value\n"
    multiple_files_error_message: .ascii "Error: Multiple files given\n"
    no_input_error_message: .ascii "Error: No given code source\n"
    multiple_input_error_message: .ascii "Error: You must use a file or inline code, not both\n"
    file_open_error_message: .ascii "Error: Fail to open file\n"
    few_arguments_message: .ascii "Warning: Execution with no arguments"
    unknown_flag_error_message: .ascii "Error: Not existing flag\n"

    # help messages
    f_flag_help_message: .ascii "-f: receives a file to interpret\n"
    c_flag_help_message: .ascii "-c: receives inline code, without file\n"
    m_flag_help_message: .ascii "-m: receives the limit cell amount\n"
    h_flag_help_message: .ascii "-h: show help, bypassing other flags"

    cell_mmap_size: .quad 4096 # it will be necessary to call `munmap`
    tape_index_code: .quad 0 # current code mmap index
    current_cell: .quad 0 # current cell index

    max_cell_mmap_size: .quad 2097152

    # constants
    newline: .byte 0x0A

# section used to declare a memory segment to a uninitialized static data
.section .bss
    # initialize a jump table with 256 bytes
    # therefore, the table will need 2048 bits of memory (256*8)
    jmp_table: .space 2048
    stat_buf: .space 144 # reserve 144 bits
    input_buffer: .byte 0
    code_mmap_size: .quad 0
    bracket_mmap_base: .quad 0
    
    .align 8
    tape_base_code: .quad 0 # base address of the code mmap
    cell_mmap_base: .quad 0 # it will store the current address base of the cell mmap
    shift_left_expand: .quad 0 # stores the value of the shift to use in the copy loop

    filename: .quad 0 # it will store the name of the file it will be open
    inline_code: .quad 0
    has_inline: .quad 0
    has_file: .quad 0

    symbol_index_acumulator: .quad 0

# instructions section
.section .text
.globl _start

_start:
    movq (%rsp), %r12 # argc
    leaq 8(%rsp), %r13 # argv[0] = program name

    decq %r12 # R12 doesn't count the program name as an argument
    addq $8, %r13 # argv[1]

    cmpq $1, %r12 # compares with one
    jl .few_arguments # if lower, return an error (few arguments)

    leaq jmp_table(%rip), %rdi
    leaq invalid_char(%rip), %rsi
    movq $256, %rcx # loop counter

.fill_loop:
    movq %rsi, (%rdi) # store `invalid_char` into the current quad
    addq $8, %rdi
    loop .fill_loop

    # in here, it will define the valid entrances of BF in `jmp_table`
    # in each of the following value attribution, we will associate it to a label pointer

    # calculate the effective memory of jmp_table and pass it to %rax

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

parse_args_loop:
    testq %r12, %r12 # verifies if argc is zero
    jz .args_done

    movq (%r13), %rdi # value of the current argument

    cmpb $'-', (%rdi) # compares it with '-'
    jne .positional_arg

    movb 1(%rdi), %al

    cmpb $'c', %al
    je c_flag

    cmpb $'f', %al
    je f_flag

    cmpb $'m', %al
    je m_flag

    cmpb $'h', %al
    je h_flag
    
    jmp .unknown_flag

.positional_arg:
    cmpb $0, has_file(%rip)
    jne .error_multiple_files

    movq %rdi, filename(%rip)
    movq $1, has_file(%rip)
    jmp .next_arg

.next_arg:
    decq %r12
    addq $8, %r13
    jmp parse_args_loop

.args_done:
    movb has_inline(%rip), %al
    orb has_file(%rip), %al
    jz .error_no_input

    movb has_inline(%rip), %al
    andb has_file(%rip), %al
    jnz .error_multiple_input

    cmpb $1, has_inline(%rip)
    je .use_inline
    jmp load_file

c_flag:
    decq %r12
    addq $8, %r13 # next argument

    testq %r12, %r12
    jz .missing_value

    movq (%r13), %rdi # flag value
    movq %rdi, inline_code(%rip) # stores the code into the variable

    movb $1, has_inline(%rip) # true
    jmp .next_arg

f_flag:
    decq %r12
    addq $8, %r13 # next arg

    testq %r12, %r12
    jz .missing_value

    movq (%r13), %rax
    movq %rax, filename(%rip) # stores the filename into 'filename' variable
    movb $1, has_file(%rip) # makes it true
    jmp .next_arg

m_flag:
    decq %r12
    addq $8, %r13 # next arg

    testq %r12, %r12
    jz .missing_value

    movq (%r13), %rdi
    call parse_number # call a label to convert a string to number

    movq %rax, max_cell_mmap_size(%rip)
    jmp .next_arg

h_flag:
    jmp print_help

.unknown_flag:
    jmp .unknown_flag_error

.use_inline:
    movq inline_code(%rip), %rdi
    call strlen # call a label to convert a given string in integer
    movq %rax, code_mmap_size(%rip) # stores it into a global variable

    movq $9, %rax # sys_mmap
    xorq %rdi, %rdi # kernel chooses address
    movq code_mmap_size(%rip), %rsi # mmap size
    addq $1, %rsi # \0
    movq $3, %rdx # PROT_READ | PROT_WRITE
    movq $0x22, %r10 # MAP_ANONYMOUS
    movq $-1, %r8 # no file descriptor
    xorq %r9, %r9 # offset = 0
    syscall

    testq %rax, %rax
    js .error

    movq %rax, tape_base_code(%rip) # copy the base of the mmap into tape_base_code
    
    movq inline_code(%rip), %rsi
    movq %rax, %rdi
    movq code_mmap_size(%rip), %rcx
    call copy_inline_code_to_mmap # call a label to copy code from inline to mmap

    movq tape_base_code(%rip), %rax
    movq code_mmap_size(%rip), %rcx
    movb $0, (%rax, %rcx, 1) # add '\0' at the final

    jmp create_cell_mmap

copy_inline_code_to_mmap:
    testq %rcx, %rcx
    jz .done
.loop_inline_code:
    testq %rcx, %rcx
    jz .done
    
    movb (%rsi), %al
    movb %al, (%rdi)

    incq %rsi
    incq %rdi

    decq %rcx
    jnz .loop_inline_code
.done:
    ret

load_file:
    movq $2, %rax # sys_open
    movq filename(%rip), %rdi # loads the memory address of `filename` into rdi
    xorq %rsi, %rsi # read only
    xorq %rdx, %rdx
    syscall # used to call kernel to execute the given syscall

    testq %rax, %rax # AND operation to determine if the file was correct opened
    js .file_open_error
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

create_bracket_mmap:
    movq code_mmap_size(%rip), %rsi
    shlq $3, %rsi # code mmap size * 8

    movq $9, %rax # sys_mmap
    xorq %rdi, %rdi
    movq $3, %rdx # PROT_READ | PROT_WRITE
    movq $0x22, %r10 # MAP_ANONYMOUS
    movq $-1, %r8 # no file descriptor
    xorq %r9, %r9 # offset = 0
    syscall

    testq %rax, %rax
    js .error

    movq %rax, bracket_mmap_base(%rip) # mapped bracket base

preprocess_brackets:
    xorq %r12, %r12
    movq %rsp, %r15

    movq tape_base_code(%rip), %rsi

.preprocess_loop:
    movzx (%rsi, %r12, 1), %eax # current byte of the code

    testb %al, %al # \0
    jz .preprocess_loop_done

    cmpb $'[', %al
    jz .open_bracket

    cmpb $']', %al
    jz .close_bracket

    jmp .next_byte

.open_bracket:
    pushq %r12
    jmp .next_byte

.close_bracket:
    cmpq %rsp, %r15 # compares the current RSP with the saved one before loop
    jz .mismatch_bracket_error

    popq %rax
    movq bracket_mmap_base(%rip), %rdi

    movq %r12, (%rdi, %rax, 8) # moves the current index to the index in the stack
    movq %rax, (%rdi, %r12, 8) # moves stack symbol index to the current one
    jmp .next_byte

.next_byte:
    incq %r12
    jmp .preprocess_loop

.preprocess_loop_done:
    cmpq %rsp, %r15
    jne .mismatch_bracket_error

interpret_loop:
    movq tape_index_code(%rip), %r15 # loads the current code index into %r15 register
    movq tape_base_code(%rip), %rdx # gets the base address value of the code storage mmap
    movzx (%rdx, %r15, 1), %rax # copies the sum between %rdx and %r15 (current symbol) into %rax

    testq %rax, %rax
    jz end_program

    cmpb $'+', %al
    jz .increases_acumulator

    cmpb $'-', %al
    jz .increases_acumulator

    cmpb $'<', %al
    jz .increases_acumulator

    cmpb $'>', %al
    jz .increases_acumulator

.continue_interpret_loop:
    leaq jmp_table(%rip), %rbp # gets the base value of the jmp_table (to call labels)
    movq (%rbp, %rax, 8), %rbp # gets the symbol handler label stored in jmp_table

    call calculate_cell_index # call a label to calculate the current cell
    movq %rax, %rdi

    jmp *%rbp # call label (indirect register)

continue_loop:
    movq $0, symbol_index_acumulator(%rip)
    incq tape_index_code(%rip) # increases current code index
    movq tape_index_code(%rip), %r15

    cmpq code_mmap_size(%rip), %r15 # verifies if the the file limit was reached
    jl interpret_loop # if lower, call interpret_loop to make a loop
    jz end_program

.increases_acumulator:
    movq tape_index_code(%rip), %rcx
    movq code_mmap_size(%rip), %rsi

.increases_acumulator_loop:
    movq %rcx, %rdi
    movq %rdi, tape_index_code(%rip)

    incq %rcx

    cmpq %rsi, %rcx
    jge .continue_interpret_loop

    incq symbol_index_acumulator(%rip)

    movq tape_base_code(%rip), %rdx
    movq (%rdx, %rdi, 1), %rdi
    movq (%rdx, %rcx, 1), %rbx

    cmpb %dil, %bl
    je .increases_acumulator_loop

    jmp .continue_interpret_loop

# operations labels
cmd_plus:
    movq symbol_index_acumulator(%rip), %r9
    addq %r9, (%rdi) # increases the value stored in %rax address
    jmp continue_loop

cmd_minus:
    movq symbol_index_acumulator(%rip), %r9
    subq %r9, (%rdi) # decreases the value stored in %rax address
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
    call calculate_cell_index

    movq cell_mmap_size(%rip), %rdi
    movq cell_mmap_base(%rip), %rsi
    
    movq (%rdi, %rsi, 1), %rdx

    cmpq %rdx, %rax # compares the current cell with the size of the mmap
    jge expand_right # if they're equal, jump to a label to expand the mmap to right

    movq symbol_index_acumulator(%rip), %rsi
    addq %rsi, current_cell(%rip) # update current_cell global variable
  
    jmp continue_loop

cmd_left:
    call calculate_cell_index

    movq cell_mmap_size(%rip), %rdi
    movq cell_mmap_base(%rip), %rsi
    
    movq (%rdi, %rsi, 1), %rdx

    cmpq %rdx, %rax # compares the current cell index with cell_mmap_base

    # in the case it is equal, it means the start limit was reached
    # base + base/2 + index -> index = base/2
    # therefore, it is needed to expand to the left
    jge expand_left

    movq symbol_index_acumulator(%rip), %rsi
    subq %rsi, current_cell(%rip) # update the current cell index
    
    jmp continue_loop

cmd_comma:
    xorq %rax, %rax # sys_read
    xorq %rdi, %rdi # stdin
    leaq input_buffer(%rip), %rsi # buffer
    movq $1, %rdx # 1 byte
    syscall

    call calculate_cell_index
    movb input_buffer(%rip), %dl
    movb %dl, (%rax) # saves the read buffer into the current cell value
    
    jmp continue_loop

cmd_osqbr:
    call calculate_cell_index # call a label to calculate the current cell
    movzx (%rax), %rcx # current cell value

    testb %cl, %cl
    jz .jmp_to_final_of_loop

    jmp continue_loop

.jmp_to_final_of_loop:
    movq bracket_mmap_base(%rip), %rdi
    movq tape_index_code(%rip), %rsi
    movq (%rdi, %rsi, 8), %rax

    movq %rax, tape_index_code(%rip)
    jmp continue_loop

cmd_csqbr:
    movq bracket_mmap_base(%rip), %rdi
    movq tape_index_code(%rip), %rsi
    movq (%rdi, %rsi, 8), %rax

    movq %rax, tape_index_code(%rip) # moves the opening index of the loop into code index
    jmp interpret_loop

expand_right:
    xorq %rdx, %rdx # first 64 bits
    movq cell_mmap_size(%rip), %rax # old mmap size (last 64 bits)
    movq $2, %rsi
    divq %rsi # get half of the mmap

    addq cell_mmap_size(%rip), %rax # new mmap size (current size + half size)

    movq %rax, %rcx # new mmap size (copy)

    cmpq max_cell_mmap_size(%rip), %rcx # verifies if the new size reached 2MB
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

    cmpq max_cell_mmap_size(%rip), %r14 # verify if the limit was reached
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

parse_number:
    xorq %rax, %rax
    xorq %rcx, %rcx
.loop:
    movzx (%rdi, %rcx, 1), %rbx
    testb %bl, %bl
    jz .loop_done 

    # Verifica se é dígito
    cmpb $'0', %bl
    jl .error_nan
    cmpb $'9', %bl
    jg .error_nan
    
    # resultado = resultado * 10
    movq $10, %rdx
    mulq %rdx                # RAX = RAX * 10 (RDX tem lixo depois)
    
    # + (char - '0')
    subb $'0', %bl
    movzx %bl, %rbx
    addq %rbx, %rax
    
    incq %rcx
    jmp .loop
.loop_done:
    ret

.error_nan:
    jmp .error

strlen:
    xorq %rax, %rax

.loop_len:
    cmpb $0, (%rdi, %rax, 1) # verifies if it's '\0'
    je .done_loop_len
    incq %rax # length of the given string
    jmp .loop_len

.done_loop_len:
    ret

print_help:
    movq $1, %rax # sys_write
    movq $1, %rdi # fd: stdout
    leaq f_flag_help_message(%rip), %rsi
    movq $33, %rdx
    syscall

    movq $1, %rax
    movq $1, %rdi
    leaq c_flag_help_message(%rip), %rsi
    movq $39, %rdx
    syscall

    movq $1, %rax
    movq $1, %rdi
    leaq m_flag_help_message(%rip), %rsi
    movq $35, %rdx
    syscall

    movq $1, %rax
    movq $1, %rdi
    leaq h_flag_help_message(%rip), %rsi
    movq $36, %rdx
    syscall

    jmp end_program

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
    movq $37, %rdx
    syscall

    jmp .error

.mismatch_bracket_error:
    movq $1, %rax #sys_write
    movq $1, %rdi
    leaq mismatch_bracket_error_message(%rip), %rsi
    movq $24, %rdx
    syscall

    jmp .error

.missing_value:
    movq $1, %rax #sys_write
    movq $1, %rdi
    leaq missing_value_error_message(%rip), %rsi
    movq $27, %rdx
    syscall

    jmp .error

.error_multiple_files:
    movq $1, %rax #sys_write
    movq $1, %rdi
    leaq multiple_files_error_message(%rip), %rsi
    movq $29, %rdx
    syscall

    jmp .error

.error_no_input:
    movq $1, %rax #sys_write
    movq $1, %rdi
    leaq no_input_error_message(%rip), %rsi
    movq $29, %rdx
    syscall

    jmp .error

.error_multiple_input:
    movq $1, %rax #sys_write
    movq $1, %rdi
    leaq multiple_input_error_message(%rip), %rsi
    movq $52, %rdx
    syscall

    jmp .error

.file_open_error:
    movq $1, %rax # sys_write
    movq $1, %rdi
    leaq file_open_error_message(%rip), %rsi
    movq $25, %rdx
    syscall

    jmp .error

.few_arguments:
    movq $1, %rax # sys_write
    movq $1, %rdi
    leaq few_arguments_message(%rip), %rsi
    movq $36, %rdx
    syscall

    jmp end_program

.unknown_flag_error:
    movq $1, %rax # sys_write
    movq $1, %rdi
    leaq unknown_flag_error_message(%rip), %rsi
    movq $25, %rdx
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
