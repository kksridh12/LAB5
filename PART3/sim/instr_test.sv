//////////////////////////////////////////////////////////////////////////////
// instr_test.sv  --  test: builds the environment and keeps the simulation
//                    running until the trickbox says the program is done
//////////////////////////////////////////////////////////////////////////////
class instr_test extends uvm_test;
  `uvm_component_utils(instr_test)

  instr_env            env;
  virtual instr_mem_if vif;

  function new(string name = "instr_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    env = instr_env::type_id::create("env", this);
    if (!uvm_config_db #(virtual instr_mem_if)::get(this, "", "vif", vif))
      `uvm_fatal("TEST", "Could not get vif from uvm_config_db")
  endfunction

  function void end_of_elaboration_phase(uvm_phase phase);
    super.end_of_elaboration_phase(phase);
    uvm_top.print_topology();
  endfunction

  // Stimulus is not sent through UVM in this lab (the program is already in
  // instruction memory). The test only holds an objection until the trickbox
  // is hit; when it is dropped, UVM ends the simulation.
  task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    wait (vif.done == 1);
    repeat (2) @(posedge vif.clk);   // give the monitor time to send the last instructions
    phase.drop_objection(this);
  endtask
endclass

