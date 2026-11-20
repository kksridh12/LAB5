VCS ?= $(VCS_HOME)/bin/vcs
PROGRAM ?= ../programs/program1.dat
TRACE ?= rtl_trace.txt
MAX_CYCLES ?= 100

SV_SRCS := ../../pipeline/top.sv ../../pipeline/controller.sv ../../pipeline/datapath.sv iss_tb.sv

.PHONY: compile sim clean
compile:
	$(VCS) -full64 -sverilog -timescale=1ns/1ps -top iss_tb \
		+incdir+../../pipeline $(SV_SRCS) \
		-debug_access+all -kdb -lca -l compile.log

sim:
	./simv +PROGRAM=$(PROGRAM) +TRACE=$(TRACE) +MAX_CYCLES=$(MAX_CYCLES) -l sim.log

clean:
	rm -rf simv simv.daidir csrc *.log *.txt ucli.key DVEFiles verdiLog
