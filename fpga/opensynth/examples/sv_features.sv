// A0 focused SystemVerilog feature sample:
// package + packed struct + enum + interface/modport + parameterized module.
// Used to identify open-source tool parser/lint blockers.
`timescale 1ns/1ps

package feature_pkg;
    typedef enum logic [1:0] {
        IDLE = 2'd0,
        RUN  = 2'd1,
        DONE = 2'd2
    } state_t;

    typedef struct packed {
        logic [7:0]  data;
        state_t      state;
        logic        valid;
    } item_t;
endpackage

interface feature_if;
    logic [7:0] data;
    logic       valid;
    modport master (output data, valid);
    modport slave  (input data, valid);
endinterface

module feature_sample #(
    parameter int WIDTH = 8
) (
    input  logic               clk,
    input  logic               rst_n,
    input  feature_if.master   bus,
    output logic [WIDTH-1:0]   out
);
    import feature_pkg::*;

    item_t item_q;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            item_q <= '0;
            out    <= '0;
        end else begin
            item_q.data  <= bus.data;
            item_q.state <= RUN;
            item_q.valid <= bus.valid;
            out <= item_q.data;
        end
    end
endmodule

module feature_tb;
    logic clk = 0;
    logic rst_n = 1;
    feature_if bus();
    logic [7:0] out;
    always #5 clk = ~clk;
    initial begin
        #10 rst_n = 0;
        #10 rst_n = 1;
        bus.data = 8'h5a;
        bus.valid = 1;
        #20 $finish;
    end
    feature_sample dut (.clk(clk), .rst_n(rst_n), .bus(bus), .out(out));
endmodule
