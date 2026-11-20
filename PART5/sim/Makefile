VCS ?= $(VCS_HOME)/bin/vcs
PYTHON ?= python3
PROGRAM ?= ../programs/program1.dat
TRACE ?= rtl_trace.txt
MAX_CYCLES ?= 100

SV_SRCS := ../../pipeline/top.sv ../../pipeline/controller.sv ../../pipeline/datapath.sv iss_tb.sv

.PHONY: compile sim part5_rtl_all part5_iss_all part5_compare_all part5_all clean

compile:
	$(VCS) -full64 -sverilog -timescale=1ns/1ps -top iss_tb \
		+incdir+../../pipeline $(SV_SRCS) \
		-debug_access+all -kdb -lca -l compile.log

sim:
	./simv +PROGRAM=$(PROGRAM) +TRACE=$(TRACE) +MAX_CYCLES=$(MAX_CYCLES) -l sim.log

part5_rtl_all:
	@set -e; for n in 1 2 3; do \
		$(MAKE) sim PROGRAM=../programs/program$$n.dat TRACE=rtl_program$${n}_trace.txt MAX_CYCLES=55; \
	done

part5_iss_all:
	@set -e; for n in 1 2 3; do \
		cp ../programs/program$$n.txt ../scripts/input.txt; \
		(cd ../scripts && $(PYTHON) Mips_Simulator.py > iss_program$${n}_output.txt); \
	done

part5_compare_all:
	@set -e; for n in 1 2 3; do \
		$(PYTHON) ../scripts/compare_part5.py ../scripts/iss_program$${n}_output.txt rtl_program$${n}_trace.txt; \
	done

part5_all:
	@$(MAKE) part5_rtl_all
	@$(MAKE) part5_iss_all PYTHON=$(PYTHON)
	@$(MAKE) part5_compare_all PYTHON=$(PYTHON)

clean:
	rm -rf simv simv.daidir csrc *.log rtl_trace.txt rtl_program*_trace.txt ucli.key DVEFiles verdiLog