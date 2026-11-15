//////////////////////////////////////////////////////////////////////////////
// tb_top.sv  --  Lab 5 Part 3 testbench (functional coverage)
//
//  1. Generate a random program with the Part 2 instruction generator
//  2. Load instruction memory ($readmemh) and data memory (through dmem's
//     write port, because dmem.RAM is written by an always_ff)
//  3. Deassert reset and call run_test()
//       instr_test -> instr_env -> instr_monitor -> instr_coverage
//  4. Trickbox: when the processor writes 0xDEADBEEF to address 0xFC,
//     print a message, check the final state and set vif.done.
//     The test then drops its objection and UVM ends the simulation.
//////////////////////////////////////////////////////////////////////////////
module tb_top;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import mips_instr_pkg::*;
  import mips_uvm_pkg::*;

  logic        clk;
  logic        reset;
  logic [31:0] writedata, dataadr;
  logic        memwrite;

  // Used to load the starting data memory
  logic [31:0] dmem_init [0:63];
  logic [31:0] init_addr, init_data;

  instruction_generator gen;

  // DUT
  top dut (.clk(clk), .reset(reset), .writedata(writedata),
           .dataadr(dataadr), .memwrite(memwrite));

  // Instruction fetch interface for the monitor
  instr_mem_if vif (clk);
  assign vif.reset        = reset;
  assign vif.pc           = dut.pc;
  assign vif.instr        = dut.instr;
  assign vif.branch_taken = dut.mips.dp.E_chgPC;
  assign vif.branch_pc    = dut.mips.dp.E_pcplus4 - 4;

  // Clock: 10 ns period
  initial clk = 0;
  always #5 clk = ~clk;

  // --------------------------------------------------------------------------
  // Generate the program, load memories, release reset, start UVM
  // --------------------------------------------------------------------------
  initial begin
    reset    = 1;
    vif.done = 0;
    uvm_config_db #(virtual instr_mem_if)::set(null, "*", "vif", vif);

    gen = new();
    gen.generate_program();      // writes memfile.dat and dmemfile.dat
    gen.display_all();

    // Start the UVM run phase at time zero without blocking the rest of the
    // setup sequence (memory load / reset release).
    fork
      run_test("instr_test");
    join_none

    #1;                          // wait for imem's own initial block to finish
    $readmemh("memfile.dat", dut.imem.RAM);

    // Write the starting data memory through dmem's write port (in reset)
    $readmemh("dmemfile.dat", dmem_init);
    init_addr = 0;
    init_data = dmem_init[0];
    force dut.dmem.we = 1'b1;
    force dut.dmem.a  = init_addr;
    force dut.dmem.wd = init_data;
    for (int w = 0; w < DMEM_WORDS; w++) begin
      @(negedge clk);
      init_addr = w * 4;
      init_data = dmem_init[w];
    end
    @(negedge clk);
    release dut.dmem.we;
    release dut.dmem.a;
    release dut.dmem.wd;

    @(negedge clk);
    reset = 0;
    `uvm_info("TB", "Reset deasserted, processor is running", UVM_LOW)
  end

  // --------------------------------------------------------------------------
  // Trickbox: watch the data memory write port
  // --------------------------------------------------------------------------
  always @(negedge clk) begin
    if (!reset && dut.dmem.we === 1 &&
        dut.dmem.a  === TRICKBOX_ADDR &&
        dut.dmem.wd === TRICKBOX_DATA) begin
      $display("\n[TRICKBOX] Address %h was written to, with data %h. Simulation ending.",
               dut.dmem.a, dut.dmem.wd);
      @(posedge clk);            // let the instruction before the SW write back
      #1;
      check_final_state();
      vif.done = 1;              // test drops its objection -> end of simulation
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
    for (int w = 0; w < DMEM_WORDS; w++)
      if (dut.dmem.RAM[w] !== gen.model_mem[w]) begin
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
    `uvm_fatal("TB", "TIMEOUT: trickbox was never written")
  end

  // --------------------------------------------------------------------------
  // Waveform dump for Verdi
  // --------------------------------------------------------------------------
  initial begin
    $fsdbDumpfile("novas.fsdb");
    $fsdbDumpvars(0, tb_top);
  end

endmodule

