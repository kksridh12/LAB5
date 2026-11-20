`timescale 1ns/1ps

// Lab 5 Part 5 testbench.
module iss_tb;
    logic clk = 1'b0;
    logic reset = 1'b1;
    logic [31:0] writedata, dataadr;
    logic memwrite;

    string program_file;
    string trace_file;
    integer trace_fd;
    integer cycle_count = 0;
    integer max_cycles = 100;

    top dut (
        .clk(clk), .reset(reset),
        .writedata(writedata), .dataadr(dataadr), .memwrite(memwrite)
    );

    always #5 clk = ~clk;

    initial begin
        if (!$value$plusargs("PROGRAM=%s", program_file))
            $fatal(1, "Missing +PROGRAM=<path-to-hex-file>");
        if (!$value$plusargs("TRACE=%s", trace_file))
            trace_file = "rtl_trace.txt";
        void'($value$plusargs("MAX_CYCLES=%d", max_cycles));

        // Override the imem module's default memfile.dat initialization.
        #1;
        for (int i = 0; i < 64; i++)
            dut.imem.RAM[i] = 32'b0;
        $readmemh(program_file, dut.imem.RAM);

        trace_fd = $fopen(trace_file, "w");
        if (trace_fd == 0)
            $fatal(1, "Could not open trace file %s", trace_file);

        repeat (2) @(negedge clk);
        reset = 1'b0;
    end

    // Events are sampled on the clock edge that commits each write.
    // No cycle number is included in trace lines since the ISS is sequential
    always @(posedge clk) begin
        if (!reset) begin
            cycle_count = cycle_count + 1;
            if (dut.mips.dp.WB_writeEnable && dut.mips.dp.WB_dest != 0)
                $fdisplay(trace_fd, "REG %0d %08h",
                          dut.mips.dp.WB_dest, dut.mips.dp.WB_result);
            if (memwrite)
                $fdisplay(trace_fd, "MEM %08h %08h", dataadr, writedata);
            if (cycle_count >= max_cycles) begin
                $fclose(trace_fd);
                $display("RTL trace saved to %s after %0d cycles", trace_file, cycle_count);
                $finish;
            end
        end
    end
endmodule
