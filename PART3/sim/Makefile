VCS ?= $(VCS_HOME)/bin/vcs
VERDI ?= $(VERDI_HOME)/bin/verdi
SEED ?= 1
SEEDS ?= 1 2 3 4 5 6 7 8 9 10 
UVM_VERBOSITY ?= UVM_MEDIUM

# Part 3 depends on the Part 2 random instruction generator plus the Part 3
# UVM monitor/coverage/environment/testbench sources.
SV_SRCS := \
	../../PART2/sim/instr_gen.sv \
	instr_mem_if.sv \
	coverage_collector.sv \
	../../pipeline/top.sv \
	../../pipeline/controller.sv \
	../../pipeline/datapath.sv

.PHONY: all compile_and_sim compile compile_verdi sim verdi waves gui clean

all: compile_and_sim

# Compile and run the UVM testbench
compile_and_sim:
	$(VCS) -R -full64 -sverilog -timescale=1ns/1ps -ntb_opts uvm \
		-top tb_top +incdir+. +incdir+../../pipeline +incdir+../../PART2/sim $(SV_SRCS) \
		-debug_access+all -kdb -lca +define+COVERAGE +UVM_VERBOSITY=$(UVM_VERBOSITY) \
		+ntb_random_seed=$(SEED) -l sim_$(SEED).log 2>&1 | tee compile_and_sim.log

# Compile without running
compile:
	$(VCS) -full64 -sverilog -timescale=1ns/1ps -ntb_opts uvm \
		-top tb_top +define+COVERAGE +incdir+. +incdir+../../pipeline +incdir+../../PART2/sim $(SV_SRCS) \
		-debug_access+all -lca -l comp.log 2>&1 | tee compile.log

# Compile with the database needed by Verdi
compile_verdi:
	$(VCS) -full64 -sverilog -timescale=1ns/1ps -ntb_opts uvm \
		-top tb_top +incdir+. +incdir+../../pipeline +incdir+../../PART2/sim $(SV_SRCS) \
		+define+COVERAGE -debug_access+all -kdb -lca -l compile_verdi.log

# Run the compiled simulation
sim:
	./simv +UVM_VERBOSITY=$(UVM_VERBOSITY) +ntb_random_seed=$(SEED) -cm_dir cov_$(SEED).vdb -l sim_$(SEED).log

# Launch Verdi, optionally loading the generated waveform database
verdi:
	$(VERDI) -dbdir ./simv.daidir -nologo

waves:
	$(VERDI) -dbdir ./simv.daidir -ssf novas.fsdb -nologo

regress: compile_verdi
	for s in $(SEEDS); do $(MAKE) sim SEED=$$s; done

merge:
	$(VCS_HOME)/bin/urg -dir cov_*.vdb -dbname merged_coverage.vdb

cov:
	$(VERDI_HOME)/bin/verdi -cov -covdir merged_coverage.vdb &

cov_one:
	$(VERDI_HOME)/bin/verdi -cov -covdir cov_$(SEED).vdb &

gui:
	./simv +UVM_VERBOSITY=$(UVM_VERBOSITY) +ntb_random_seed=$(SEED) -gui=verdi

clean:
	rm -rf *.log *.h csrc simv simv.daidir *.vdb *.fsdb ucli.key DVEFiles \
		verdiLog novas.* memfile.dat dmemfile.dat urgReport *.conf *Log



