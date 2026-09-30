// A0 minimal SystemVerilog sample: IEEE 1800-2017 subset.
// Intentionally portable (package/struct/interface tested separately).
`timescale 1ns/1ps
module minimal_counter #(
    parameter int WIDTH = 8,
    parameter logic [WIDTH-1:0] INIT = 0
) (
    input  logic             clk,
    input  logic             rst_n,
    input  logic             en,
    output logic [WIDTH-1:0] count
);
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            count <= INIT;
        else if (en)
            count <= count + 1'b1;
    end
endmodule
