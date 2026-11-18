//////////////////////////////////////////////////////////////////////////////
// instr_gen.sv  --  constrained-random MIPS instruction generator
//
//   instruction           : one MIPS instruction (extends uvm_transaction)
//   instruction_generator : builds a program = setup + random body + trickbox,
//                           and converts it to machine code (memfile.dat)
//   tb_top                : testbench shared by Part 2 and Part 3 (DUT,
//                           generator, reset, trickbox, final-state check);
//                           Part 3 adds its UVM hooks with +define+COVERAGE
//
// Add -ntb_opts uvm to the VCS command line
//////////////////////////////////////////////////////////////////////////////

package mips_instr_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"

  // ------------------------------------------------------------------------
  // Settings
  // ------------------------------------------------------------------------
  parameter int        IMEM_WORDS    = 64;            // size of imem in top.sv
  parameter int        DMEM_WORDS    = 64;            // size of dmem in top.sv
  parameter bit [15:0] MEM_ADDRS [4] = '{16'h10, 16'h14, 16'h18, 16'h1C};
  parameter int        MIN_GAP       = 1;
  parameter int        MAX_GAP       = 4;

  // I_ADDI is only used by the fixed setup template, never randomized
  typedef enum {I_ADD, I_AND, I_LW, I_SW, I_BEQ, I_ADDI} instr_kind_e;


  // ==========================================================================
  // instruction : one MIPS instruction
  // ==========================================================================
  class instruction extends uvm_transaction;
    `uvm_object_utils(instruction)

    rand bit [4:0]    reg_a, reg_b, reg_c;
    rand instr_kind_e opcode;
    rand bit [15:0]   mem_addr;
    rand bit [2:0]    br_offset;  // BEQ: how many instructions to jump over
    rand bit          br_taken;   // BEQ: do we want this branch to be taken?
    bit [15:0]        imm;        // ADDI immediate (for initial values only)

    // ---- Extra information filled in by the generator ----
    bit [4:0]  locked_reg;  // BEQ that is the 2nd instr of a pair must keep reading this reg
    bit        in_pair;     // gap or 2nd instr of a pair (branches must not land here)
    bit        executed;    // 0 if a taken branch jumps over this instruction
    bit        taken;       // BEQ: final outcome
    bit [31:0] pc;          // address of the instruction (filled in by the monitor)
    string     note;        // comment printed in the program listing

    function new(string name = "instruction");
      super.new(name);
    endfunction

    // ---- Constraints ----
    // Only registers $1-$4. LW/SW use $0 as base, so address = mem_addr.
    // ADD/AND read two different registers.
    constraint unique_regs {
      reg_b inside {[1:4]};
      if (opcode == I_LW || opcode == I_SW) reg_a == 0;
      else                                  reg_a inside {[1:4]};
      if (opcode == I_ADD || opcode == I_AND) {
        reg_c inside {[1:4]};
        reg_a != reg_b;
      }
      else reg_c == 0;
    }

    // How often each instruction is picked
    constraint valid_opcode {
      opcode dist {I_ADD := 20, I_AND := 20, I_LW := 20, I_SW := 20, I_BEQ := 20};
    }

    // Never pick an instruction the lab does not allow
    constraint illegal_opcode {
      opcode inside {I_ADD, I_AND, I_LW, I_SW, I_BEQ};
    }

    // Only the 4 chosen data memory addresses
    constraint valid_mem_addr {
      if (opcode == I_LW || opcode == I_SW) mem_addr inside {16'h10, 16'h14, 16'h18, 16'h1C};
      else                                  mem_addr == 0;
    }

    // Branch offset 1..4 
    constraint valid_branch {
      br_offset inside {[1:4]};
    }
    // No constraint on br_taken; it is 50-50 by default
    
    // ---- Which register does this instruction write? (0 = none) ----
    function bit [4:0] dest_reg();
      if (opcode == I_ADD || opcode == I_AND) return reg_c;
      if (opcode == I_LW || opcode == I_ADDI) return reg_b;
      return 0;
    endfunction

    // ---- Assembler: instruction -> 32-bit machine code ----
    function bit [31:0] machine_code();
      case (opcode)
        I_ADD: return {6'b000000, reg_a, reg_b, reg_c, 5'b00000, 6'b100000};
        I_AND: return {6'b000000, reg_a, reg_b, reg_c, 5'b00000, 6'b100100};
        I_LW:  return {6'b100011, reg_a, reg_b, mem_addr};
        I_SW:  return {6'b101011, reg_a, reg_b, mem_addr};
        I_BEQ: return {6'b000100, reg_a, reg_b, 13'b0, br_offset};
        I_ADDI: return {6'b001000, reg_a, reg_b, imm};
      endcase
      return 0;
    endfunction

    // One line: [prefix] machine code, assembly text (e.g. "add $3, $1, $2"), note
    // (prefix lets the caller add its own columns, e.g. index / pc / status)
    function void print_me(string prefix = "");
      string asm_txt;
      case (opcode)
        I_ADD:  asm_txt = $sformatf("add $%0d, $%0d, $%0d",   reg_c, reg_a, reg_b);
        I_AND:  asm_txt = $sformatf("and $%0d, $%0d, $%0d",   reg_c, reg_a, reg_b);
        I_LW:   asm_txt = $sformatf("lw  $%0d, 0x%0h($%0d)",  reg_b, mem_addr, reg_a);
        I_SW:   asm_txt = $sformatf("sw  $%0d, 0x%0h($%0d)",  reg_b, mem_addr, reg_a);
        I_BEQ:  asm_txt = $sformatf("beq $%0d, $%0d, %0d",    reg_a, reg_b, br_offset);
        I_ADDI: asm_txt = $sformatf("addi $%0d, $%0d, 0x%0h", reg_b, reg_a, imm);
        default: asm_txt = "???";
      endcase
      $display("%s%h  %-21s  %s", prefix, machine_code(), asm_txt, note);
    endfunction
  endclass


  // ==========================================================================
  // instruction_generator : builds the whole program
  // ==========================================================================
  class instruction_generator;
    instruction instr_list[$];          // the program (dynamic array)
    bit [31:0]  machine_code_list[];   // the program as machine code

    rand int        pair_percent;      // chance (%) of making a dependent pair
    rand bit [31:0] init_val[4];       // starting values for the 4 data words

    constraint c_pair_percent { pair_percent inside {[30:70]}; }
    constraint c_init_val {
      foreach (init_val[i]) init_val[i] inside {[1:255]};
      unique {init_val};               // all different, so "not taken" is possible
    }

      // End program instruction template: lw $0, 0($0) -> end of simulation (last imem word)
    int endsim_idx = instr_list.size();
    int n_pairs;

    // Simple model of the processor, used to make branches taken / not taken.
    // At the end it holds the expected final registers and memory.
    bit [31:0] model_reg [32];
    bit [31:0] model_mem [DMEM_WORDS];
    bit        model_mem_written [DMEM_WORDS];  // 1 = the program stores to this word

    // Add one instruction to the end of the dynamic array
    function void add_instr(instruction t);
      instr_list.push_back(t);
    endfunction

    // Make a fixed (non-random) LW or SW for the setup / trickbox templates
    function instruction make_lw_sw(instr_kind_e opcode, bit [4:0] reg_b, bit [15:0] addr, string note);
      instruction t = new("template");
      t.opcode   = opcode;
      t.reg_a    = 0;
      t.reg_b    = reg_b;
      t.reg_c    = 0;
      t.mem_addr = addr;
      t.note     = note;
      return t;
    endfunction

    // Make a fixed ADDI: rt = rs + sign_extend(imm)
    function instruction make_addi(bit [4:0] rt, bit [4:0] rs, bit [15:0] imm, string note);
      instruction t = new("template");
      t.opcode   = I_ADDI;
      t.reg_a    = rs;
      t.reg_b    = rt;
      t.reg_c    = 0;
      t.mem_addr = 0;
      t.imm      = imm;
      t.note     = note;
      return t;
    endfunction

    // ------------------------------------------------------------------------
    // 1) One random instruction, added to the end of instr_list
    // ------------------------------------------------------------------------
    function void generate_individual(bit allow_branch = 1);
      instruction t = new("individual");
      if (allow_branch) begin
        assert(t.randomize())
          else `uvm_fatal("GEN", "randomize() of individual instruction failed")
      end
      else begin
        assert(t.randomize() with { opcode != I_BEQ; })
          else `uvm_fatal("GEN", "randomize() of individual instruction failed")
      end
      instr_list.push_back(t);
    endfunction

    // ------------------------------------------------------------------------
    // 2) A pair of dependent instructions with a random gap between them
    //    - register dependency: ADD/AND/LW writes $x, then ADD/AND/SW/BEQ reads $x
    //    - memory dependency  : SW to an address, then LW from the same address
    // ------------------------------------------------------------------------
    function void generate_pairs();
      instruction txn1     = new("pair_first");
      instruction txn2     = new("pair_second");
      int         gap      = $urandom_range(MIN_GAP, MAX_GAP);
      bit         mem_dep  = ($urandom_range(0, 9) < 5);    // 50% memory, 50% register
      bit [4:0]   dep_reg  = 0;
      bit [15:0]  dep_addr = 0;

      if (!mem_dep) begin
        assert(txn1.randomize() with { opcode inside {I_ADD, I_AND, I_LW}; })
          else `uvm_fatal("GEN", "randomize() of pair (first) failed")
        dep_reg = txn1.dest_reg();

        assert(txn2.randomize() with {
                 opcode inside {I_ADD, I_AND, I_SW, I_BEQ};
                 if (opcode == I_SW) reg_b == dep_reg;          // store the new value
                 else                (reg_a == dep_reg || reg_b == dep_reg); })
          else `uvm_fatal("GEN", "randomize() of pair (second) failed")

        if (txn2.opcode == I_BEQ) txn2.locked_reg = dep_reg;
        txn2.note = $sformatf("pair %0d: uses $%0d, gap %0d", n_pairs, dep_reg, gap);
      end
      else begin
        assert(txn1.randomize() with { opcode == I_SW; })
          else `uvm_fatal("GEN", "randomize() of pair (first) failed")
        dep_addr = txn1.mem_addr;

        assert(txn2.randomize() with { opcode == I_LW; mem_addr == dep_addr; })
          else `uvm_fatal("GEN", "randomize() of pair (second) failed")

        txn2.note = $sformatf("pair %0d: uses mem 0x%0h, gap %0d", n_pairs, dep_addr, gap);
      end

      txn1.note    = $sformatf("pair %0d: first", n_pairs);
      txn2.in_pair = 1;

      add_instr(txn1);
      insert_gaps(gap, mem_dep, dep_reg, dep_addr);
      add_instr(txn2);
      n_pairs++;
    endfunction

    // ------------------------------------------------------------------------
    // 3) Gap: `gap` random instructions placed between the pair.
    //    They must not break the dependency (no branch, don't overwrite the
    //    register / memory word the pair is using).
    // ------------------------------------------------------------------------
    function void insert_gaps(int gap, bit mem_dep, bit [4:0] dep_reg, bit [15:0] dep_addr);
      instruction t;
      for (int g = 0; g < gap; g++) begin
        t = new("gap");
        assert(t.randomize() with {
                 opcode != I_BEQ;
                 if (!mem_dep) {
                   !((opcode == I_ADD || opcode == I_AND) && reg_c == dep_reg);
                   !(opcode == I_LW && reg_b == dep_reg);
                 } else {
                   !(opcode == I_SW && mem_addr == dep_addr);
                 } })
          else `uvm_fatal("GEN", "randomize() of gap instruction failed")
        t.in_pair = 1;
        t.note    = $sformatf("pair %0d: gap", n_pairs);
        add_instr(t);
      end
    endfunction

    // ------------------------------------------------------------------------
    // 4) Whole program: setup + random body + end_program_inst
    // ------------------------------------------------------------------------
    function void generate_sequence();
      int n_skip;
      int room;                          // free words left before the end_program_inst

      n_pairs    = 0;

      // Setup: write the 4 literals into $1..$4 and into data memory
      // (start of program), for i = 1..4:
      //       addi $i, $0, <init_val>
      //       sw   $i, <0x10/0x14/0x18/0x1C>($0)   -> registers AND memory initialized
      for (int i = 0; i < 4; i++) begin
        add_instr(make_addi(i + 1, 0, init_val[i][15:0], "setup: literal"));
        add_instr(make_lw_sw(I_SW, i + 1, MEM_ADDRS[i], "setup: write literal to mem"));
      end

      // Random body: fill every word up to the end_program_inst (word 63).
      // room = free words left before the trickbox (updated after every add).
      //  - A pair is at most 2 + MAX_GAP words and may end with a BEQ, so it
      //    needs 3 + MAX_GAP words of room (1 left over to jump over).
      //  - A BEQ needs at least 1 instruction after it, so it needs 2 words.
      //    The last body word is therefore never a BEQ.
      room = IMEM_WORDS - 1 - instr_list.size();
      while (room > 0) begin
        if (room >= 3 + MAX_GAP && $urandom_range(0, 99) < pair_percent)
          generate_pairs();
        else
          generate_individual(room >= 2);
        room = IMEM_WORDS - 1 - instr_list.size();

        // A BEQ jumps over br_offset instructions. Fill that space with single
        // instructions so the target is always safe and the random offset is kept.
        // The space may hold another BEQ (gives BEQ -> BEQ order); that BEQ then
        // needs its own br_offset single instructions after it, so n_skip grows.
        // Near the end the space is cut short; pick_branch_offset() then picks
        // an offset that still lands inside the program.
        n_skip = 0;
        if (instr_list[instr_list.size() - 1].opcode == I_BEQ)
          n_skip = instr_list[instr_list.size() - 1].br_offset;
        while (n_skip > 0 && room > 0) begin
          generate_individual(room >= 2);
          room = IMEM_WORDS - 1 - instr_list.size();
          n_skip--;
          if (instr_list[instr_list.size() - 1].opcode == I_BEQ &&
              instr_list[instr_list.size() - 1].br_offset > n_skip)
            n_skip = instr_list[instr_list.size() - 1].br_offset;
        end
      end

      add_end_program_inst();

      if (instr_list.size() != IMEM_WORDS)
        `uvm_fatal("GEN", $sformatf("program is %0d words, expected %0d",
                                    instr_list.size(), IMEM_WORDS))

      fix_branches();
    endfunction

    // End program instruction: one instruction
    //       lw $0, 0($0)          <- destination register is $0
    // The testbench ends the test as soon as any valid instruction writes back with $0 as its destination.
    function void add_end_program_inst();
      add_instr(make_lw_sw(I_LW, 0, 16'h0, "End of program instruction: dest $0 -> END OF TEST"));
    endfunction

    // ------------------------------------------------------------------------
    // 5) Fix branches so taken / not-taken really happens.
    //    We "run" the program on a simple model of the processor. For each BEQ
    //    that is executed we choose reg_a/reg_b using the current register values:
    //      taken     -> two registers with the same value
    //      not taken -> two registers with different values
    // ------------------------------------------------------------------------
    function void fix_branches();
      int skip_until = 0;    // instructions before this index are jumped over
      instruction t;

      // Model starts with registers and data memory all zero.  The hardware
      // dmem is not initialized (X), so only words the program stores to
      // (model_mem_written) are compared at the end.  The setup writes the literals.
      foreach (model_reg[r]) model_reg[r] = 0;
      foreach (model_mem[w]) begin model_mem[w] = 0; model_mem_written[w] = 0; end

      for (int i = 0; i < instr_list.size(); i++) begin
        t = instr_list[i];
        if (t.opcode == I_BEQ) pick_branch_offset(i, t);

        t.executed = (i >= skip_until);
        if (!t.executed) continue;

        case (t.opcode)
          I_ADD: model_reg[t.reg_c] = model_reg[t.reg_a] + model_reg[t.reg_b];
          I_AND: model_reg[t.reg_c] = model_reg[t.reg_a] & model_reg[t.reg_b];
          I_LW:  model_reg[t.reg_b] = model_mem[mem_index(t)];
          I_SW:  begin
                   model_mem[mem_index(t)]         = model_reg[t.reg_b];
                   model_mem_written[mem_index(t)] = 1;
                 end
          I_ADDI: model_reg[t.reg_b] = model_reg[t.reg_a] + {{16{t.imm[15]}}, t.imm};
          I_BEQ: begin
            pick_branch_regs(t);
            if (t.taken) skip_until = i + 1 + t.br_offset;
          end
        endcase
        model_reg[0] = 0;                          // $0 is hardwired to zero
      end
    endfunction

    // dmem word used by LW/SW: base + sign-extended offset, bits [7:2] (like dmem)
    function int mem_index(instruction t);
      bit [31:0] ea = model_reg[t.reg_a] + {{16{t.mem_addr[15]}}, t.mem_addr};
      return ea[7:2];
    endfunction

    // Target must be inside the program and must not land in the middle of a
    // pair (that would skip the pair's first instruction).
    function void pick_branch_offset(int i, instruction t);
      int off, target;
      for (int k = 0; k < 4; k++) begin
        off    = ((t.br_offset - 1 + k) % 4) + 1;     // try the random offset first
        target = i + 1 + off;
	if (target <= endsim_idx && !instr_list[target].in_pair) begin
          t.br_offset = off;
          return;
        end
      end
      // No safe target: keep offset 1 and make the branch not taken
      t.br_offset = 1;
      t.br_taken  = 0;
    endfunction

    // Collect every register that gives the wanted outcome and pick one at
    // random, so reg_b is spread evenly over $1..$4 (no bias to a high/low reg).
    function void pick_branch_regs(instruction t);
      bit [4:0] a, b;
      bit [4:0] cand[$];                           // registers that give the wanted outcome

      if (t.locked_reg != 0) a = t.locked_reg;   // must keep the pair's register
      else                   a = t.reg_a;

      for (int r = 1; r <= 4; r++)
        if (t.br_taken ? (model_reg[r] == model_reg[a])     // taken: same value (includes a)
                       : (model_reg[r] != model_reg[a]))    // not taken: different value
          cand.push_back(r);

      if (cand.size() == 0) begin                  // not taken impossible: all 4 regs equal
        b       = a;
        t.taken = 1;
      end
      else begin
        b       = cand[$urandom_range(0, cand.size() - 1)];
        t.taken = t.br_taken;
      end

      // Put the two registers in random slots (the pair's register may be in
      // either reg_a or reg_b; the BEQ still reads it)
      if ($urandom_range(0, 1)) begin t.reg_a = a; t.reg_b = b; end
      else                      begin t.reg_a = b; t.reg_b = a; end
    endfunction

    // ------------------------------------------------------------------------
    // 6) Main function called by the testbench:
    //    generate the program, then write memfile.dat (all
    //    64 words are used).  Data memory literals are written by the program itself.
    // ------------------------------------------------------------------------
    function void generate_machine_code();
      bit [31:0] imem_image [IMEM_WORDS];

      assert(this.randomize())
        else `uvm_fatal("GEN", "randomize() of instruction_generator failed")
      generate_sequence();

      // imem_image is a bit array, so unused words already start as 0 (NOP)
      machine_code_list = new[instr_list.size()];
      foreach (instr_list[i]) begin
        machine_code_list[i] = instr_list[i].machine_code();
        imem_image[i]        = machine_code_list[i];
      end

      $writememh("memfile.dat", imem_image);
    endfunction

    // ------------------------------------------------------------------------
    // 7) Print the program
    // ------------------------------------------------------------------------
    function void display_all();
      string status;
      instruction t;

      $display("\n================= Generated MIPS program =================");
      $display(" idx  pc    status      machine   assembly               note");
      foreach (instr_list[i]) begin
        t = instr_list[i];
        if (!t.executed)            status = "skipped";
        else if (t.opcode != I_BEQ) status = "";
        else if (t.taken)           status = "TAKEN";
        else                        status = "not-taken";
        t.print_me($sformatf("%4d  %4h  %-10s  ", i, i * 4, status));
      end
      $display(" %0d instructions, %0d dependent pairs", instr_list.size(), n_pairs);
      $display(" Setup writes: [0x10]=%0h [0x14]=%0h [0x18]=%0h [0x1C]=%0h",
               init_val[0], init_val[1], init_val[2], init_val[3]);
      $display(" Expected end: $1=%0h $2=%0h $3=%0h $4=%0h",
               model_reg[1], model_reg[2], model_reg[3], model_reg[4]);
      $display("==========================================================\n");
    endfunction
  endclass

