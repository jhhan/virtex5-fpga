/*******************************************************************************
*
*  NetFPGA-10G http://www.netfpga.org
*
*  File:
*        rx_tlp_trigger.v
*
*  Project:
*
*
*  Author:
*        Marco Forconesi
*
*  Description:
*        When enough (good) data is in the internal buffer, a TLP is sent.
*        Ethernet frame boundaries are not taken in consideration.
*
*        TODO: 
*        Fast timeout has to be implemented when sw is ready for it.
*
*    This code is initially developed for the Network-as-a-Service (NaaS) project.
*
*  Copyright notice:
*        Copyright (C) 2014 University of Cambridge
*
*  Licence:
*        This file is part of the NetFPGA 10G development base package.
*
*        This file is free code: you can redistribute it and/or modify it under
*        the terms of the GNU Lesser General Public License version 2.1 as
*        published by the Free Software Foundation.
*
*        This package is distributed in the hope that it will be useful, but
*        WITHOUT ANY WARRANTY; without even the implied warranty of
*        MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
*        Lesser General Public License for more details.
*
*        You should have received a copy of the GNU Lesser General Public
*        License along with the NetFPGA source package.  If not, see
*        http://www.gnu.org/licenses/.
*
*/

//////////////////////////////////////////////////////////////////////////////////////////////
//////////////////////////////////////////////////////////////////////////////////////////////
`timescale 1ns / 1ps
//`default_nettype none
`include "includes.v"

module rx_tlp_trigger (

    input    clk,
    input    reset,

    // Internal logic
    input      [`BF:0]      commited_wr_addr,
    output reg              trigger_tlp,
    input                   trigger_tlp_ack,
    output reg              change_huge_page,
    input                   change_huge_page_ack,
    output reg              send_last_tlp,
    output reg              send_tail_tlp,
    output reg              send_numb_qws,
    input                   send_numb_qws_ack,
    output reg [4:0]        qwords_to_send
    );

    // localparam
    localparam s0  = 16'b0000000000000000;
    localparam s1  = 16'b0000000000000001;
    localparam s2  = 16'b0000000000000010;
    localparam s3  = 16'b0000000000000100;
    localparam s4  = 16'b0000000000001000;
    localparam s5  = 16'b0000000000010000;
    localparam s6  = 16'b0000000000100000;
    localparam s7  = 16'b0000000001000000;
    localparam s8  = 16'b0000000010000000;
    localparam s9  = 16'b0000000100000000;
    localparam s10 = 16'b0000001000000000;
    localparam s11 = 16'b0000010000000000;
    localparam s12 = 16'b0000100000000000;
    localparam s13 = 16'b0001000000000000;
    localparam s14 = 16'b0010000000000000;
    localparam s15 = 16'b0100000000000000;
    localparam s16 = 16'b1000000000000000;

    //-------------------------------------------------------
    // Local timeout-generation
    //-------------------------------------------------------
    reg     [15:0]       free_running;
    reg                  timeout;

    //-------------------------------------------------------
    // Local trigger-logic
    //-------------------------------------------------------
    reg     [15:0]       trigger_fsm;
    reg     [`BF:0]      diff;
    reg     [`BF:0]      diff_reg;
    reg     [`BF:0]      commited_rd_addr;
    reg     [`BF:0]      look_ahead_commited_rd_addr;
    reg                  huge_page_dirty;
    reg     [18:0]       huge_buffer_qword_counter;
    reg     [18:0]       aux_huge_buffer_qword_counter;
    reg     [18:0]       aux2_huge_buffer_qword_counter;
    reg     [18:0]       look_ahead_huge_buffer_qword_counter;
    reg     [3:0]        qwords_remaining;
    reg     [4:0]        number_of_tlp_sent;
    reg     [4:0]        look_ahead_number_of_tlp_sent;
    reg     [4:0]        number_of_tlp_to_send;
    reg                  rx_idle;

    ////////////////////////////////////////////////
    // timeout logic
    ////////////////////////////////////////////////
    always @(posedge clk) begin
        if (reset) begin  // reset
            timeout <= 1'b0;
            free_running <= 'b0;
        end
        
        else begin  // not reset

            timeout <= 1'b0;
            free_running <= 'b0;

            if (rx_idle) begin
                free_running <= free_running +1;
                if (free_running == 'h40) begin
                    timeout <= 1'b1;
                end
            end

        end     // not reset
    end  //always

    ////////////////////////////////////////////////
    // trigger-logic
    ////////////////////////////////////////////////
    always @(posedge clk) begin
        
        if (reset) begin  // reset
            trigger_tlp <= 1'b0;
            change_huge_page <= 1'b0;
            send_last_tlp <= 1'b0;
            send_tail_tlp <= 1'b0;
            send_numb_qws <= 1'b0;

            diff <= 'b0;
            commited_rd_addr <= 'b0;
            huge_buffer_qword_counter <= 'h10;
            huge_page_dirty <= 1'b0;
            qwords_remaining <= 'b0;

            rx_idle <= 1'b0;
            trigger_fsm <= s0;
        end

        else begin  // not reset

            rx_idle <= 1'b0;

            diff <= commited_wr_addr + (~commited_rd_addr) +1;
            
            case (trigger_fsm)

                s0 : begin
                    rx_idle <= 1'b1;
                    look_ahead_huge_buffer_qword_counter <= huge_buffer_qword_counter + diff;
                    diff_reg <= diff;
                    number_of_tlp_to_send <= diff[`BF:4];

                    if (diff >= 'h10) begin
                        trigger_fsm <= s1;
                    end
                    else if ( (huge_page_dirty) && (timeout) ) begin
                        trigger_fsm <= s9;
                    end
                    else if ( (diff) && (timeout) ) begin
                        trigger_fsm <= s14;
                    end
                end

                s1 : begin
                    huge_page_dirty <= 1'b1;
                    number_of_tlp_sent <= 'b0;
                    if (look_ahead_huge_buffer_qword_counter[18]) begin       // 2MB
                        if (!qwords_remaining) begin
                            change_huge_page <= 1'b1;
                            trigger_fsm <= s5;
                        end
                        else begin
                            qwords_to_send <= {1'b0, qwords_remaining};
                            send_last_tlp <= 1'b1;
                            trigger_fsm <= s6;
                        end
                    end
                    else begin
                        qwords_to_send <= 'h10;
                        trigger_tlp <= 1'b1;
                        qwords_remaining <= diff_reg[3:0];
                        trigger_fsm <= s2;
                    end
                end

                s2 : begin
                    look_ahead_commited_rd_addr <= commited_rd_addr + qwords_to_send;
                    look_ahead_number_of_tlp_sent <= number_of_tlp_sent +1;
                    aux_huge_buffer_qword_counter <= huge_buffer_qword_counter + qwords_to_send;
                    if (trigger_tlp_ack) begin
                        trigger_tlp <= 1'b0;
                        trigger_fsm <= s3;
                    end
                end

                s3 : begin
                    commited_rd_addr <= look_ahead_commited_rd_addr;
                    number_of_tlp_sent <= look_ahead_number_of_tlp_sent;
                    huge_buffer_qword_counter <= aux_huge_buffer_qword_counter;
                    trigger_fsm <= s4;
                end

                s4 : begin
                    if (number_of_tlp_sent < number_of_tlp_to_send) begin
                        trigger_tlp <= 1'b1;
                        trigger_fsm <= s2;
                    end
                    else begin
                        trigger_fsm <= s0;
                    end
                end

                s5 : begin
                    huge_page_dirty <= 1'b0;
                    huge_buffer_qword_counter <= 'h10;
                    if (change_huge_page_ack) begin
                        change_huge_page <= 1'b0;
                        trigger_fsm <= s0;
                    end
                end

                s6 : begin
                    look_ahead_commited_rd_addr <= commited_rd_addr + qwords_to_send;
                    if (change_huge_page_ack) begin
                        send_last_tlp <= 1'b0;
                        trigger_fsm <= s7;
                    end
                end

                s7 : begin
                    commited_rd_addr <= look_ahead_commited_rd_addr;
                    huge_buffer_qword_counter <= 'h10;
                    qwords_remaining <= 'b0;
                    huge_page_dirty <= 1'b0;
                    trigger_fsm <= s8;
                end

                s8 : begin
                    // delay: diff
                    trigger_fsm <= s0;
                end

                s9 : begin
                    if (!qwords_remaining) begin
                        send_numb_qws <= 1'b1;
                        trigger_fsm <= s10;
                    end
                    else begin
                        trigger_fsm <= s11;
                    end
                end

                s10 : begin
                    huge_page_dirty <= 1'b0;
                    if (send_numb_qws_ack) begin
                        send_numb_qws <= 1'b0;
                        trigger_fsm <= s0;
                    end
                end

                s11 : begin
                    aux2_huge_buffer_qword_counter <= huge_buffer_qword_counter + 'h10;
                    qwords_to_send <= {1'b0, qwords_remaining};
                    if (huge_buffer_qword_counter == 'h3FFF0) begin
                        send_last_tlp <= 1'b1;
                        trigger_fsm <= s6;
                    end
                    else begin
                        send_tail_tlp <= 1'b1;
                        trigger_fsm <= s12;
                    end
                end

                s12 : begin
                    look_ahead_commited_rd_addr <= commited_rd_addr + qwords_to_send;
                    if (send_numb_qws_ack) begin
                        send_tail_tlp <= 1'b0;
                        trigger_fsm <= s13;
                    end
                end

                s13 : begin
                    commited_rd_addr <= look_ahead_commited_rd_addr;
                    huge_buffer_qword_counter <= aux2_huge_buffer_qword_counter;
                    qwords_remaining <= 'b0;
                    huge_page_dirty <= 1'b0;
                    trigger_fsm <= s8;
                end

                s14 : begin
                    aux2_huge_buffer_qword_counter <= huge_buffer_qword_counter + 'h10;
                    qwords_to_send <= diff_reg;
                    if (huge_buffer_qword_counter == 'h3FFF0) begin
                        send_last_tlp <= 1'b1;
                        trigger_fsm <= s6;
                    end
                    else begin
                        send_tail_tlp <= 1'b1;
                        trigger_fsm <= s12;
                    end
                end
                
                default : begin
                    trigger_fsm <= s0;
                end

            endcase

        end     // not reset
    end  //always

endmodule // rx_tlp_trigger

//////////////////////////////////////////////////////////////////////////////////////////////
//////////////////////////////////////////////////////////////////////////////////////////////