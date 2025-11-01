# BF interpreter

This is an efficient interpreter for the esoteric programming language Brainfuck written entirely in x86_64 Assembly!

### Project structure

bf-interpreter/
├── src/ # Source files (.s)
├── build/ # Build artifacts
├── Makefile # Build configuration
└── README.md # This file

---

### Features

- Direct syscalls
- Dynamic memory expansion (up to 2MB by default)
- Flexible command-line interface
- Jump table dispatch
- Robust error handling
- Flags support

---

### Brainfuck syntax

BF has only 8 symbols in its syntax:

- `.`: used to print the value of the current cell
- `,`: used to read a byte by the user and store into the current cell
- `+`: used to increases the value of the current cell
- `-`: used to decreases the value of the current cell
- `<`: used to move one cell to the left
- `>`: used to move one cell to the right
- `[`: used to open a loop
- `]`: used to close a loop

It is based in **cells**, 8-bit sized memory space, to store values

---

### Core logic

Let's break the code and go through each block and feature:

`.section .data`: define global initialized variables
`.section .text`: define global uninitialized variables

---

`_start`: the start function

- It gets `argc` from the top of the stack memory and then the arguments.
- this variable represents the count of arguments passed to a program in its execution.
- `argv[i]` represents the `i` argument passed in
- either `argc` and `argv[i]` has 8 bytes

  > [!IMPORTANT]
  > The arguments are stored in stack memory.
  > `RSP` represents the limit of the current stack frame
  > If we tried to get this variables after a label call, it wouldn't work, because `RBP` and `RSP` would point to the current stack frame.

- Now, we load the memory address into `RDI` register;
- `invalid_char` (any other symbol, except the 8 provided by BF)

---

`.fill_loop`: used to fill `jmp_table` with the symbol handlers

- starts filling all spaces with `invalid_char`
- increments 8 bits in `jmp_table` for each iteration
- calls loop that will be executed `RCX` times (256)
  - In it, we store the each handler in `RBX` and move its pointer into the correct offset of the `jmp_table`

  ```gas
    leaq cmd_plus(%rip), %rbx
    movq %rbx, 0x2B*8(%rax) # 0x2B (+) * 8 = 0x158 + jmp_table base address
  ```

  > [!IMPORTANT]
  > `jmp_table` will represent the ASCII table. That's why it has 256 spaces
  > We must multiply the symbol by 8 to determine the start correct value
  > e.g.: 0x00 \* 8 = 0x00 -> will start at 0x00
  - Now, we can call the pointer by symbol

---

`parse_args_loop`: loop to parse all arguments passed in

