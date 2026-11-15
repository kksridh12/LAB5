//////////////////////////////////////////////////////////////////////////////
// tb_top.sv  --  Lab 5 Part 2 testbench
//
//  1. Create the instruction generator and generate a random program
//  2. Load the program (memfile.dat) into instruction memory ($readmemh) and
//     write the starting data (dmemfile.dat) through dmem's write port
//  3. Deassert reset -> the MIPS processor starts fetching
//  4. Trickbox: when the processor writes 0xDEADBEEF to address 0xFC,
//     print a message and call $finish
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

  // Used to load the starting data memory (see the initial block below)
  logic [31:0] dmem_init [0:63];
  logic [31:0] init_addr, init_data;

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
    gen.generate_program();      // writes memfile.dat and dmemfile.dat
    gen.display_all();

    #1;                          // wait for imem's own initial block to finish
    $readmemh("memfile.dat",  dut.imem.RAM);
    `uvm_info("TB", "Loaded memfile.dat into imem", UVM_LOW)

    // dmem.RAM is written by an always_ff in top.sv, so the TB is not allowed
    // to write it directly (VCS error ICPD). Instead, while the processor is
    // held in reset, we drive dmem's own write port and write every word.
    $readmemh("dmemfile.dat", dmem_init);
    init_addr = 0;
    init_data = dmem_init[0];
    force dut.dmem.we = 1'b1;
    force dut.dmem.a  = init_addr;
    force dut.dmem.wd = init_data;
    for (int w = 0; w < DMEM_WORDS; w++) begin
      @(negedge clk);            // change address/data away from the clock edge
      init_addr = w * 4;
      init_data = dmem_init[w];
    end
    @(negedge clk);              // last word is written on the posedge before this
    release dut.dmem.we;
    release dut.dmem.a;
    release dut.dmem.wd;
    `uvm_info("TB", "Loaded dmemfile.dat into dmem through its write port", UVM_LOW)

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
  // Trickbox: watch the data memory write port (XMR into the DUT)
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

