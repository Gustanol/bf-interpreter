section .data
    ; initialize a jump table with 256 spaces filled by invalid characters
    
    ; dq (define quadword) is used to allocate a space of 8 bytes (an ASCII character)
    ; therefore, the table will need 2048 bytes of memory (256*8)
    jmp_table times 256 dq invalid_char
    filename db "tests/main.bf", 0 ; initialize "filename" variable to store the name of the file it will be open

; instructions section
section .text
    global _start

; section used to declare a memory segment to a uninitialized static data
section .bss
    stat_buf resb 144 ; 144KB

_start:
    ; in here, will define the valid entrances of BF in `jmp_table`
    
    ; in each of the following value attribution, we will associate a label pointer
    ; to quadword (8-byte) value in the correct memory address
    mov qword [jmp_table + '+'*8], cmd_plus ; '+' = 0x2B (43) * 8 = 0x158 (344) + jmp_table address -> offset representing the character within the table
    mov qword [jmp_table + '-'*8], cmd_minus
    mov qword [jmp_table + '>'*8], cmd_right
    mov qword [jmp_table + '<'*8], cmd_left

    ; we must to do this 'cause memory is stored continuously
    ; therefore, to access a value stored within the table, we need to get its value from the address of the table itself

    call load_file ; call label to open the file (filename)
    call interpret ; call label to interpret the code stored

load_file:
    mov rax, 2; sys_open
    lea rdi, [filename] ; uses lea (load effective address) to the memory address of `filename` pointer into rdi
    xor rsi, rsi ; make rsi null to represents zero flag (read only)
    xor rdx, rdx
    syscall ; used to call kernel to execute the given syscall

    test rax, rax ; make an AND operation to determine if the file was correct opened

    ; JS (jump if sign) jumps to a specific label if the result of an operation (in this case, test) is negative
    ; in here, it will jump to the `error` label
    js error
    mov r12, rax ; stores file descriptor into `r12` register

    mov rax, 5 ; sys_fstat
    mov rdi, r12 ; uses the stored file descriptor
    lea rsi, [stat_buf] ; copies `stat_buf` variable pointer into rsi
    syscall
    test rax, rax
    js error
    mov r13, [stat_buf + 48] ; r13 will store the file size
    ; size is stored at 48 offset of the buffer because the struct he populates

    ; C implementation (not all):
    ; struct stat {
    ;   dev_t st_dev
    ;   ino_t st_ino
    ;   // ...
    ;   off_t st_size // offset 48
    ; }
    
    ; mmap maps something into the virtual memory of the program
    ; instead of reading a file and copy data into a buffer, mmap will only pointer to a map
    mov rax, 9 ; sys_mmap

    ; in here, we make a xor operation to make RDI (register destination index) null
    ; therefore, the kernel itself will determine the address to allocate the file (in this case)

    ; if we would need to allocate at a specific memory address, we could do this by using:
    ; mov rdi, <memory_address>
    xor rdi, rdi

    ; allocates memory to mmap according to file length
    mov rsi, r13 ; rsi = register source index: represents the local memory (program memory)
    mov rdx, 1

    ; Protection:
    ; PROT_READ = 1: read
    ; PROT_WRITE = 2: write
    ; PROT_EXEC = 4: execute
    ; ...

    mov r10, 2

    ; Flags:
    ; MAP_SHARED = 1: changes affect the file (shared)
    ; MAP_PRIVATE = 2: changes does not affect the file, it's kept only in memory (copy-on-write)
    ; MAP_PRIVATE = 0x20: not a file, just memory (malloc)

    mov r8, r12 ; define file descriptor
    xor r9, r9 ; offset = 0
    syscall

    test rax, rax
    js error

    mov r14, rax ; mapped code address

    mov rax, 3 ; sys_close
    mov rdi, r12 ; file descriptor that will be closed
    syscall

interpret:

error:
    mov rax, 60 ; sys_exit
    mov rdi, 1 ; exit code (fail)
    syscall
