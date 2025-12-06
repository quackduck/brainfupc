## Background

### Fall 2024

At HackMIT 2024, Bun, one of the companies sponsoring the hackathon, announced that they'd give $1,000 to the team that makes the fastest Brainfuck interpreter.

Since I'd brought my (pricey) Pynq Z1 that Hunter from Cradle graciously let me keep after the end of my internship, I thought to myself: what could be faster than a Brainfuck interpreter implemented in hardware?

Quick check:
```
Clock speeds
  Pynq: 50 MHz.
Laptop: ~3 GHz == 60x faster.

I win if the software version uses 60x more clock cycles per instruction.
```
Okay... so I guess a random C implementation would likely be faster. 

But we'll make it anyway! And we'll call it a Brainfuck CPU, because what is a CPU if not a hardware interpreter?

One day later, after a lot of frustrating fiddling with Vivado, Ethernet cables, Jupyter notebooks, AXI DMA, little sleep and one can of Yerba Mate, I had a tiny demo proving I could do a small amount of computation on the FPGA. This demo was about halfway to what I would have liked my project to be. After telling the judges about the broader picture of hardware acceleration, I won Most Technical at HackMIT 2024 (they gave me an instant camera) but did not win Bun's challenge.

Unfortunately, my project didn't feel very real. It didn't have any ability to do jumps, and so wasn't Turing complete. This feeling built up until I had to fix it the following summer.

### Summer 2025

Here's some central pieces of the VHDL code I wrote to gain Turing completeness:



This piece builds a jump table storing matching bracket addresses:
```vhdl
if (program_buf(temp_iptr) = x"5b") then -- '['

    bracket_stack(temp_stack_ptr) <= std_logic_vector(to_unsigned(temp_iptr, 10));
    temp_stack_ptr := temp_stack_ptr + 1;

elsif (program_buf(temp_iptr) = x"5d") then -- ']'

    temp_stack_ptr := temp_stack_ptr - 1;
    jump_table(temp_iptr) <= bracket_stack(temp_stack_ptr); -- ] points to [
    jump_table(to_integer(unsigned(bracket_stack(temp_stack_ptr)))) <= std_logic_vector(to_unsigned(temp_iptr, 10)); -- [ points to ]

end if;
temp_iptr := temp_iptr + 1;
```

This piece fetches and executes one instruction:
```vhdl
-- led(3 downto 0) <= std_logic_vector(to_unsigned(iptr, 4));
inst := program_buf(iptr);

curr_output := (others => '0');

case inst is
    when x"3e" => -- '>'
        dptr := dptr + 1;
    when x"3c" => -- '<'
        dptr := dptr - 1;
    when x"2b" => -- '+'
        data(dptr) <= std_logic_vector(unsigned(data(dptr)) + 1);
    when x"2d" => -- '-'
        data(dptr) <= std_logic_vector(unsigned(data(dptr)) - 1);
    when x"2e" => -- '.'
        curr_output := data(dptr);
    when x"2c" => -- ','
        -- ummm no input rn

    when x"5b" => -- '['

        if (data(dptr) = x"00") then
            iptr := to_integer(unsigned(jump_table(iptr)));
        end if;

    when x"5d" => -- ']'

        if (data(dptr) /= x"00") then
            iptr := to_integer(unsigned(jump_table(iptr)));
        end if;

    when others =>
        null;
end case;

stream_data_out(7 downto 0) <= curr_output;
iptr := iptr + 1;
```
Easy to reason about, but this is not good code.



Anyone with FPGA experience can see how this code is absolutely thrashing the poor device. By storing all data such that I can retrieve an item at any index immediately, I force Vivado to synthesize "distributed RAM," which can easily use up almost all the LUTs on the FPGA and cause timing problems. I'm pretty sure this was the cause of my programs breaking when I uncommented this line:
```vhdl
led(3 downto 0) <= std_logic_vector(to_unsigned(iptr, 4));
```
Which, of course, should change nothing about program execution. (???)


One can only imagine how twisted the synthesis and implementation tools had to get to have this nested array access happen within a single clock cycle:

```vhdl
jump_table(to_integer(unsigned(bracket_stack(temp_stack_ptr)))) <= std_logic_vector(to_unsigned(temp_iptr, 10)); -- [ points to ]
```

This design did work! I got it to say Hello World, compute Fibonacci numbers, and go into infinite loops. (The only three things a computer needs to be able to do, of course.)

Limited to around 1024 for program size, data tape size, output size, and having no input at all meant that I couldn't run all the interesting programs I wanted to.

The nagging suspicion that feeling limited by such a pricey FPGA running such a simple idea meant I was doing something really wrong, and my hard to debug issues, meant that this left a bad aftertaste.

## How to make a Brainfuck CPU

