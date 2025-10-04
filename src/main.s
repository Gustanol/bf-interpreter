section .data
    ; initialize a jump table with 256 spaces filled by invalid characters
    ;
    ; dq (define quadword) is used to allocate a space of 8 bytes (an ASCII character)
    ; therefore, the table will need 2048 bytes of memory (256*8)
    jmp_table: times 256 dq invalid_char

; instructions section
section .text
    global _start

_start:
    ; in here, will define the valid entrances of BF in `jmp_table`
    ;
    ; in each of the following value attribution, we will associate a label pointer
    ; to quadword (8-byte) value in the correct memory address
    mov qword [jmp_table + '+'*8], cmd_plus ; '+' = 0x2B (43) * 8 = 0x158 (344) + jmp_table address -> offset representing the character within the table
    mov qword [jmp_table + '-'*8], cmd_minus
    mov qword [jmp_table + '>'*8], cmd_right
    mov qword [jmp_table + '<'*8], cmd_left

    ; we must to do this 'cause memory is stored continuously
    ; therefore, to access a value stored within the table, we need to get its value from the address of the table itself