endpackage


// ============================================================================
// tb_top : shared by Part 2 and Part 3 (named tb_top because the DUT module is
// already called "top")
//  1. Create the instruction generator and generate a random program
//  2. Load the program (memfile.dat) into instruction memory ($readmemh).
//     Data memory is not loaded: the program writes its own literals
//  3. Deassert reset -> the MIPS processor starts fetching
//  4. Trickbox: when a valid instruction with $0 as its destination reaches
//     writeback (lw $0, 0($0)), check the final state and end the test
//
// Part 2 (default)      : prints a fetch trace, ends with $finish
// Part 3 (+define+COVERAGE, also compile part3/instr_mem_if.sv and
//         part3/coverage_collector.sv):
//                         drives the instr_mem_if interface for the monitor,
//                         puts it in the resource db, calls run_test("my_test")
//                         and ends by setting vif.done (the test then drops
//                         its objection, so UVM writes the coverage report)
// ============================================================================
module tb_top;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import mips_instr_pkg::*;

  logic        clk;
  logic        reset;
  logic [31:0] writedata, dataadr;
  logic        memwrite;
  bit          done = 0;               // set by the trickbox

  instruction_generator gen;

  // DUT
  top dut (.clk(clk), .reset(reset), .writedata(writedata),
           .dataadr(dataadr), .memwrite(memwrite));

  // Clock: 10 ns period
  initial clk = 0;
  always #5 clk = ~clk;

