//////////////////////////////////////////////////////////////////////////////
// coverage_collector.sv  --  functional coverage
//
//   instr_monitor  : watches the instruction fetch interface and sends one
//                    instruction transaction for every EXECUTED instruction
//   instr_coverage : uvm_subscriber with the covergroups
//                      instr_fields_cg : fields of single instructions
//                      instr_order_cg  : order of two back-to-back instructions
//                      instr_gap_cg    : register / memory dependencies and gaps
//   instr_env      : monitor -> coverage collector
//   my_test        : builds the env, keeps the simulation running until the
//                    trickbox says the program is done
//   tb_top         : NOT here -- shared module in ../instr_gen.sv, compiled
//                    with +define+COVERAGE (drives instr_mem_if, resource db,
//                    run_test("my_test"), sets vif.done at the trickbox)
//
// Add -ntb_opts uvm to the VCS command line
//////////////////////////////////////////////////////////////////////////////
import uvm_pkg::*;
`include "uvm_macros.svh"
import mips_instr_pkg::*;


// ============================================================================
// Monitor
//
// On every rising clock edge after reset:
//   - pc same as last cycle : pipeline stall, same instruction -> do nothing
//   - new pc                : decode the instruction and add it to "pending"
//   - branch_taken          : mark that BEQ as taken and remove the
//                             instructions fetched after it (the pipeline
//                             throws them away, they never execute)
//
// A BEQ is decided two fetches after it is fetched, so an instruction is only
// sent to the coverage collector when 3 newer instructions are pending.
// ============================================================================
class instr_monitor extends uvm_monitor;
  `uvm_component_utils(instr_monitor)

  virtual instr_mem_if vif;
  uvm_analysis_port #(instruction) ap;

  instruction pending[$];       // fetched but not sent yet (oldest first)

  function new(string name, uvm_component parent);
    super.new(name, parent);
    ap = new("ap", this);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    // Get vif from resource db
    if (!uvm_resource_db #(virtual instr_mem_if)::read_by_name(get_full_name(), "vif", vif, this))
      `uvm_fatal("MON", "Could not get vif from uvm_resource_db")
  endfunction

  task run_phase(uvm_phase phase);
    instruction tr;
    bit [31:0]  last_pc;
    bit         new_fetch = 1;   // 1 = next pc is a new instruction for sure

    // Wait for reset
    @(negedge vif.reset);

    forever begin
      @(posedge vif.clk);

      // Program finished: send the instructions that are still pending
      if (vif.done) begin
        while (pending.size() > 0)
          send_oldest();
        continue;
      end

      // A BEQ is taken. The instruction fetched in this cycle is thrown away too.
      if (vif.branch_taken) begin
        branch_was_taken(vif.branch_pc);
        new_fetch = 1;
        continue;
      end

      // Trickbox (lw $0) already fetched: later fetches never execute (the
      // pc may even wrap around to 0), so ignore them. A taken branch above
      // still removes a trickbox that was fetched on the wrong path.
      if (pending.size() > 0 && is_trickbox(pending[$]))
        continue;

      // Same pc as last cycle = stall
      if (new_fetch == 0 && vif.pc == last_pc)
        continue;

      last_pc   = vif.pc;
      new_fetch = 0;

      // 0x00000000 = NOP (empty memory after the program)
      if (vif.instr == 0)
        continue;

      tr    = decode(vif.instr);     // new instruction object
      tr.pc = vif.pc;
      pending.push_back(tr);

      if (pending.size() > 3)
        send_oldest();
    end
  endtask

  // Mark the BEQ at beq_pc as taken and remove everything fetched after it
  function void branch_was_taken(bit [31:0] beq_pc);
    // The BEQ is near the newest end: drop wrong-path instructions until it is last
    // Flush out instructions fetched after the taken BEQ
    while (pending.size() > 0 && pending[$].pc != beq_pc)
      void'(pending.pop_back());

    if (pending.size() == 0)
      `uvm_warning("MON", $sformatf("Taken branch at pc %h was not found", beq_pc))
    else
      pending[$].taken = 1;
  endfunction

  // End-of-test instruction: lw $0, 0($0) (destination $0)
  function bit is_trickbox(instruction t);
    return (t.opcode == I_LW && t.reg_b == 0);
  endfunction

  // Send the oldest pending instruction to the analysis port
  function void send_oldest();
    instruction tr;

    tr = pending.pop_front();
    if (tr.opcode == I_BEQ) tr.note = tr.taken ? "(taken)" : "(not taken)";
    // Same verbosity control as the old `uvm_info(..., UVM_MEDIUM)
    if (uvm_report_enabled(UVM_MEDIUM, UVM_INFO, "MON"))
      tr.print_me($sformatf("[MON] pc %h executed: ", tr.pc));

    ap.write(tr);
  endfunction

  // Machine code -> instruction object
  function instruction decode(bit [31:0] mc);
    instruction tr = new("fetched");
    tr.reg_a = mc[25:21];
    tr.reg_b = mc[20:16];
    tr.reg_c = 0;
    tr.taken = 0;

    case (mc[31:26])
      6'b000000: begin                       // R-type
        tr.reg_c = mc[15:11];
        if (mc[5:0] == 6'b100100) tr.opcode = I_AND;
        else                      tr.opcode = I_ADD;
      end
      6'b100011: begin
        tr.opcode   = I_LW;
        tr.mem_addr = mc[15:0];
      end
      6'b101011: begin
        tr.opcode   = I_SW;
        tr.mem_addr = mc[15:0];
      end
      6'b000100: begin
        tr.opcode    = I_BEQ;
        tr.br_offset = mc[2:0];
      end
      6'b001000: begin                       // setup only
        tr.opcode = I_ADDI;
        tr.imm    = mc[15:0];
      end
      default: `uvm_warning("MON", $sformatf("Unknown instruction %h", mc))
    endcase
    return tr;
  endfunction
endclass


// ============================================================================
// Coverage collector
//
// "gap" = number of executed instructions between the two dependent
//         instructions (lab limit: 1, 2, 3, 4)
// ============================================================================
class instr_coverage extends uvm_subscriber #(instruction);
  `uvm_component_utils(instr_coverage)

  uvm_analysis_imp #(instruction, instr_coverage) imp;

  instruction tr;               // current instruction
  instruction prev;             // previous executed instruction
  instruction history[$];       // queue: last 5 executed instructions (newest at back)

  // Values used by instr_gap_cg
  bit          dep_is_mem;      // 0 = register dependency, 1 = memory dependency
  instr_kind_e dep_first_kind;  // instruction that writes the register
  instr_kind_e dep_second_kind; // instruction that reads it
  bit [4:0]    dep_reg;
  bit [15:0]   dep_addr;
  int          dep_gap;

  // --------------------------------------------------------------------------
  // Fields of single instructions
  // --------------------------------------------------------------------------
  covergroup instr_fields_cg;
    coverpoint tr.opcode {
      bins add    = {I_ADD};
      bins and_op = {I_AND};
      bins lw     = {I_LW};
      bins sw     = {I_SW};
      bins beq    = {I_BEQ};
    }

    // ADD / AND
    cp_alu_op: coverpoint tr.opcode iff (tr.opcode == I_ADD || tr.opcode == I_AND) {
      bins add    = {I_ADD};
      bins and_op = {I_AND};
    }
    cp_alu_reg_a: coverpoint tr.reg_a iff (tr.opcode == I_ADD || tr.opcode == I_AND) { bins r[] = {[1:4]}; }
    cp_alu_reg_b: coverpoint tr.reg_b iff (tr.opcode == I_ADD || tr.opcode == I_AND) { bins r[] = {[1:4]}; }
    cp_alu_reg_c: coverpoint tr.reg_c iff (tr.opcode == I_ADD || tr.opcode == I_AND) { bins r[] = {[1:4]}; }
    x_alu_reg_c:  cross cp_alu_op, cp_alu_reg_c;

    // LW / SW
    cp_mem_op: coverpoint tr.opcode iff (tr.opcode == I_LW || tr.opcode == I_SW) {
      bins lw = {I_LW};
      bins sw = {I_SW};
    }
    cp_mem_addr: coverpoint tr.mem_addr iff (tr.opcode == I_LW || tr.opcode == I_SW) {
      bins addr[] = {16'h10, 16'h14, 16'h18, 16'h1C};
    }
    cp_mem_reg: coverpoint tr.reg_b iff (tr.opcode == I_LW || tr.opcode == I_SW) { bins r[] = {[1:4]}; }
    x_mem_addr: cross cp_mem_op, cp_mem_addr;
    x_mem_reg:  cross cp_mem_op, cp_mem_reg;

    // BEQ
    cp_beq_reg_a:  coverpoint tr.reg_a iff (tr.opcode == I_BEQ) { bins r[] = {[1:4]}; }
    cp_beq_reg_b:  coverpoint tr.reg_b iff (tr.opcode == I_BEQ) { bins r[] = {[1:4]}; }
    cp_beq_offset: coverpoint tr.br_offset iff (tr.opcode == I_BEQ) { bins off[] = {[1:4]}; }
    cp_beq_taken:  coverpoint tr.taken iff (tr.opcode == I_BEQ) {
      bins not_taken = {0};
      bins taken     = {1};
    }
    x_beq: cross cp_beq_offset, cp_beq_taken;
  endgroup

  // --------------------------------------------------------------------------
  // Order of two back-to-back executed instructions (5 x 5 = 25 orders)
  // ADDI (setup only) has no bins, so the cross stays 5 x 5.
  // --------------------------------------------------------------------------
  covergroup instr_order_cg;
    cp_prev: coverpoint prev.opcode {
      bins op[] = {I_ADD, I_AND, I_LW, I_SW, I_BEQ};
    }
    cp_curr: coverpoint tr.opcode {
      bins op[] = {I_ADD, I_AND, I_LW, I_SW, I_BEQ};
    }
    x_order: cross cp_prev, cp_curr;
  endgroup

  // --------------------------------------------------------------------------
  // Dependencies and the gap between the two dependent instructions
  //   register: ADD/AND/LW writes $x ... ADD/AND/SW/BEQ reads $x
  //   memory  : SW to an address  ... LW from the same address
  // --------------------------------------------------------------------------
  covergroup instr_gap_cg;
    cp_dep_type: coverpoint dep_is_mem {
      bins reg_dep = {0};
      bins mem_dep = {1};
    }
    cp_gap: coverpoint dep_gap { bins gap[] = {[1:4]}; }
    x_type_gap: cross cp_dep_type, cp_gap;

    // Register dependency
    cp_first: coverpoint dep_first_kind iff (!dep_is_mem) {
      bins add    = {I_ADD};
      bins and_op = {I_AND};
      bins lw     = {I_LW};
    }
    cp_second: coverpoint dep_second_kind iff (!dep_is_mem) {
      bins add    = {I_ADD};
      bins and_op = {I_AND};
      bins sw     = {I_SW};
      bins beq    = {I_BEQ};
    }
    cp_reg: coverpoint dep_reg iff (!dep_is_mem) { bins r[] = {[1:4]}; }
    x_first_gap:  cross cp_first,  cp_gap;
    x_second_gap: cross cp_second, cp_gap;
    x_pair:       cross cp_first,  cp_second;
    x_reg_gap:    cross cp_reg,    cp_gap;

    // Memory dependency
    cp_addr: coverpoint dep_addr iff (dep_is_mem) { bins addr[] = {16'h10, 16'h14, 16'h18, 16'h1C}; }
    x_addr_gap: cross cp_addr, cp_gap;
  endgroup

  function new(string name, uvm_component parent);
    super.new(name, parent);
    imp             = new("imp", this);
    instr_fields_cg = new();
    instr_order_cg  = new();
    instr_gap_cg    = new();
  endfunction

  // Called for every instruction the monitor sends
  function void write(instruction t);
    tr = t;

    // Call sample of the covergroups
    instr_fields_cg.sample();
    if (prev != null)
      instr_order_cg.sample();

    // Register dependencies: which registers does this instruction read?
    if (tr.opcode == I_ADD || tr.opcode == I_AND || tr.opcode == I_BEQ) begin
      check_reg_dependency(tr.reg_a);
      if (tr.reg_b != tr.reg_a) check_reg_dependency(tr.reg_b);
    end
    if (tr.opcode == I_SW)
      check_reg_dependency(tr.reg_b);

    // Memory dependency: load from an address that was stored to
    if (tr.opcode == I_LW)
      check_mem_dependency(tr.mem_addr);

    // Add this instruction to the queue (keep only the last 5)
    history.push_back(tr);
    if (history.size() > 5)
      history.pop_front();
    prev = tr;
  endfunction

  // Find the most recent instruction that wrote register r.
  function void check_reg_dependency(bit [4:0] r);
    for (int i = history.size() - 1; i >= 0; i--) begin
      if (history[i].dest_reg() == r) begin
        dep_is_mem      = 0;
        dep_first_kind  = history[i].opcode;
        dep_second_kind = tr.opcode;
        dep_reg         = r;
        dep_gap         = history.size() - 1 - i;   // instructions in between
        instr_gap_cg.sample();
        return;
      end
    end
  endfunction

  // Find the most recent SW to the same address
  function void check_mem_dependency(bit [15:0] addr);
    for (int i = history.size() - 1; i >= 0; i--) begin
      if (history[i].opcode == I_SW && history[i].mem_addr == addr) begin
        dep_is_mem = 1;
        dep_addr   = addr;
        dep_gap    = history.size() - 1 - i;
        instr_gap_cg.sample();
        return;
      end
    end
  endfunction

  function void report_phase(uvm_phase phase);
    `uvm_info("COV", $sformatf("Coverage: fields %0.1f%%, order %0.1f%%, gap %0.1f%%",
                               instr_fields_cg.get_coverage(), instr_order_cg.get_coverage(),
                               instr_gap_cg.get_coverage()), UVM_LOW)
  endfunction
endclass


// ============================================================================
// Environment: monitor -> coverage collector
// ============================================================================
class instr_env extends uvm_env;
  `uvm_component_utils(instr_env)

  instr_monitor  mon;
  instr_coverage cov;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    mon = instr_monitor::type_id::create("mon", this);
    cov = instr_coverage::type_id::create("cov", this);
  endfunction

  virtual function void connect_phase(uvm_phase phase);
    mon.ap.connect(cov.imp);
  endfunction
endclass


// ============================================================================
// Test
// The test only holds an objection until the end of simulation is hit; 
// when it is dropped, UVM ends the simulation.
// ============================================================================
class my_test extends uvm_test;

  instr_env            env;
  virtual instr_mem_if vif;

  `uvm_component_utils(my_test)

  function new(string name = "my_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    env = instr_env::type_id::create("env", this);
    if (!uvm_resource_db #(virtual instr_mem_if)::read_by_name(get_full_name(), "vif", vif, this))
      `uvm_fatal("TEST", "Could not get vif from uvm_resource_db")
  endfunction

  function void end_of_elaboration_phase(uvm_phase phase);
    super.end_of_elaboration_phase(phase);
    uvm_top.print_topology();
  endfunction

  task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    wait (vif.done == 1);
    repeat (2) @(posedge vif.clk);   // give the monitor time to send the last instructions
    phase.drop_objection(this);
  endtask
endclass

