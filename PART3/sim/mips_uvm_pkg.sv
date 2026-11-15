//////////////////////////////////////////////////////////////////////////////
// mips_uvm_pkg.sv  --  Part 3 UVM components
//////////////////////////////////////////////////////////////////////////////
package mips_uvm_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import mips_instr_pkg::*;     // instruction class (Part 2)

  `include "instr_monitor.sv"
  `include "instr_coverage.sv"
  `include "instr_env.sv"
  `include "instr_test.sv"
endpackage

