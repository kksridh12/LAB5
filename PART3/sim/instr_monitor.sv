//////////////////////////////////////////////////////////////////////////////
// instr_monitor.sv  --  watches the instruction fetch interface and sends one
//                       instruction transaction for every EXECUTED instruction
//
// On every rising clock edge:
//   - reset                 : do nothing
//   - pc same as last cycle : pipeline stall, same instruction -> do nothing
//   - new pc                : decode the instruction and add it to "pending"
//   - branch_taken          : mark that BEQ as taken and remove the
//                             instructions fetched after it (the pipeline
//                             throws them away, they never execute)
//
// A BEQ is decided two fetches after it is fetched, so an instruction is only
// sent to the coverage collector when 3 newer instructions are pending.
//////////////////////////////////////////////////////////////////////////////
class instr_monitor extends uvm_monitor;
  `uvm_component_utils(instr_monitor)

  virtual instr_mem_if vif;
  uvm_analysis_port #(instruction) ap;

  instruction pending[$];       // fetched but not sent yet (oldest first)

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    ap = new("ap", this);
    if (!uvm_config_db #(virtual instr_mem_if)::get(this, "", "vif", vif))
      `uvm_fatal("MON", "Could not get vif from uvm_config_db")
  endfunction

  task run_phase(uvm_phase phase);
    instruction t;
    bit [31:0]  last_pc;
    bit         new_fetch = 1;   // 1 = next pc is a new instruction for sure

    forever begin
      @(posedge vif.clk);

      // Program finished: send the instructions that are still pending
      if (vif.done) begin
        while (pending.size() > 0)
          send_oldest();
        continue;
      end

      if (vif.reset) begin
        new_fetch = 1;
        continue;
      end

      // A BEQ is taken. The instruction fetched in this cycle is thrown away too.
      if (vif.branch_taken) begin
        branch_was_taken(vif.branch_pc);
        new_fetch = 1;
        continue;
      end

      // Same pc as last cycle = stall
      if (new_fetch == 0 && vif.pc == last_pc)
        continue;

      last_pc   = vif.pc;
      new_fetch = 0;

      // 0x00000000 = NOP (empty memory after the program)
      if (vif.instr == 0)
        continue;

      t    = decode(vif.instr);
      t.pc = vif.pc;
      pending.push_back(t);

      if (pending.size() > 3)
        send_oldest();
    end
  endtask

  // Mark the BEQ at beq_pc as taken and remove everything fetched after it
  function void branch_was_taken(bit [31:0] beq_pc);
    for (int i = 0; i < pending.size(); i++) begin
      if (pending[i].pc == beq_pc) begin
        pending[i].taken = 1;
        while (pending.size() > i + 1)
          pending.pop_back();
        return;
      end
    end
    `uvm_warning("MON", $sformatf("Taken branch at pc %h was not found", beq_pc))
  endfunction

  // Send the oldest pending instruction to the analysis port
  function void send_oldest();
    instruction t;
    string      msg;

    t   = pending.pop_front();
    msg = t.convert2string();
    if (t.kind == I_BEQ && t.taken == 1) msg = {msg, "   (taken)"};
    if (t.kind == I_BEQ && t.taken == 0) msg = {msg, "   (not taken)"};
    `uvm_info("MON", $sformatf("pc %h executed: %s", t.pc, msg), UVM_MEDIUM)

    ap.write(t);
  endfunction

  // Machine code -> instruction object
  function instruction decode(bit [31:0] mc);
    instruction t = new("fetched");
    t.rs    = mc[25:21];
    t.rt    = mc[20:16];
    t.rd    = 0;
    t.imm   = mc[15:0];
    t.taken = 0;

    case (mc[31:26])
      6'b000000: begin                       // R-type
        t.rd = mc[15:11];
        if (mc[5:0] == 6'b100100) t.kind = I_AND;
        else                      t.kind = I_ADD;
      end
      6'b100011: t.kind = I_LW;
      6'b101011: t.kind = I_SW;
      6'b000100: begin
        t.kind      = I_BEQ;
        t.br_offset = mc[2:0];
      end
      default: `uvm_warning("MON", $sformatf("Unknown instruction %h", mc))
    endcase
    return t;
  endfunction

endclass