- In each iteration, it decreases the value of `argc` (subtracted by 1 to not count program's name)
  - if this value reach zero, the loop if finished

- `RDI` stores the value of current argument
  - Now, its first byte is compared with `-`
    - if ain't present there, jump to a callback to treat the value as file name
  - The value is increased to get the flag
  - The code has 4 flags:
    - `f`: used to pass the file name (can be passed without a flag as well);
    - `c`: used to pass inline code, without a file;
    - `m`: used to pass the maximum value of cells
    - `h`: used to get help

- `use_inline`: called label for when inline code is in use

- In here, a `mmap` is created (just like in file use)
- The next step is copy the symbols into the `mmap`
  - `copy_inline_code_to_mmap`: expects `RSI` (base of the code) and `RDI` (base of the `mmap`)
    - in each iteration, the value stored in `RSI` is passed to `RDI`. At the final, both are increased
  - In the return, it will jump to `create_cell_mmap`

- If `has_file` global variable is `1` and `has_inline` is `0`, the code will try to open the file (its name is stored in `filename` global variable) with `load_file` label

- `load_file`
  - It calls the syscall 2 (SYS_open) to open file by its name
    - The file descriptor is stored into `R12` register
  - Now, we call the syscall number 5 (SYS_fstat) only to get the file size with ease and store it into `R13` register
  - Now, we create the `mmap` to point to that file descriptor (external file)

- `create_cell_mmap`: creates a new mmap to store all program cells
  - By default, it maximum size is 2MB, but it can be increased by passing `-m VALUE` at execution

- `create_bracket_mmap`: creates a mmap to store all brackets index
  - It has the code size 8 times because we will use `qwords` to store 2\*\*64 indexes
    - So, if there's a `[` at `tape_base_code + 0x4000F`, we can access it using `bracket_mmap_base + 0x4000F`

---

**Loop logic**:

- The code preprocess all brackets before interpret

- `preprocess_brackets`
  - `R12`: used as index
  - `R15`: used to store the current value of `RSP`
  - `RSI`: used to store the base of the `mmap` code

- `.preprocess_loop`:
  - `EAX`: gets the current symbol and fill remaining bits with zero

- `.open_bracket`:
  - Only pushes `R12`

- `.close_bracket`:
  - Verifies if `RSP` is the same as `R15` (stored `RSP`)
    - If so, no bracket were open
  - Pops the last bracket and moves it into `RAX`

  - Moves the value of the opening bracket to the current one (closing) in `brackt mmap`
  - Moves the value of the closining bracket (current one) to the opening one in `bracket mmap`

---

- `interpret_loop`: label to interpret BF code
  - `R15`: will receive the current index of code
  - `RDX`: will receive the base of code `mmap`
    - the sum between them will result in the current symbol of code

    > [!NOTE]
    > Note that if we multiply the value of the current symbol by 8, we will get the start offset of its pointer handler stored in `jmp_table`
    - now, call the label by calling an indirect register (`*%rbp`)

- `continue_loop`:
  - Increases the index value and updated its global variable
  - Compares it with the size
    - if lower, go back to loop
    - if zero (equal), call a label to end the program

---

**Symbol labels**

- `cmd_plus` and `cmd_minus`:
  - Increases and decreases respectively the value of the current cell
    - This value is gained by calling the label `calculate_cell_index`
      - It only calculate the index considering the middle as the start

- `cmd_dot`:
  - Calls syscall number 1 (SYS_write) to print the value of the current cell

- `cmd_right`:
  - Compares if the current cell + mmap base is greater or equal than the size of the `mmap` itself
    - If so, the limit was reached and it must be increased
  - Increases the cell index and return to loop

    > [!WARNING]
    > The cell `mmap` starts with 4KB and can be increased up to 2MB by default

- `cmd_left`:
  - Almost the same as `cmd_right`, but decreases cell index instead of increase it

- `cmd_comma`:
  - Calls the syscall number 0 (SYS_read) to read a byte from user and store it in the current cell value

- `cmd_osqbr` (open square bracket):
  - Verifies if the current cell value is zero
    - If it isn't, it will just jump to `continue_loop`
    - If so, it must be jump to its final

- `.jmp_to_final_of_loop`:
  - Gets the index of the closing bracket using bracket `mmap` + current index (bidirectional value)

- `cmd_csqbr` (close square bracket):
  - Only gets the value of the opening bracket and puts it into index of code
  - Jumps to `interpret_loop`

  - It makes a loop that will be stoped if the current cell is zero

---

- `expand_right`:
  - It gets the middle of the `mmap` (right part) and sums to it
  - Calls the syscall number 25 (SYS_mremap) to resize the cell `mmap` with it sum

  > [!NOTE]
  > The `mmap` will be increased to right
  - Updates the base and the size of the global variables

- `expand_left`:
  - The same resize length
  - In here, SYS_mremap would not work we need to expand to left.
    - But there's not possible resizing it (only expands to right)
  - A new `mmap` is created with the new size
  - A label is called to copy the values from the old to new `mmap` with the shift expand variable (left part)

  - Make some updates
    - index = index + shift expand

---

### How to run this?

Build

```bash
make
```

Run

```bash
make run
```

Debug

```bash
make debug
```

Clean

```bash
make clean
```

---

### Usage

```bash
./bf -f program.bf                # Run file
./bf -c "+++[>++."                # Inline code
./bf -m 4096 -f program.bf        # Custom memory limit
./bf -h                           # Help
```

> [!TIP]
> You can find some example code files in [here](https://github.com/fabianishere/brainfuck/tree/master/examples)

---

That's it!
