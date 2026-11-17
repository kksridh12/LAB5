//////////////////////////////////////////////////////////////////////////////
// tb_top.sv  --  Lab 5 Part 2 testbench
//
//  1. Create the instruction generator and generate a random program
//  2. Load the program (memfile.dat) into instruction memory ($readmemh).
//     Data memory is not loaded: the program writes its own literals
//  3. Deassert reset -> the MIPS processor starts fetching
//  4. Trickbox: when a valid instruction with $0 as its destination reaches
//     writeback (lw $0, 0($0)), print a message and call $finish
//////////////////////////////////////////////////////////////////////////////
module tb_top;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import mips_instr_pkg::*;

  logic        clk;
  logic        reset;
  logic [31:0] writedata, dataadr;
  logic        memwrite;

  int cycle = 0;

  instruction_generator gen;

  // DUT
  top dut (.clk(clk), .reset(reset), .writedata(writedata),
           .dataadr(dataadr), .memwrite(memwrite));

  // Clock: 10 ns period
  initial clk = 0;
  always #5 clk = ~clk;

  // --------------------------------------------------------------------------
  // Generate the program, load memories, release reset
  // --------------------------------------------------------------------------
  initial begin
    reset = 1;

    gen = new();
    gen.generate_machine_code(); // writes memfile.dat
    gen.display_all();

    #1;                          // wait for imem's own initial block to finish
    $readmemh("memfile.dat",  dut.imem.RAM);
    `uvm_info("TB", "Loaded memfile.dat into imem", UVM_LOW)

    @(negedge clk);
    reset = 0;
    `uvm_info("TB", "Reset deasserted, processor is running", UVM_LOW)
  end

  // --------------------------------------------------------------------------
  // Print every instruction fetch
  // --------------------------------------------------------------------------
  always @(negedge clk) begin
    if (!reset) begin
      $display("[%0t] cycle %0d: FETCH pc=%h instr=%h", $time, cycle, dut.pc, dut.instr);
      cycle++;
    end
  end

  // --------------------------------------------------------------------------
  // Trickbox: watch the writeback stage (XMR into the DUT).  Any valid
  // instruction writing back with destination $0 ends the test.  NOPs and
  // flushed/bubbled instructions have WB_valid = 0, so they never trigger it.
  // --------------------------------------------------------------------------
  always @(negedge clk) begin
    if (!reset && dut.mips.dp.WB_valid === 1 && dut.mips.dp.WB_regwrite === 1 &&
        dut.mips.dp.WB_dest === 5'd0) begin
      $display("\n[TRICKBOX] Instruction with destination $0 reached writeback. Simulation ending.");
      // Every older instruction has already written back, so check now
      check_final_state();
      $finish;
    end
  end

  // Compare the DUT's registers and memory with the generator's model
  task automatic check_final_state();
    int errors = 0;
    for (int r = 1; r <= 4; r++)
      if (dut.mips.dp.rf.rf[r] !== gen.model_reg[r]) begin
        `uvm_error("CHECK", $sformatf("$%0d = %h, expected %h",
                                      r, dut.mips.dp.rf.rf[r], gen.model_reg[r]))
        errors++;
      end
    // Only words the program stores to: the rest of dmem is never initialized (X)
    for (int w = 0; w < DMEM_WORDS; w++)
      if (gen.model_mem_written[w] && dut.dmem.RAM[w] !== gen.model_mem[w]) begin
        `uvm_error("CHECK", $sformatf("mem[%h] = %h, expected %h",
                                      w * 4, dut.dmem.RAM[w], gen.model_mem[w]))
        errors++;
      end
    if (errors == 0)
      `uvm_info("CHECK", "PASS: final registers and memory match the expected values", UVM_LOW)
  endtask

  // --------------------------------------------------------------------------
  // Timeout in case the trickbox is never reached
  // --------------------------------------------------------------------------
  initial begin
    #20000;
    `uvm_error("TB", "TIMEOUT: trickbox was never written")
    $finish;
  end

  // --------------------------------------------------------------------------
  // Waveform dump for Verdi
  // --------------------------------------------------------------------------
  initial begin
    $fsdbDumpfile("novas.fsdb");
    $fsdbDumpvars(0, tb_top);
  end

endmodule

