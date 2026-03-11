`timescale 1ns / 1ps

/*
 * Module: tb_ml_accelerator_top
 * Description: Complete Testbench simulating CPU AXI-Lite commands, 
 * external RAM responses, and testing the Batch Processing feature.
 */

module tb_ml_accelerator_top();

    // System Signals
    reg clk;
    reg rst_n;
    
    // AXI-Lite Simulation Signals (CPU to Accelerator)
    reg  [5:0]  s_axi_awaddr;
    reg         s_axi_awvalid;
    wire        s_axi_awready;
    reg  [31:0] s_axi_wdata;
    reg  [3:0]  s_axi_wstrb;
    reg         s_axi_wvalid;
    wire        s_axi_wready;
    wire [1:0]  s_axi_bresp;
    wire        s_axi_bvalid;
    reg         s_axi_bready;
    
    reg  [5:0]  s_axi_araddr;
    reg         s_axi_arvalid;
    wire        s_axi_arready;
    wire [31:0] s_axi_rdata;
    wire [1:0]  s_axi_rresp;
    wire        s_axi_rvalid;
    reg         s_axi_rready;

    // AXI-Master Simulation Signals (Accelerator DMA to RAM)
    wire [31:0] m_axi_araddr;
    wire [7:0]  m_axi_arlen;
    wire [2:0]  m_axi_arsize;
    wire [1:0]  m_axi_arburst;
    wire        m_axi_arvalid;
    reg         m_axi_arready;
    reg  [31:0] m_axi_rdata;
    reg         m_axi_rlast;
    reg         m_axi_rvalid;
    wire        m_axi_rready;

    wire        irq_done;

    // Memory Array to simulate actual SoC RAM (1024 bytes)
    reg [7:0] MAIN_RAM [0:1023]; 

    // Instantiate the Top Level Accelerator
    ml_accelerator_top uut (
        .clk(clk),
        .rst_n(rst_n),
        .s_axi_awaddr(s_axi_awaddr),
        .s_axi_awvalid(s_axi_awvalid),
        .s_axi_awready(s_axi_awready),
        .s_axi_wdata(s_axi_wdata),
        .s_axi_wstrb(s_axi_wstrb),
        .s_axi_wvalid(s_axi_wvalid),
        .s_axi_wready(s_axi_wready),
        .s_axi_bresp(s_axi_bresp),
        .s_axi_bvalid(s_axi_bvalid),
        .s_axi_bready(s_axi_bready),
        .s_axi_araddr(s_axi_araddr),
        .s_axi_arvalid(s_axi_arvalid),
        .s_axi_arready(s_axi_arready),
        .s_axi_rdata(s_axi_rdata),
        .s_axi_rresp(s_axi_rresp),
        .s_axi_rvalid(s_axi_rvalid),
        .s_axi_rready(s_axi_rready),
        .m_axi_araddr(m_axi_araddr),
        .m_axi_arlen(m_axi_arlen),
        .m_axi_arsize(m_axi_arsize),
        .m_axi_arburst(m_axi_arburst),
        .m_axi_arvalid(m_axi_arvalid),
        .m_axi_arready(m_axi_arready),
        .m_axi_rdata(m_axi_rdata),
        .m_axi_rlast(m_axi_rlast),
        .m_axi_rvalid(m_axi_rvalid),
        .m_axi_rready(m_axi_rready),
        .irq_done(irq_done)
    );

    // Clock Generation (100 MHz)
    always #5 clk = ~clk;

    // =========================================================================
    // Simulated Main Memory (RAM) Responding to DMA Burst Requests
    // =========================================================================
    integer ram_ptr;
    integer burst_count;
    
    always @(posedge clk) begin
        if (!rst_n) begin
            m_axi_arready <= 0;
            m_axi_rvalid  <= 0;
            m_axi_rlast   <= 0;
            m_axi_rdata   <= 0;
            burst_count   <= 0;
        end else begin
            // 1. Accept Address from DMA
            if (m_axi_arvalid && !m_axi_arready) begin
                m_axi_arready <= 1;
                ram_ptr       <= m_axi_araddr;
                burst_count   <= m_axi_arlen + 1; // arlen is N-1
            end else if (m_axi_arready) begin
                m_axi_arready <= 0;
            end
            
            // 2. Stream Data back to DMA
            if (burst_count > 0 && (!m_axi_rvalid || m_axi_rready)) begin
                m_axi_rvalid <= 1;
                // Fetch 4 bytes (32 bits) at a time
                m_axi_rdata  <= {MAIN_RAM[ram_ptr+3], MAIN_RAM[ram_ptr+2], MAIN_RAM[ram_ptr+1], MAIN_RAM[ram_ptr]};
                
                if (burst_count == 1) m_axi_rlast <= 1;
                else m_axi_rlast <= 0;

                if (m_axi_rvalid && m_axi_rready) begin
                    burst_count <= burst_count - 1;
                    ram_ptr     <= ram_ptr + 4;
                    if (burst_count == 1) begin
                        m_axi_rvalid <= 0;
                        m_axi_rlast  <= 0;
                    end
                end
            end
        end
    end

    // =========================================================================
    // Test Sequence
    // =========================================================================
    initial begin
        // Output waves for GTKWave
        $dumpfile("waveform.vcd"); 
        $dumpvars(0, tb_ml_accelerator_top);

        // Initialize Signals
        clk = 0; rst_n = 0;
        s_axi_awaddr = 0; s_axi_awvalid = 0;
        s_axi_wdata = 0;  s_axi_wstrb = 4'hF; s_axi_wvalid = 0;
        s_axi_bready = 1;
        s_axi_araddr = 0; s_axi_arvalid = 0;
        s_axi_rready = 1;

        // Load external data into simulated RAM
        $readmemh("ram_data.hex", MAIN_RAM);

        #20 rst_n = 1;

        // ---------------------------------------------------------------------
        // RUN 1: Full Initialization (Fetch Weights + Fetch Inputs)
        // ---------------------------------------------------------------------
        $display("RUN 1: Full Load and Compute...");
        
        // Write REG_WGT_BASE (Address 0x14) -> Fetch weights from Address 0
        #10 s_axi_awaddr = 6'h14; s_axi_wdata = 32'd0; s_axi_awvalid = 1; s_axi_wvalid = 1;
        #10 s_axi_awvalid = 0; s_axi_wvalid = 0;

        // Write REG_INP_BASE (Address 0x18) -> Fetch inputs from Address 256
        #10 s_axi_awaddr = 6'h18; s_axi_wdata = 32'd256; s_axi_awvalid = 1; s_axi_wvalid = 1;
        #10 s_axi_awvalid = 0; s_axi_wvalid = 0;

        // Write REG_CONTROL (Address 0x00) -> Start = 1, Reuse Weights = 0 (Data: 32'h01)
        #10 s_axi_awaddr = 6'h00; s_axi_wdata = 32'h01; s_axi_awvalid = 1; s_axi_wvalid = 1;
        #10 s_axi_awvalid = 0; s_axi_wvalid = 0;

        // Wait for Run 1 to finish
        wait(irq_done == 1);
        $display("RUN 1 Complete.");
        #100; // Small delay between runs

        // ---------------------------------------------------------------------
        // RUN 2: Batch Processing (Reuse Weights + Fetch NEW Inputs)
        // ---------------------------------------------------------------------
        $display("RUN 2: Reusing Weights for new Data block...");

        // Write REG_INP_BASE (Address 0x18) -> Fetch NEW inputs from Address 512
        #10 s_axi_awaddr = 6'h18; s_axi_wdata = 32'd512; s_axi_awvalid = 1; s_axi_wvalid = 1;
        #10 s_axi_awvalid = 0; s_axi_wvalid = 0;

        // Write REG_CONTROL (Address 0x00) -> Start = 1, Reuse Weights = 1 (Data: 32'h03)
        #10 s_axi_awaddr = 6'h00; s_axi_wdata = 32'h03; s_axi_awvalid = 1; s_axi_wvalid = 1;
        #10 s_axi_awvalid = 0; s_axi_wvalid = 0;

        // Wait for Run 2 to finish
        wait(irq_done == 1);
        $display("RUN 2 Complete.");

        #200;
        $display("All Simulations Complete.");
        $finish;
    end
endmodule
