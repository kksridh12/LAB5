//////////////////////////////////////////////////////////////////////////////
// instr_mem_if.sv  --  instruction fetch interface watched by the monitor
//////////////////////////////////////////////////////////////////////////////
interface instr_mem_if (input logic clk);
  logic        reset;

  // Instruction memory interface
  logic [31:0] pc;            // instruction memory address
  logic [31:0] instr;         // instruction memory read data

  // Fetch redirect: a BEQ in the Execute stage is taken. The pipeline then
  // throws away the instructions fetched after the BEQ and fetches the target.
  // (A taken branch with offset 1 or 2 looks just like sequential fetching
  //  on pc alone, so the monitor needs this signal to tell taken/not taken.)
  logic        branch_taken;
  logic [31:0] branch_pc;     // address of the BEQ that is taken

  // Set by the testbench trickbox when the program has finished
  logic        done;
endinterface

