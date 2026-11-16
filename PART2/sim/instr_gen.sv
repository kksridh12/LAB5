//////////////////////////////////////////////////////////////////////////////
// instr_gen.sv  --  Lab 5 Part 2: constrained-random MIPS instruction generator
//
//   instruction           : one MIPS instruction (extends uvm_transaction)
//   instruction_generator : builds a program = setup + random body + trickbox,
//                           converts it to machine code (memfile.dat) and
//                           writes the initial data memory (dmemfile.dat)
//   testbench             : small stand-alone module that only runs the
//                           generator (the real testbench is tb_top.sv)
//
// Instruction fields:
//   opcode   : ADD, AND, LW, SW or BEQ
//   reg_a    : ADD/AND: source 1 | LW/SW: base ($0) | BEQ: compare reg 1
//   reg_b    : ADD/AND: source 2 | LW: dest | SW: data | BEQ: compare reg 2
//   reg_c    : ADD/AND: destination
//   mem_addr : LW/SW address
//
// Lab limits (every generated instruction follows them):
//   instructions : ADD, AND, LW, SW, BEQ
//   registers    : $1, $2, $3, $4      ($0 is only used as the LW/SW base)
//   data memory  : 0x10, 0x14, 0x18, 0x1C
//   gaps         : 1..4 instructions between a dependent pair
//   BEQ offsets  : 1..4 (forward)
//
// We only have 5 instructions (no ADDI), so the registers are initialized by
// LW from a data memory that the testbench pre-loads from dmemfile.dat.
//
// Trickbox (end of simulation):
//   0xF8 is pre-loaded with 0xDEADBEEF.  The last two instructions are
//       lw $1, 0xf8($0)
//       sw $1, 0xfc($0)     <- testbench sees this write and ends the test
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
  parameter bit [15:0] MARKER_ADDR   = 16'hF8;        // holds TRICKBOX_DATA
  parameter bit [15:0] TRICKBOX_ADDR = 16'hFC;        // trickbox location
  parameter bit [31:0] TRICKBOX_DATA = 32'hDEADBEEF;
  parameter int        MIN_GAP       = 1;
  parameter int        MAX_GAP       = 4;
  parameter int        MAX_BODY      = 45;            // max random instructions (fits in 64-word imem)

  typedef enum {I_ADD, I_AND, I_LW, I_SW, I_BEQ} instr_kind_e;


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
    // Only registers $1..$4. LW/SW use $0 as base, so address = mem_addr.
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

    // Branch offset 1..4 (br_taken is 50-50 by default)
    constraint valid_branch {
      br_offset inside {[1:4]};
    }

    // ---- Which register does this instruction write? (0 = none) ----
    function bit [4:0] dest_reg();
      if (opcode == I_ADD || opcode == I_AND) return reg_c;
      if (opcode == I_LW)                     return reg_b;
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
      endcase
      return 0;
    endfunction

    // ---- Assembly text, e.g. "add $3, $1, $2" ----
    virtual function string convert2string();
      case (opcode)
        I_ADD: return $sformatf("add $%0d, $%0d, $%0d", reg_c, reg_a, reg_b);
        I_AND: return $sformatf("and $%0d, $%0d, $%0d", reg_c, reg_a, reg_b);
        I_LW:  return $sformatf("lw  $%0d, 0x%0h($%0d)", reg_b, mem_addr, reg_a);
        I_SW:  return $sformatf("sw  $%0d, 0x%0h($%0d)", reg_b, mem_addr, reg_a);
        I_BEQ: return $sformatf("beq $%0d, $%0d, %0d",   reg_a, reg_b, br_offset);
      endcase
      return "???";
    endfunction

    function void print_me();
      $display("%h  %-21s  %s", machine_code(), convert2string(), note);
    endfunction
  endclass


  // ==========================================================================
  // instruction_generator : builds the whole program
  // ==========================================================================
  class instruction_generator;
    instruction instr_list[];          // the program (dynamic array)
    bit [31:0]  machine_code_list[];   // the program as machine code

    rand int        num_body;          // how many random instructions
    rand int        pair_percent;      // chance (%) of making a dependent pair
    rand bit [31:0] init_val[4];       // starting values for the 4 data words

    constraint c_num_body     { num_body inside {[20:MAX_BODY]}; }
    constraint c_pair_percent { pair_percent inside {[30:70]}; }
    constraint c_init_val {
      foreach (init_val[i]) init_val[i] inside {[1:255]};
      unique {init_val};               // all different, so "not taken" is possible
    }

    int teardown_idx;                  // index of the first trickbox instruction
    int n_pairs;

    // Simple model of the processor, used to make branches taken / not taken.
    // At the end it holds the expected final registers and memory.
    bit [31:0] model_reg [32];
    bit [31:0] model_mem [DMEM_WORDS];

    // Add one instruction to the end of the dynamic array
    function void add_instr(instruction t);
      instr_list = new[instr_list.size() + 1](instr_list);
      instr_list[instr_list.size() - 1] = t;
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

    // ------------------------------------------------------------------------
    // 1) One random instruction, added to the end of instr_list
    // ------------------------------------------------------------------------
    function void generate_individual(bit allow_branch = 1);
      int i = instr_list.size();
      instr_list    = new[i + 1](instr_list);
      instr_list[i] = new("individual");
      if (allow_branch) begin
        assert(instr_list[i].randomize())
          else `uvm_fatal("GEN", "randomize() of individual instruction failed")
      end
      else begin
        assert(instr_list[i].randomize() with { opcode != I_BEQ; })
          else `uvm_fatal("GEN", "randomize() of individual instruction failed")
      end
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
      bit         mem_dep  = ($urandom_range(0, 9) < 3);    // 30% memory, 70% register
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
    // 4) Whole program: setup + random body + trickbox
    // ------------------------------------------------------------------------
    function void generate_sequence();
      int body_count = 0;
      int size_before;
      int n_skip;

      instr_list = new[0];
      n_pairs    = 0;

      // Setup template: load $1..$4 from the 4 data words
      for (int i = 0; i < 4; i++)
        add_instr(make_lw_sw(I_LW, i + 1, MEM_ADDRS[i], "setup"));

      // Random body: mix of single instructions and dependent pairs
      while (body_count < num_body) begin
        size_before = instr_list.size();
        if ($urandom_range(0, 99) < pair_percent)
          generate_pairs();
        else
          generate_individual();

        // A BEQ jumps over br_offset instructions. Fill that space with single
        // instructions so the target is always safe and the random offset is kept.
        // The space may hold another BEQ (gives BEQ -> BEQ order); that BEQ then
        // needs its own br_offset single instructions after it, so n_skip grows.
        // Near the size limit no more BEQs are added, so the program fits in imem.
        n_skip = 0;
        if (instr_list[instr_list.size() - 1].opcode == I_BEQ)
          n_skip = instr_list[instr_list.size() - 1].br_offset;
        while (n_skip > 0) begin
          generate_individual(instr_list.size() < MAX_BODY);
          n_skip--;
          if (instr_list[instr_list.size() - 1].opcode == I_BEQ &&
              instr_list[instr_list.size() - 1].br_offset > n_skip)
            n_skip = instr_list[instr_list.size() - 1].br_offset;
        end

        body_count += instr_list.size() - size_before;
      end

      // A branch just before the trickbox would have nowhere legal to jump
      if (instr_list[instr_list.size() - 1].opcode == I_BEQ)
        generate_individual(0);

      // Trickbox template: write 0xDEADBEEF to 0xFC -> end of simulation
      teardown_idx = instr_list.size();
      add_instr(make_lw_sw(I_LW, 1, MARKER_ADDR,   "trickbox: load 0xDEADBEEF"));
      add_instr(make_lw_sw(I_SW, 1, TRICKBOX_ADDR, "trickbox: END OF TEST"));

      if (instr_list.size() > IMEM_WORDS)
        `uvm_fatal("GEN", "program is bigger than the instruction memory")

      fix_branches();
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

      // Model starts like the real hardware after the TB loads dmemfile.dat
      foreach (model_reg[r]) model_reg[r] = 0;
      foreach (model_mem[w]) model_mem[w] = 0;
      for (int i = 0; i < 4; i++) model_mem[MEM_ADDRS[i] >> 2] = init_val[i];
      model_mem[MARKER_ADDR >> 2] = TRICKBOX_DATA;

      for (int i = 0; i < instr_list.size(); i++) begin
        t = instr_list[i];
        if (t.opcode == I_BEQ) pick_branch_offset(i, t);

        t.executed = (i >= skip_until);
        if (!t.executed) continue;

        case (t.opcode)
          I_ADD: model_reg[t.reg_c] = model_reg[t.reg_a] + model_reg[t.reg_b];
          I_AND: model_reg[t.reg_c] = model_reg[t.reg_a] & model_reg[t.reg_b];
          I_LW:  model_reg[t.reg_b] = model_mem[t.mem_addr >> 2];
          I_SW:  model_mem[t.mem_addr >> 2] = model_reg[t.reg_b];
          I_BEQ: begin
            pick_branch_regs(t);
            if (t.taken) skip_until = i + 1 + t.br_offset;
          end
        endcase
      end
    endfunction

    // Target must be inside the program and must not land in the middle of a
    // pair (that would skip the pair's first instruction).
    function void pick_branch_offset(int i, instruction t);
      int off, target;
      for (int k = 0; k < 4; k++) begin
        off    = ((t.br_offset - 1 + k) % 4) + 1;     // try the random offset first
        target = i + 1 + off;
        if (target <= teardown_idx && !instr_list[target].in_pair) begin
          t.br_offset = off;
          return;
        end
      end
      // No safe target: keep offset 1 and make the branch not taken
      t.br_offset = 1;
      t.br_taken  = 0;
    endfunction

    function void pick_branch_regs(instruction t);
      bit [4:0] a;
      if (t.locked_reg != 0) a = t.locked_reg;   // must keep the pair's register
      else                   a = t.reg_a;

      t.reg_a = a;
      if (t.br_taken) begin
        t.reg_b = a;                               // same register -> always equal
        for (int r = 1; r <= 4; r++)               // prefer another reg with same value
          if (r != a && model_reg[r] == model_reg[a]) t.reg_b = r;
        t.taken = 1;
      end
      else begin
        t.reg_b = a;
        t.taken = 1;                               // in case all 4 regs are equal
        for (int r = 1; r <= 4; r++)
          if (model_reg[r] != model_reg[a]) begin
            t.reg_b = r;
            t.taken = 0;
          end
      end
    endfunction

    // ------------------------------------------------------------------------
    // 6) Main function called by the testbench:
    //    generate the program, then write memfile.dat (padded with NOPs to
    //    64 words) and dmemfile.dat
    // ------------------------------------------------------------------------
    function void generate_machine_code();
      bit [31:0] imem_image [IMEM_WORDS];

      assert(this.randomize())
        else `uvm_fatal("GEN", "randomize() of instruction_generator failed")
      generate_sequence();

      machine_code_list = new[instr_list.size()];
      foreach (instr_list[i]) machine_code_list[i] = instr_list[i].machine_code();

      foreach (imem_image[i]) imem_image[i] = 0;
      foreach (machine_code_list[i]) imem_image[i] = machine_code_list[i];

      $writememh("memfile.dat", imem_image);
      generate_data_memory();
    endfunction

    // Initial data memory -> dmemfile.dat
    function void generate_data_memory();
      bit [31:0] dmem_image [DMEM_WORDS];

      foreach (dmem_image[i]) dmem_image[i] = 0;
      for (int i = 0; i < 4; i++) dmem_image[MEM_ADDRS[i] >> 2] = init_val[i];
      dmem_image[MARKER_ADDR >> 2] = TRICKBOX_DATA;

      $writememh("dmemfile.dat", dmem_image);
    endfunction

    // ------------------------------------------------------------------------
    // 7) Print the program
    // ------------------------------------------------------------------------
    function void display_all();
      string status;
      instruction t;

      $display("\n================= Generated MIPS program =================");
      $display(" idx  pc    machine   assembly               status      note");
      foreach (instr_list[i]) begin
        t = instr_list[i];
        if (!t.executed)            status = "skipped";
        else if (t.opcode != I_BEQ) status = "";
        else if (t.taken)           status = "TAKEN";
        else                        status = "not-taken";
        $display("%4d  %4h  %8h  %-21s  %-10s  %s",
                 i, i * 4, machine_code_list[i], t.convert2string(), status, t.note);
      end
      $display(" %0d instructions, %0d dependent pairs", instr_list.size(), n_pairs);
      $display(" Initial mem : [0x10]=%0h [0x14]=%0h [0x18]=%0h [0x1C]=%0h",
               init_val[0], init_val[1], init_val[2], init_val[3]);
      $display(" Expected end: $1=%0h $2=%0h $3=%0h $4=%0h",
               model_reg[1], model_reg[2], model_reg[3], model_reg[4]);
      $display("==========================================================\n");
    endfunction
  endclass

endpackage


// ============================================================================
// testbench : runs only the generator (no DUT).
// The full testbench with the processor is tb_top.sv, which also loads the
// memories with $readmemh and deasserts reset.
// ============================================================================
module testbench;
  import mips_instr_pkg::*;

  instruction_generator gen;

  initial begin
    gen = new();
    gen.generate_machine_code();
    gen.display_all();
  end
endmodule