`ifdef COVERAGE
  // --------------------------------------------------------------------------
  // Part 3: instruction fetch interface (watched by the monitor), resource db
  // and run_test(). run_test() must be called at time 0, so it has its own
  // initial block.
  // --------------------------------------------------------------------------
  instr_mem_if vif (clk);
  assign vif.reset        = reset;
  assign vif.pc           = dut.pc;
  assign vif.instr        = dut.instr;
  assign vif.branch_taken = dut.mips.dp.E_chgPC;
  assign vif.branch_pc    = dut.mips.dp.E_pcplus4 - 4;
  assign vif.done         = done;

  initial begin
    // Scope "*" = visible to every component; read with read_by_name("vif")
    uvm_resource_db #(virtual instr_mem_if)::set("*", "vif", vif);
    run_test("my_test");
  end
`endif

  // --------------------------------------------------------------------------
  // Generate the program, load instruction memory, release reset
  // --------------------------------------------------------------------------
  initial begin
    reset = 1;

    gen = new();
    gen.generate_machine_code(); // writes memfile.dat
    gen.display_all();

    #1;                          // wait for imem's own initial block to finish
    $readmemh("memfile.dat", dut.imem.RAM);
    `uvm_info("TB", "Loaded memfile.dat into imem", UVM_LOW)

    @(negedge clk);
    reset = 0;
    `uvm_info("TB", "Reset deasserted, processor is running", UVM_LOW)
  end

