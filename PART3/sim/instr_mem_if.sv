//////////////////////////////////////////////////////////////////////////////
// instr_mem_if.sv  --  instruction fetch interface watched by the monitor
//////////////////////////////////////////////////////////////////////////////
interface instr_mem_if (input logic clk);
  logic        reset;

  // Instruction memory interface
  logic [31:0] pc;            // instruction memory address
  logic [31:0] instr;         // instruction memory read data

  logic        branch_taken;
  logic [31:0] branch_pc;     // address of the BEQ that is taken

  // Set by the testbench trickbox when the program has finished
  logic        done;
endinterface

