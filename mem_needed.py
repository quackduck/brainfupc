import math
from math import ceil, log2

prog_len = 2**15 - 1 # 16383
data_len = prog_len # could be a different choice. apparently its standard to have 30,000

prog_addr_len = ceil(log2(prog_len))
data_addr_len = ceil(log2(data_len))

total = 0

# total += prog_len * 8 # program memory
# total += data_len * 8 # data memory

# total += prog_addr_len * prog_len # jump table memory. stores address of matching inst for each inst.

bracket_stack_len = prog_len // 2 # max number of bracket pairs. one entry per opening bracket
# total += prog_addr_len * bracket_stack_len # bracket stack memory. stores addresses of opening brackets.



prog_mem = prog_len * 3
data_mem = data_len * 8
jump_table_mem = prog_addr_len * prog_len
bracket_stack_mem = prog_addr_len * bracket_stack_len



print(f"If we want prog_len = {prog_len} and data_len = {data_len}:\n")




print("With optimal scheme:")

print(f"Program Memory: {prog_mem / 1024:.2f} KB")
print(f"Data Memory: {data_mem / 1024:.2f} KB")
print(f"Jump Table Memory: {jump_table_mem / 1024:.2f} KB")
print(f"Bracket Stack Memory: {bracket_stack_mem / 1024:.2f} KB")
total = prog_mem + data_mem + jump_table_mem + bracket_stack_mem
print(f"Total Memory Needed: {total / 1024:.2f} KB")



# print("\nWith current scheme:")
# prog_mem = prog_len * 8 # currently using 8 bits per inst (tf)
# data_mem = data_len * 8
# jump_table_mem = prog_addr_len * prog_len
# bracket_stack_mem = jump_table_mem

# print(f"Program Memory: {prog_mem / 1024:.2f} KB")
# print(f"Data Memory: {data_mem / 1024:.2f} KB")
# print(f"Jump Table Memory: {jump_table_mem / 1024:.2f} KB")
# print(f"Bracket Stack Memory: {bracket_stack_mem / 1024:.2f} KB")
# total = prog_mem + data_mem + jump_table_mem + bracket_stack_mem
# print(f"Total Memory Needed: {total / 1024:.2f} KB")