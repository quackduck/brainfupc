PROJ = top

# List all Verilog source files here
SRCS = top.sv \
	   bram_sp.sv \
       seven_seg_ctrl.sv \
       seven_seg_hex.sv \
	   debounce.sv \
	   cpu_core.sv \
	   spram.sv \
	   hvsync_generator.sv \
	   loader.sv

all: $(PROJ).rpt $(PROJ).bin

$(PROJ).json: $(SRCS)
	yosys -ql $(PROJ).yslog -p 'read_verilog -sv $(SRCS); synth_ice40 -top $(PROJ) -json $@; stat'

$(PROJ).asc: $(PROJ).json icebreaker.pcf
	nextpnr-ice40 -ql $(PROJ).nplog --up5k --package sg48 --freq 12 \
		--asc $@ --pcf icebreaker.pcf --json $< --report $(PROJ)_pnr.rpt


$(PROJ).bin: $(PROJ).asc
	icepack $< $@

$(PROJ).rpt: $(PROJ).asc
	icetime -d up5k -c 12 -mtr $@ $<

# Simulation (testbench)
$(PROJ)_tb: $(PROJ)_tb.v $(SRCS)
	iverilog -g2012 -o $@ $^

$(PROJ)_tb.vcd: $(PROJ)_tb
	vvp -N $< +vcd=$@

# Synthesized netlist (optional)
$(PROJ)_syn.v: $(PROJ).json
	yosys -p 'read_json $^; write_verilog $@'

$(PROJ)_syntb: $(PROJ)_tb.v $(PROJ)_syn.v
	iverilog -g2012 -o $@ $^ `yosys-config --datdir/ice40/cells_sim.v`

$(PROJ)_syntb.vcd: $(PROJ)_syntb
	vvp -N $< +vcd=$@

# Programming and utilization report
prog: $(PROJ).bin
	@echo
	@echo "=== FPGA Resource Utilization (from yosys synthesis) ==="
	@yosys -p 'read_verilog -sv $(SRCS); synth_ice40 -top $(PROJ) -json /dev/null; stat' 2>&1 | awk '/=== $(PROJ) ===/,/End of script/' || echo "(no synthesis data)"
	@echo "--------------------------------------------------------"
	@echo
	@echo "=== FPGA Resource Utilization (from nextpnr place/route) ==="
	@grep -A20 -E "Device utilisation" $(PROJ)_pnr.rpt 2>/dev/null || echo "(no place/route data)"
	@echo "------------------------------------------------------------"
	@echo
	@echo "Programming FPGA..."
	iceprog $(PROJ).bin


sudo-prog: $(PROJ).bin
	@echo 'Executing prog as root!!!'
	sudo iceprog $<

clean:
	rm -f $(PROJ).yslog $(PROJ).nplog $(PROJ).json $(PROJ).asc $(PROJ).rpt $(PROJ).bin
	rm -f $(PROJ)_tb $(PROJ)_tb.vcd $(PROJ)_syn.v $(PROJ)_syntb $(PROJ)_syntb.vcd
	rm -f $(PROJ)_util.txt $(PROJ)_pnr.rpt
	rm -f simv tb_top.vcd .DS_Store

.SECONDARY:
.PHONY: all prog clean



# PROJ = top

# # List all Verilog source files here
# SRCS = top.v \
# 	   bram_sp.v \
#        seven_seg_ctrl.v \
#        seven_seg_hex.v \
# 	   debounce.v \
# 	   cpu_core.v

# all: $(PROJ).rpt $(PROJ).bin util

# # $(PROJ).json: $(SRCS)
# # 	yosys -ql $(PROJ).yslog -p 'synth_ice40 -top $(PROJ) -json $@; stat' $(SRCS) | tee $(PROJ)_util.txt

# $(PROJ).json: $(SRCS)
# 	yosys -p 'synth_ice40 -top $(PROJ) -json $@' $(SRCS) 2>&1 | tee $(PROJ)_util.txt


# $(PROJ).asc: $(PROJ).json icebreaker.pcf
# 	nextpnr-ice40 -ql $(PROJ).nplog --up5k --package sg48 --freq 12 \
# 		--asc $@ --pcf icebreaker.pcf --json $<

# $(PROJ).bin: $(PROJ).asc
# 	icepack $< $@

# $(PROJ).rpt: $(PROJ).asc
# 	icetime -d up5k -c 12 -mtr $@ $<

# # Resource utilization summary
# util: $(PROJ).json
# 	@echo
# 	@echo "=== FPGA Resource Utilization (from yosys) ==="
# 	@grep -A 20 "=== top ===" $(PROJ)_util.txt || echo "(no utilization data found)"
# 	@echo "----------------------------------------------"
# 	@echo

# # Simulation (testbench)
# $(PROJ)_tb: $(PROJ)_tb.v $(SRCS)
# 	iverilog -o $@ $^

# $(PROJ)_tb.vcd: $(PROJ)_tb
# 	vvp -N $< +vcd=$@

# # Synthesized netlist (optional)
# $(PROJ)_syn.v: $(PROJ).json
# 	yosys -p 'read_json $^; write_verilog $@'

# $(PROJ)_syntb: $(PROJ)_tb.v $(PROJ)_syn.v
# 	iverilog -o $@ $^ `yosys-config --datdir/ice40/cells_sim.v`

# $(PROJ)_syntb.vcd: $(PROJ)_syntb
# 	vvp -N $< +vcd=$@

# prog: $(PROJ).bin
# 	iceprog $<

# sudo-prog: $(PROJ).bin
# 	@echo 'Executing prog as root!!!'
# 	sudo iceprog $<

# clean:
# 	rm -f $(PROJ).yslog $(PROJ).nplog $(PROJ).json $(PROJ).asc $(PROJ).rpt $(PROJ).bin
# 	rm -f $(PROJ)_tb $(PROJ)_tb.vcd $(PROJ)_syn.v $(PROJ)_syntb $(PROJ)_syntb.vcd $(PROJ)_util.txt

# .SECONDARY:
# .PHONY: all prog clean util
