// A0 package/struct-only sample (no interface), tests Yosys/Icarus parser depth.
`timescale 1ns/1ps
package pkg_struct_pkg;
    typedef enum logic [1:0] { S_IDLE=0, S_RUN=1, S_DONE=2 } state_t;
    typedef struct packed {
        logic [7:0]  data;
        state_t      state;
        logic        valid;
    } item_t;
endpackage

module pkg_struct_sample #(
    parameter int WIDTH = 8
) (
    input  logic             clk,
    input  logic             rst_n,
    input  logic [WIDTH-1:0] din,
    output logic [WIDTH-1:0] dout
);
    import pkg_struct_pkg::*;
    item_t item_q;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            item_q <= '0;
            dout <= '0;
        end else begin
            item_q.data  <= din;
            item_q.state <= S_RUN;
            item_q.valid <= 1'b1;
            dout <= item_q.data;
        end
    end
endmodule