Back at Purdue for my third year, Amber, my partner, nudges me to present my CPU at [Spill](https://spill.purduehackers.com), a showcase of projects she's helping organize. I'm considering it. When Ray tells me I can get reimbursed for whatever hardware I want, I'm completely convinced.

I want a return to simplicity. I will free myself from Vivado and free all who want a Brainfuck CPU. I will use a cheap open-source FPGA and use open-source tooling to program it with code I will open-source.

Five days after hearing I will be reimbursed, I have a shiny new Icebreaker v1.1a in my hands along with a couple seven-segment displays. This is all I need to get started.

### Ingredients

#### What's an FPGA?
An FPGA is a piece of programmable silicon. Essentially, you describe circuits in code and the FPGA will pretend to become that circuit, like magic! 

For example, you could have it pretend to be an HDMI to USB adapter. Or a counter connected to some LEDs. Or a fast hardware-based SHA256 hasher. Or even an entire RISC-V CPU that can run Linux.

Of course, they are not actually magic and have no moving "rewiring" parts. They are cleverly designed chips that wire together "lookup tables" (LUTs) to give this appearance.

If FPGAs are so flexible, and can become anything? Why not just use them everywhere? You could have something like a processor that can switch from being ARM to x86 to RISC-V. 

Unfortunately, as is a trend in computer science, mathematics, and life in general, genericity comes with a cost. While actual CPUs operate at gigahertz clock speeds, FPGAs are in the tens to hundreds of megahertz domain.

This does not make them slow! For an FPGA running at 50 megahertz, light travels about 6 meters (~18 feet). Imagine doing computation at that speed! While software engineers might sometimes think in microseconds, FPGA engineers think in nanoseconds.

(While it's not practical to have CPUs be implemented on FPGAs, I think it would be cool to have laptops with small FPGAs builtin.)

#### What's Brainfuck?

What does a computer need to be able to do to be able to compute? Can some computers compute more than others? What does "compute" mean? Thankfully for us, Alan Turing helped with these questions back in the 19-somethings. 

We now know that there are very few operations a computer needs to support that make it possible to compute anything your laptop might. It might just be really slow!

Using "Turing-complete" as an adjective thus means being able to compute anything that any other Turing-complete machine can. This is a bit of a circular definition, of course, unless I give you some base cases. The following are Turing-complete: 
- Apple M2
- Python
- Lisp
- TypeScript's type system
- Some sort of water contraption
- And of course...

**Brainfuck**, the minimal and infamous Turing-complete language known to break programmer heads composed of just eight symbols.

Given a "data tape", a 1-D array of bytes called "cells", and the "program", the list of instructions, here's what each of the instructions do:

- `+` Increment value of current cell
- `-` Decrement value of current cell
- `>` Go to next cell
- `<` Go to previous cell
- `.` Output current cell as a character
- `,` Set current cell to the next input character 
- `[` If the current cell is 0, skip to the instruction after the matching `]`
- `]` If the current cell is not 0, skip back to the instruction after the matching `[`

(The last two might seem complicated, but its just a `while (cell != 0)` if you think about it)

And that's it! Here's some basic Brainfuck programs:

```bf
+++.>++.
```
Prints `0x03` and then `0x02`. If we wanted to print a letter, say `A`, which is 65 in ASCII, we could chain 65 pluses together first.

```bf
-.
```
Prints `0xff`. Since cells are bytes, `0 - 1 = 255`

```bf
+[.]
```
Infinite loop that prints `0x01` constantly.

```bf
.+[.+]
```
Prints every byte from `0x00` to `0xff`. Do you see how?

```bf
+++[>++++<-].>.
```
This is multiplication! Do you see how?

```bf
+++++[>+++++++++++++<-]>.
```
A better way to print the character A than stringing 65 pluses.

Finally, here is `Hello World!\n`
```bf
++++++++++[>+++++++>++++++++++>+++>+<<<<-]>++.>+.+++++++..+++.>++.<<+++++++++++++++.>.+++.------.--------.>+.>.
```
It shouldn't look totally unfamiliar anymore!

### BF CPU


#### High level design

Imagine software as using an API provided by the CPU. It becomes clear that someone needs to implement this API in hardware, and that's what it means to make a CPU.

Let's come up with the API that our CPU needs to provide. 

Since we want to implement Brainfuck, we need to support the eight instructions above and the structures they need.

It's clear that we need some way to store the data tape. We'll need a data pointer to keep track of which cell we're on.

Similarly, we need to store the program somehow, and again we'll need an instruction pointer to know which instruction we're executing.

Now we need a way to handle input and output. Since FPGAs don't have screens or keyboards, we'll use a simple streaming interface where the CPU can output one byte at a time and receive one byte at a time through serial. When I was initially developing this CPU, I ignored input and hooked up output to a seven segment display that could only show a single byte.

Looks like we've thought about how to handle incrementing and decrementing the data pointer and current cell, as well as input and output. That's six of the eight instructions:

```sv
case inst:
    > : dptr += 1
    < : dptr -= 1
    + : data[dptr] += 1
    - : data[dptr] -= 1
    . : output data[dptr]
    , : data[dptr] = input
```

To implement `[` and `]`, we need a way to jump to the matching bracket based on the value of the current cell.

For a second, let's think about how we'd implement the comments here:
```sv
if inst == '[':
    if data[dptr] == 0:
        // jump to matching ']'
if inst == ']':
    if data[dptr] != 0:
        // jump to matching '['
```

We could keep track of bracket depth and increment `iptr` until we find the matching bracket:
```sv
if inst == '[':
    if data[dptr] == 0:
        depth = 1
        while depth > 0:
            iptr += 1
            if program[iptr] == '[':
                depth += 1
            elif program[iptr] == ']':
                depth -= 1
        iptr += 1  // inst after matching bracket
```

Hopefully alarms are ringing in your head. This is *slow*. A single instruction could take on the order of the size of the program to execute!

Here's a simple idea. Before we start running, we can have a hashmap of bracket locations. For each `[`, we store the index of the matching `]`, and vice versa. This way, when we need to jump, we can just look it up in O(1) time:
```sv
jump_table = map(int -> int)
stack = []
for iptr:
    if program[iptr] == '[':
        stack.push(iptr)
    elif program[iptr] == ']':
        match = stack.pop()
        jump_table[match] = iptr
        jump_table[iptr] = match
```
And now:
```sv
if inst == '[':
    if data[dptr] == 0:
        iptr = jump_table[iptr] + 1
if inst == ']':
    if data[dptr] != 0:
        iptr = jump_table[iptr] + 1
```

Simple, but we've been thinking in software-y pseudocode. How do we implement this in hardware? We don't have stacks, or hashmaps, and how does memory work?

#### Thinking in hardware

Thankfully, languages like SystemVerilog provide abstractions that allow us to use some of our software thinking. For example, we don't have to implement adders every time we want to increment something; the tooling can do that for us. 

Here's a crash course in clock cycles, logic and memory.

##### Clock
A computer runs off of electricity, and electricity travels at the speed of light, so why aren't computers basically instantaneous?

The answer is that we need synchronization. Let's say we have a circuit that depends on the output of an adder connected to wires carrying two binary numbers, `a` and `b`. Now, let's say that the physical length of the wires carrying `a` is longer. This means that the signal for `a` will arrive later than the signal for `b`. Our adder is a circuit, and so it will continuously compute `a+b` without caring about whether `a` is "valid" (a concept imposed by humans). For a split second, the adder will compute and output garbage.

This is not inherently a problem. If we were just displaying the output of the adder on a seven segment display, it's okay if it flickers garbage for a split second. But it's possible for some circuit to always need valid input.

Hmm, how do we fix this "garbage" problem?

Turns out it's possible to make something called a flip-flop, which is a circuit that can store a single bit of information. It has a clock input and a data input, and whenever the clock signal goes from low to high (a "rising edge"), it will store the value of its data input into its internal storage (surprisingly, a flip-flop can be made from just regular state-less logic gates!).

Now we see a solution. If we have a global clock signal that goes high and low at some frequency, and we can set that frequency so signals always have time to fully propagate between pulses, we can use flip-flops to store values at each rising edge of the clock. This way, we can ensure that all our circuits have "valid" inputs at the same time: right after the clock rises.

This is the core reason we need clock signals. The faster the clock, the faster we can compute things, but the more likely it is that signals won't have time to propagate and we'll get garbage. The limiting factor is thus the "critical path," the longest path a signal has to travel between two flip-flops.

Commercial CPUs run at gigahertz speeds, while FPGAs are usually in the tens to hundreds of megahertz range. This is because CPUs are designed with custom silicon that minimizes the critical path for common operations, while FPGAs have to be generic enough to implement any circuit, which adds overhead.

These are insanely fast speeds. A clock cycle running at 1 GHz allows only 1 nanosecond for signal propagation. Light travels only about 30 centimeters in that time.

##### Logic

In a circuit, instaneous is the default. A logic gate continuously computes its output based on its inputs. How then could we make something like a counter that increments every clock cycle? We can't just connect the output of an adder back to its input, because the adder would continuously increment and never stop.

Think flip-flops! We can use a flip-flop to store the current count, and on each clock cycle, we can feed the output of an adder (which adds 1 to the current count) into the flip-flop's input. This way, the count only updates on the rising edge of the clock.

SystemVerilog makes this super easy:
```sv
logic [7:0] count; // 8-bit counter
always @(posedge clk) begin
    count <= count + 1;
end
```
