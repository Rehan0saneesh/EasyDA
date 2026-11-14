import Foundation

/// Larger designs offered in the editor's Examples menu.
enum Examples {
    static let all: [(title: String, source: String)] = [
        ("8-bit counter", counter),
        ("UART sender", uart),
        ("Tiny CPU", tinyCPU),
    ]

    static let counter = """
    module counter(
      input clk,
      input rst,
      input up,
      output reg [7:0] count,
      output wrap
    );
      // 1 on the cycle the counter is about to roll over
      assign wrap = up ? (count == 8'hFF) : (count == 8'h00);

      always @(posedge clk) begin
        if (rst)
          count <= 8'd0;
        else if (up)
          count <= count + 1;
        else
          count <= count - 1;
      end
    endmodule
    """

    // Hold `send` high, pulse `rst`, run the clock, then choose Decode > UART in Waves.
    static let uart = """
    module uart_tx(
      input clk,
      input rst,
      input send,
      input [7:0] data,
      output reg tx,
      output busy
    );
      reg [3:0] count;   // 0 idle, 1 start bit, 2-9 data bits, 10 stop bit
      reg [7:0] shift;

      assign busy = count != 0;

      always @(posedge clk) begin
        if (rst) begin
          count <= 0;
          tx <= 1;
        end else if (count == 0) begin
          tx <= 1;
          if (send) begin
            shift <= data;
            count <= 1;
          end
        end else if (count == 1) begin
          tx <= 0;                  // start bit
          count <= 2;
        end else if (count <= 9) begin
          tx <= shift[0];           // least significant bit first
          shift <= shift >> 1;
          count <= count + 1;
        end else begin
          tx <= 1;                  // stop bit
          count <= 0;
        end
      end
    endmodule
    """

    static let tinyCPU = #"""
`default_nettype none

module tt_um_funproj (
    input  wire [7:0] ui_in,
    output wire [7:0] uo_out,  
    input  wire [7:0] uio_in, 
    output wire [7:0] uio_out,
    output wire [7:0] uio_oe,
    input  wire       ena, 
    input  wire       clk, 
    input  wire       rst_n
);
    assign uio_out = 8'b0;
    assign uio_oe  = 8'b0;

    tiny_cpu my_cpu (
        .clk(clk),
        .reset(~rst_n), 
        .keyboard_in(ui_in), 
        .screen_out(uo_out)
    );
endmodule

module tiny_cpu (
    input wire clk,
    input wire reset,
    input wire [7:0] keyboard_in,
    output reg [7:0] screen_out
);
    reg [2:0] pc;
    reg [7:0] reg_a, reg_b;
    
    // REDUCED TO 16 BYTES: Leaves enough room for CTS and timing buffers.
    reg [7:0] ram [15:0];  
    
    wire [7:0] instruction;
    
    wire [1:0] opcode = instruction[7:6];
    wire [2:0] jump_addr = instruction[2:0]; 
    wire reg_sel = instruction[3];  
    wire imm_mode = instruction[4];
    
    // Use the bottom 4 bits of reg_b as the RAM address (0 to 15)
    wire [3:0] ram_addr = reg_b[3:0];
    wire [7:0] alu_result = reg_a + ram[ram_addr];

    // HARDWIRED ROM
    assign instruction = (pc == 3'd0) ? 8'h10 :
                         (pc == 3'd1) ? 8'h18 :
                         (pc == 3'd2) ? 8'h40 :
                         (pc == 3'd3) ? 8'h80 :
                         (pc == 3'd4) ? 8'hC0 :
                         (pc == 3'd5) ? 8'hD5 : 8'h00;
    
    always @(posedge clk) begin
        if (reset) begin
            pc <= 3'b000;
            reg_a <= 8'h00;
            reg_b <= 8'h00;
            screen_out <= 8'h20;  // Space character
        end else begin
            case (opcode)
                2'b00: begin  // ADD/LOAD
                    if (imm_mode) begin
                        if (reg_sel) reg_b <= keyboard_in;
                        else reg_a <= keyboard_in;
                    end else begin
                        if (reg_sel) reg_b <= alu_result;
                        else reg_a <= alu_result;
                    end
                    pc <= pc + 1;
                end
                
                2'b01: begin  // STORE to RAM
                    ram[ram_addr] <= reg_sel ? reg_b : reg_a;
                    pc <= pc + 1;
                end
                
                2'b10: begin  // LOAD from RAM
                    if (imm_mode) begin
                        if (reg_sel) reg_b <= keyboard_in;
                        else reg_a <= keyboard_in;
                    end else begin
                        if (reg_sel) reg_b <= ram[ram_addr];
                        else reg_a <= ram[ram_addr];
                    end
                    pc <= pc + 1;
                end
                
                2'b11: begin  // STORE to screen / JUMP
                    if (imm_mode) begin
                        pc <= jump_addr;  // JUMP
                    end else begin
                        screen_out <= reg_sel ? reg_b : reg_a;
                        pc <= pc + 1;
                    end
                end
            endcase
        end
    end
endmodule
"""#
}
