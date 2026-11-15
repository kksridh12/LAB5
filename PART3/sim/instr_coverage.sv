//////////////////////////////////////////////////////////////////////////////
// instr_coverage.sv  --  functional coverage collector (uvm_subscriber)
//
// Covergroups:
//   cg_fields   : fields of single instructions (incl. branch taken/not taken)
//   cg_order    : order of two back-to-back executed instructions
//   cg_reg_dep  : register dependency (write $x ... read $x) and its gap
//   cg_mem_dep  : memory dependency  (sw addr ... lw addr) and its gap
//
// "gap" = number of instructions between the two dependent instructions
//         (lab limit: 1, 2, 3, 4)
//////////////////////////////////////////////////////////////////////////////
class instr_coverage extends uvm_subscriber #(instruction);
  `uvm_component_utils(instr_coverage)

  // Port that receives the monitor's transactions (calls write() below)
  uvm_analysis_imp #(instruction, instr_coverage) imp;

  instruction tr;               // current instruction
  instruction prev;             // previous executed instruction
  instruction history[$];       // last 5 executed instructions (newest at back)

  // Values used by the dependency covergroups
  instr_kind_e dep_first_kind;  // instruction that writes reg / memory
  instr_kind_e dep_second_kind; // instruction that reads it
  bit [4:0]    dep_reg;
  bit [15:0]   dep_addr;
  int          dep_gap;

  // --------------------------------------------------------------------------
  covergroup cg_fields;
    cp_kind: coverpoint tr.kind;    // one bin per instruction: add, and, lw, sw, beq

    // ADD / AND
    cp_alu_op: coverpoint tr.kind iff (tr.kind == I_ADD || tr.kind == I_AND) {
      bins add    = {I_ADD};
      bins and_op = {I_AND};
    }
    cp_alu_rs: coverpoint tr.rs iff (tr.kind == I_ADD || tr.kind == I_AND) { bins r[] = {[1:4]}; }
    cp_alu_rt: coverpoint tr.rt iff (tr.kind == I_ADD || tr.kind == I_AND) { bins r[] = {[1:4]}; }
    cp_alu_rd: coverpoint tr.rd iff (tr.kind == I_ADD || tr.kind == I_AND) { bins r[] = {[1:4]}; }
    x_alu_rd:  cross cp_alu_op, cp_alu_rd;

    // LW / SW
    cp_mem_op: coverpoint tr.kind iff (tr.kind == I_LW || tr.kind == I_SW) {
      bins lw = {I_LW};
      bins sw = {I_SW};
    }
    cp_mem_addr: coverpoint tr.imm iff (tr.kind == I_LW || tr.kind == I_SW) {
      bins addr[] = {16'h10, 16'h14, 16'h18, 16'h1C};
    }
    cp_mem_reg: coverpoint tr.rt iff (tr.kind == I_LW || tr.kind == I_SW) { bins r[] = {[1:4]}; }
    x_mem_addr: cross cp_mem_op, cp_mem_addr;
    x_mem_reg:  cross cp_mem_op, cp_mem_reg;

    // BEQ
    cp_beq_rs:     coverpoint tr.rs iff (tr.kind == I_BEQ) { bins r[] = {[1:4]}; }
    cp_beq_rt:     coverpoint tr.rt iff (tr.kind == I_BEQ) { bins r[] = {[1:4]}; }
    cp_beq_offset: coverpoint tr.br_offset iff (tr.kind == I_BEQ) { bins off[] = {[1:4]}; }
    cp_beq_taken:  coverpoint tr.taken iff (tr.kind == I_BEQ) {
      bins not_taken = {0};
      bins taken     = {1};
    }
    x_beq: cross cp_beq_offset, cp_beq_taken;
  endgroup

  // --------------------------------------------------------------------------
  covergroup cg_order;
    cp_prev: coverpoint prev.kind;
    cp_curr: coverpoint tr.kind;
    x_order: cross cp_prev, cp_curr;     // 5 x 5 = 25 orders
  endgroup

  // --------------------------------------------------------------------------
  covergroup cg_reg_dep;
    cp_first: coverpoint dep_first_kind {
      bins add    = {I_ADD};
      bins and_op = {I_AND};
      bins lw     = {I_LW};
    }
    cp_second: coverpoint dep_second_kind {
      bins add    = {I_ADD};
      bins and_op = {I_AND};
      bins sw     = {I_SW};
      bins beq    = {I_BEQ};
    }
    cp_reg: coverpoint dep_reg { bins r[]   = {[1:4]}; }
    cp_gap: coverpoint dep_gap { bins gap[] = {[1:4]}; }
    x_first_gap:  cross cp_first,  cp_gap;
    x_second_gap: cross cp_second, cp_gap;
    x_pair:       cross cp_first,  cp_second;
    x_reg_gap:    cross cp_reg,    cp_gap;
  endgroup

  // --------------------------------------------------------------------------
  covergroup cg_mem_dep;
    cp_addr: coverpoint dep_addr { bins addr[] = {16'h10, 16'h14, 16'h18, 16'h1C}; }
    cp_gap:  coverpoint dep_gap  { bins gap[]  = {[1:4]}; }
    x_addr_gap: cross cp_addr, cp_gap;
  endgroup

  // --------------------------------------------------------------------------
  function new(string name, uvm_component parent);
    super.new(name, parent);
    imp        = new("imp", this);
    cg_fields  = new();
    cg_order   = new();
    cg_reg_dep = new();
    cg_mem_dep = new();
  endfunction

  // Called for every instruction the monitor sends
  function void write(instruction t);
    tr = t;

    cg_fields.sample();
    if (prev != null)
      cg_order.sample();

    // Register dependencies: which registers does this instruction read?
    if (tr.kind == I_ADD || tr.kind == I_AND || tr.kind == I_BEQ) begin
      check_reg_dependency(tr.rs);
      if (tr.rt != tr.rs) check_reg_dependency(tr.rt);
    end
    if (tr.kind == I_SW)
      check_reg_dependency(tr.rt);

    // Memory dependency: load from an address that was stored to
    if (tr.kind == I_LW)
      check_mem_dependency(tr.imm);

    // Remember this instruction (keep only the last 5)
    history.push_back(tr);
    if (history.size() > 5)
      history.pop_front();
    prev = tr;
  endfunction

  // Find the most recent instruction that wrote register r
  function void check_reg_dependency(bit [4:0] r);
    for (int i = history.size() - 1; i >= 0; i--) begin
      if (history[i].dest_reg() == r) begin
        dep_first_kind  = history[i].kind;
        dep_second_kind = tr.kind;
        dep_reg         = r;
        dep_gap         = history.size() - 1 - i;   // instructions in between
        cg_reg_dep.sample();
        return;
      end
    end
  endfunction

  // Find the most recent SW to the same address
  function void check_mem_dependency(bit [15:0] addr);
    for (int i = history.size() - 1; i >= 0; i--) begin
      if (history[i].kind == I_SW && history[i].imm == addr) begin
        dep_addr = addr;
        dep_gap  = history.size() - 1 - i;
        cg_mem_dep.sample();
        return;
      end
    end
  endfunction

  function void report_phase(uvm_phase phase);
    `uvm_info("COV", $sformatf("Coverage: fields %0.1f%%, order %0.1f%%, reg dep %0.1f%%, mem dep %0.1f%%",
                               cg_fields.get_coverage(), cg_order.get_coverage(),
                               cg_reg_dep.get_coverage(), cg_mem_dep.get_coverage()), UVM_LOW)
  endfunction

endclass

