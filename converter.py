import textwrap

def bf_to_verilog_load(bf_program: str, indent_level: int = 4) -> str:
    """
    Converts a Brainfuck program string into a Verilog case block format 
    suitable for hardcoding program memory loading.
    """
    # Define the instruction mapping (based on ASCII and common BF cores)
    INSTRUCTION_MAP = {
        '+': "8'h2B",
        '-': "8'h2D",
        '>': "8'h3E",
        '<': "8'h3C",
        '.': "8'h2E",
        ',': "8'h2C",
        '[': "8'h5B",
        ']': "8'h5D",
    }
    
    # 1. Clean the program (remove all non-instruction characters)
    clean_program = "".join(c for c in bf_program if c in INSTRUCTION_MAP)
    
    output_lines = []
    
    # 2. Generate the Verilog case lines
    for addr, instruction in enumerate(clean_program):
        hex_code = INSTRUCTION_MAP.get(instruction)
        if hex_code:
            # Format: '    <address>: prog_wr <= <hex_code>; // <instruction>'
            line = f"{addr}: prog_wr <= {hex_code}; // {instruction}"
            output_lines.append(line)
            
    # Calculate the program length
    prog_length = len(clean_program)

    # 3. Assemble the final output block
    indent = " " * indent_level
    verilog_block = f"""\
{indent}// --- BEGIN AUTO-GENERATED CODE ---
{indent}// PROGRAM LENGTH (PROG_LEN) should be set to: {prog_length}
{indent}case (iptr)
"""
    
    # Add the generated case lines with required indentation
    for line in output_lines:
        verilog_block += f"{indent}  {line}\n"
        
    verilog_block += f"""\
{indent}  default: prog_wr <= 8'h00; // NOP
{indent}endcase
{indent}// --- END AUTO-GENERATED CODE ---
"""
    return verilog_block, prog_length

# --- EXAMPLE USAGE ---

# Use the 'Hello World' stress test program
hello_world_program = "++++++++[>++++[>++>+++>+++>+<<<<-]>+>+>->>+[<]<-]>>.>---.+++++++..+++.>>.<-.<.+++.------.--------.>>+.>++."

# Use the Nested Loop (2 * 3) stress test program
# nested_loop_program = "++[>+++<-]"


# Generate the output for the Nested Loop test
verilog_code, length = bf_to_verilog_load(hello_world_program)

print(f"## 🛠️ Verilog Output for: {hello_world_program}")
print(verilog_code)
print(f"**NOTE:** Set the PROG_LEN parameter to **{length}** in your module declaration.")