`ifndef COVERAGE
  // --------------------------------------------------------------------------
  // Part 2: print every instruction fetch (Part 3's monitor prints executed
  // instructions instead)
  // --------------------------------------------------------------------------
  int cycle = 0;
  always @(negedge clk) begin
    if (!reset) begin
      $display("[%0t] cycle %0d: FETCH pc=%h instr=%h", $time, cycle, dut.pc, dut.instr);
      cycle++;
    end
  end
`endif

  // --------------------------------------------------------------------------
  // Trickbox: watch the writeback stage (XMR into the DUT).  Any valid
  // instruction writing back with destination $0 ends the test.  NOPs and
  // flushed/bubbled instructions have WB_valid = 0, so they never trigger it.
  // --------------------------------------------------------------------------
  always @(negedge clk) begin
    if (!reset && !done && dut.mips.dp.WB_valid === 1 &&
        dut.mips.dp.WB_regwrite === 1 && dut.mips.dp.WB_dest === 5'd0) begin
      $display("\n[TRICKBOX] Instruction with destination $0 reached writeback. Simulation ending.");
      // Every older instruction has already written back, so check now
      check_final_state();
      done = 1;
`ifndef COVERAGE
      $finish;                   // Part 3: my_test sees vif.done and ends UVM
`endif
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
    `uvm_fatal("TB", "TIMEOUT: trickbox was never reached")
  end

  // --------------------------------------------------------------------------
  // Waveform dump for Verdi
  // --------------------------------------------------------------------------
  initial begin
    $fsdbDumpfile("novas.fsdb");
    $fsdbDumpvars(0, tb_top);
  end

endmodule
