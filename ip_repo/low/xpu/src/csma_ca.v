// Xianjun jiao. putaoshu@msn.com; xianjun.jiao@imec.be;

`timescale 1 ns / 1 ps

// `define DEBUG_PREFIX (*mark_debug="true",DONT_TOUCH="TRUE"*)
`define DEBUG_PREFIX

	module csma_ca #
	(
	  parameter integer RSSI_HALF_DB_WIDTH = 11
	)
	(// simple csma/ca, still need lots of improvements
    input wire clk,
    input wire rstn,
    
    input wire tsf_pulse_1M,

    input  wire pkt_header_valid,
    input  wire pkt_header_valid_strobe,
    input  wire [7:0] signal_rate,
    input  wire [15:0] signal_len,

    input  wire fcs_in_strobe,
    input  wire fcs_valid,

    input wire nav_enable,
    input wire difs_enable,
    input wire eifs_enable,
    input wire [3:0] cw_min,
    input wire [6:0] preamble_sig_time,
    input wire [4:0] ofdm_symbol_time,
    input wire [4:0] slot_time,
    input wire [6:0] sifs_time,
    input wire [6:0] phy_rx_start_delay_time,
    input wire [7:0] difs_advance,
    input wire [7:0] backoff_advance,

    input wire addr1_valid,
    input wire [47:0] addr1,
    input wire [47:0] self_mac_addr,

    input wire FC_DI_valid,
    input wire [1:0] FC_type,
    input wire [3:0] FC_subtype,
    input wire [15:0] duration,

    input wire [1:0] random_seed,
    input wire ch_idle,

    input wire slice_en0,
    input wire slice_en1,
    input wire slice_en2,
    input wire slice_en3,
    input wire retrans_trigger,
    input wire quit_retrans,
    input wire high_trigger,
    input wire tx_bb_is_ongoing,
    input wire ack_tx_flag,

    output wire high_tx_allowed0,
    output wire high_tx_allowed1,
    output wire high_tx_allowed2,
    output wire high_tx_allowed3,
    `DEBUG_PREFIX output reg [9:0] num_slot_random_log_dl,
    `DEBUG_PREFIX output reg increase_cw,
    `DEBUG_PREFIX output reg cw_used_dl,
    `DEBUG_PREFIX output wire backoff_done
	);

    localparam [2:0]  IDLE =                 3'b000,
                      BACKOFF_CH_BUSY =      3'b001,
                      BACKOFF_WAIT_1 =       3'b010,
                      BACKOFF_WAIT_2 =       3'b011,
                      BACKOFF_RUN =          3'b100,
                      BACKOFF_SUSPEND =      3'b101,
                      BACKOFF_WAIT_FOR_OWN = 3'b110;

    localparam [1:0]  NAV_IDLE =              2'b00,
                      NAV_WAIT_FOR_DURATION = 2'b01,
                      NAV_CHECK_RA =          2'b10,
                      NAV_UPDATE =            2'b11;
    `DEBUG_PREFIX reg [2:0]  backoff_state;

    `DEBUG_PREFIX reg [1:0]  nav_state;
    `DEBUG_PREFIX reg [1:0]  nav_state_old;
    `DEBUG_PREFIX wire ch_idle_final;

    `DEBUG_PREFIX reg [14:0] nav;
    `DEBUG_PREFIX reg [14:0] nav_new;
    `DEBUG_PREFIX reg nav_reset;
    `DEBUG_PREFIX reg nav_set;
    `DEBUG_PREFIX wire [14:0] nav_for_mac;

    wire [7:0] ackcts_n_sym;
    wire [7:0] ackcts_time;
    `DEBUG_PREFIX reg  is_rts_received;
    `DEBUG_PREFIX reg  [14:0] nav_reset_timeout_count;
    `DEBUG_PREFIX reg  [14:0] nav_reset_timeout_top_after_rts;
    `DEBUG_PREFIX wire is_pspoll;
    `DEBUG_PREFIX wire is_rts;

    `DEBUG_PREFIX wire [11:0] longest_ack_time;
    `DEBUG_PREFIX wire [11:0] difs_time;
    `DEBUG_PREFIX wire [11:0] eifs_time;
    `DEBUG_PREFIX reg last_fcs_valid;
    `DEBUG_PREFIX reg take_new_random_number;
    `DEBUG_PREFIX reg [9:0]  num_slot_random;
    `DEBUG_PREFIX reg [31:0] random_number = 32'h0b00a001;
    `DEBUG_PREFIX reg [12:0] backoff_timer;
    `DEBUG_PREFIX reg [11:0] backoff_wait_timer;
    `DEBUG_PREFIX reg cw_used;
    `DEBUG_PREFIX reg cw_used_dl_int;
    `DEBUG_PREFIX reg [9:0] num_slot_random_log;
    `DEBUG_PREFIX reg [9:0] num_slot_random_log_dl_int;
    
    
    //(* mark_debug = "true", DONT_TOUCH = "TRUE" *) 
    //wire backoff_done;

    assign is_pspoll = (((FC_type==2'b01) && (FC_subtype==4'b1010))?1:0);
    assign is_rts    = (((FC_type==2'b01) && (FC_subtype==4'b1011) && (signal_len==20))?1:0);//20 is the length of rts frame

    assign ackcts_time = preamble_sig_time + ofdm_symbol_time*ackcts_n_sym;
    assign nav_for_mac = (nav_enable?nav:0);
    
    assign longest_ack_time = 44;
    assign difs_time = ( difs_enable?(sifs_time + 2*slot_time):0 );
    assign eifs_time = ( eifs_enable?(sifs_time + difs_time + longest_ack_time):0 );

    assign ch_idle_final = (ch_idle&&(nav_for_mac==0));
    assign backoff_done =   (backoff_state==BACKOFF_WAIT_FOR_OWN);
    assign high_tx_allowed0 = (backoff_done && slice_en0);
    assign high_tx_allowed1 = (backoff_done && slice_en1);
    assign high_tx_allowed2 = (backoff_done && slice_en2);
    assign high_tx_allowed3 = (backoff_done && slice_en3);

    n_sym_len14_pkt # (
    ) n_sym_ackcts_pkt_i (
      .ht_flag(signal_rate[7]),
      .rate_mcs(signal_rate[3:0]),
      .n_sym(ackcts_n_sym[2:0])
    );

    // nav update process
    always @(posedge clk) 
    begin
      if (!rstn) begin
        nav<=0;
        nav_new<=0;
        nav_reset<=0;
        nav_set<=0;
        is_rts_received<=0;
        nav_reset_timeout_count<=0;
        nav_reset_timeout_top_after_rts<=0;
        nav_state<=NAV_IDLE;
        nav_state_old<=NAV_IDLE;
      end else begin
        //nav setting/resetting and count down until 0
        if (nav_reset) begin
          nav <= 0;
          is_rts_received<=0;//if timeout after we observe a rts, after reset nav we should forget the rts we received
        end else if (nav_set) begin
          nav <= (nav_new>nav?nav_new:nav);
        end else begin 
          nav <= (nav!=0?(tsf_pulse_1M?(nav-1):nav):nav);
        end

        nav_state_old<=nav_state;

        if (pkt_header_valid_strobe) begin //pkt_header_valid_strobe is reset signal of nav state machine in case openofdm_rx core runs into abnormal status where fcs strobe never happen
          nav_new<=0;
          nav_reset<=0;
          nav_set<=0;
          if (pkt_header_valid) begin
            nav_state<=NAV_WAIT_FOR_DURATION;
          end else begin
            nav_state<=NAV_IDLE;
          end
        end else begin// //decide new nav value
          //here we do nav reset after long time no pkt arrival following previous rts nav update
          nav_reset_timeout_count <= (is_rts_received==0?0:(tsf_pulse_1M?(nav_reset_timeout_count+1):nav_reset_timeout_count));
          nav_reset <= (nav_reset_timeout_count>nav_reset_timeout_top_after_rts);

          case (nav_state)
            NAV_IDLE: begin
              nav_new<=0;
              nav_set<=0;
              nav_state<=nav_state;
            end

            NAV_WAIT_FOR_DURATION: begin
              if ( FC_DI_valid && duration[15]==0 ) begin
                nav_state<=NAV_CHECK_RA;
              end else begin
                nav_state<=nav_state;//anyhow we stay here until next reset pkt_header_valid_strobe
              end
            end

            NAV_CHECK_RA: begin // if RA is for us, we stay here until next reset pkt_header_valid_strobe because we don't need to udpate NAV: 802.11-2012. 9.3.2.4 Setting and resetting the NAV
              nav_state<=( (addr1_valid&&(addr1!=self_mac_addr))?NAV_UPDATE:nav_state );
            end
            
            NAV_UPDATE: begin
              nav_state<=(fcs_valid?NAV_IDLE:nav_state); //generate nav_set&nav_new and goto&stay idle until next reset pkt_header_valid_strobe
              nav_set<=fcs_valid;
              if (is_pspoll) begin
                nav_new<=ackcts_time+sifs_time;//9.3.2.4 Setting and resetting the NAV
              end else begin
                nav_new<=duration[14:0];
              end

              if (fcs_valid) begin
                if (is_rts) begin
                  is_rts_received <= 1;
                  nav_reset_timeout_top_after_rts<=(2*sifs_time + ackcts_time + phy_rx_start_delay_time + 2*slot_time);
                end else begin
                  is_rts_received <= 0;
                  nav_reset_timeout_top_after_rts<=nav_reset_timeout_top_after_rts;
                end
              end
            end
            
          endcase
        end
      end
    end
    
    // random number generator
    always @(posedge clk)
      if (!rstn)
         random_number <= 32'h1020f0cb;
      else if (take_new_random_number) begin
         random_number[31:1] <= random_number[30:0];
         random_number[0] <= ~^{random_number[31], random_number[21], random_number[1:0]};
      end

    always @( random_number[9:0], random_seed, cw_min[3:0] )
      begin
        case (cw_min[3:0])
          4'd0 : begin 
                num_slot_random = 0;
                end
          4'd1 : begin 
                num_slot_random = {9'h0,random_number[0]^random_seed[1]};
                end
          4'd2 : begin 
                num_slot_random = {8'h0,random_number[1],random_number[0]};
                end
          4'd3 : begin 
                num_slot_random = {7'h0,random_number[2]^random_seed[0],random_number[1]^random_seed[1],random_number[0]};
                end
          4'd4 : begin
                num_slot_random = {6'h0,random_number[3],random_number[2]^random_seed[0],random_number[1]^random_seed[1],random_number[0]};
                end
          4'd5 : begin
                num_slot_random = {5'h0,random_number[4]^random_seed[0],random_number[3],random_number[2]^random_seed[0],random_number[1]^random_seed[1],random_number[0]};
                end
          4'd6 : begin
                num_slot_random = {4'h0,random_number[5],random_number[4],random_number[3],random_number[2]^random_seed[0],random_number[1],random_number[0]^random_seed[1]};
                end
          4'd7 : begin
                num_slot_random = {3'h0,random_number[6],random_number[5]^random_seed[0],random_number[4],random_number[3],random_number[2],random_number[1]^random_seed[1],random_number[0]};
                end
          4'd8 : begin
                num_slot_random = {2'h0,random_number[7],random_number[6]^random_seed[1],random_number[5],random_number[4]^random_seed[0],random_number[3],random_number[2],random_number[1],random_number[0]^random_seed[1]};
                end
          4'd9 : begin
                num_slot_random = {1'h0,random_number[8],random_number[7]^random_seed[0],random_number[6],random_number[5]^random_seed[1],random_number[4],random_number[3]^random_seed[0],random_number[2],random_number[1]^random_seed[1],random_number[0]};
                end
          4'd10: begin
                num_slot_random = {random_number[9],random_number[8]^random_seed[0],random_number[7]^random_seed[1],random_number[6],random_number[5],random_number[4]^random_seed[1],random_number[3],random_number[2],random_number[1]^random_seed[0],random_number[0]};
                end                
          default: begin
                num_slot_random = {7'h0,random_number[2]^random_seed[0],random_number[1],random_number[0]^random_seed[1]};
                end
        endcase
      end

    // media access random backoff state machine
    always @(posedge clk) 
    begin
      if (!rstn) begin
        backoff_timer<=0;
        backoff_wait_timer<=0;
        last_fcs_valid<=0;
        take_new_random_number<=0;
        backoff_state<=IDLE;
        num_slot_random_log<=0 ;
        num_slot_random_log_dl_int<=0;
        num_slot_random_log_dl<=0;
        increase_cw<=0 ;
        cw_used<=0;
        cw_used_dl<=0;
        cw_used_dl_int<=0;
      end else begin
        last_fcs_valid <= (fcs_in_strobe?fcs_valid:last_fcs_valid);
        cw_used_dl_int <= cw_used ;
        cw_used_dl <= cw_used_dl_int; // dl cw used flag by two clock pulses, to insure cw is logged correctly if quit_retrans issued
        num_slot_random_log_dl_int<=num_slot_random_log;
        num_slot_random_log_dl<=num_slot_random_log_dl_int; 
        case (backoff_state)
          IDLE: begin
            cw_used<=((high_trigger || quit_retrans)?0:cw_used);
            num_slot_random_log<=((high_trigger || quit_retrans)?0:num_slot_random_log);
            backoff_timer<=0;
            take_new_random_number<=0;
            if(ch_idle_final) begin
              if((high_trigger ==1) || (quit_retrans==1)) begin
                backoff_state<=BACKOFF_WAIT_1;
                increase_cw<=0;
                if (last_fcs_valid) begin
                  backoff_wait_timer<=(difs_time==0?0:(difs_time - difs_advance));
                end else begin
                  backoff_wait_timer<=(eifs_time==0?0:(eifs_time - difs_advance));
                end              
              end else if (retrans_trigger==1) begin
                backoff_state<=BACKOFF_WAIT_2;
                increase_cw<=(cw_used?1:0);
                if (last_fcs_valid) begin
                  backoff_wait_timer<=(difs_time==0?0:(difs_time - difs_advance));
                end else begin
                  backoff_wait_timer<=(eifs_time==0?0:(eifs_time - difs_advance));
                end                
              end
            end else begin
              if((high_trigger==1) || (retrans_trigger==1) || (quit_retrans==1)) begin
                backoff_state<=BACKOFF_CH_BUSY; 
                increase_cw<=(retrans_trigger?(cw_used?1:0):0);
                backoff_wait_timer<=0;
              end  
            end
          end // end IDLE

          BACKOFF_CH_BUSY: begin
            backoff_timer<=0;
            take_new_random_number<=0;
            increase_cw<=0;
            cw_used<=((high_trigger || quit_retrans)?0:cw_used);
            num_slot_random_log<=((high_trigger || quit_retrans)?0:num_slot_random_log);
            if (!ch_idle_final) begin
              backoff_wait_timer<=0;
              backoff_state<=backoff_state;
            end else begin
              if (last_fcs_valid) begin
                backoff_wait_timer <= (difs_time==0?0:(difs_time - difs_advance));
              end else begin
                backoff_wait_timer <= (eifs_time==0?0:(eifs_time - difs_advance));
              end
              backoff_state<=BACKOFF_WAIT_2;
            end 
          end  // end CH_BUSY  

          BACKOFF_WAIT_1: begin
            backoff_wait_timer<=( backoff_wait_timer==0?backoff_wait_timer:(tsf_pulse_1M?(backoff_wait_timer-1):backoff_wait_timer) );
            take_new_random_number<=0;
            backoff_timer<=0;
            cw_used<=0;
            num_slot_random_log<=0;
            if (ch_idle_final) begin
              if (backoff_wait_timer==0) begin
                backoff_state<=BACKOFF_WAIT_FOR_OWN;
              end else begin
                backoff_state<=backoff_state;
              end
            end else begin
              backoff_state<=BACKOFF_CH_BUSY;
            end
          end // end WAIT1

          BACKOFF_WAIT_2: begin
            backoff_wait_timer<=( backoff_wait_timer==0?backoff_wait_timer:(tsf_pulse_1M?(backoff_wait_timer-1):backoff_wait_timer) );
            cw_used<=((high_trigger || quit_retrans)?0:1);
            if((backoff_wait_timer == 2) && tsf_pulse_1M) begin
              take_new_random_number<=1;
            end else begin
              take_new_random_number<=0;
            end
            if (ch_idle_final) begin
              increase_cw<=0;
              if(quit_retrans==1) begin
                backoff_state<=BACKOFF_WAIT_1; // avoid additional back off for a new packet
                num_slot_random_log<=num_slot_random_log;
              end else begin
                if (backoff_wait_timer==0) begin
                  backoff_state<=BACKOFF_RUN;
                  backoff_timer<=(num_slot_random==0?0:((num_slot_random*slot_time) - backoff_advance));
                  num_slot_random_log <= num_slot_random;
                end else begin
                  backoff_state<=backoff_state;
                  backoff_timer<=0;
                  num_slot_random_log<=num_slot_random_log;
                end
              end
            end else begin
              backoff_state<=BACKOFF_CH_BUSY;
              increase_cw<=1;
              backoff_timer<=0;
              num_slot_random_log<=((high_trigger || quit_retrans)?0:num_slot_random_log);
            end
          end // end WAIT2

          BACKOFF_RUN: begin
            take_new_random_number<=0;
            cw_used<=((high_trigger || quit_retrans)?0:1);
            num_slot_random_log<=((high_trigger || quit_retrans)?0:num_slot_random_log);
            if (ch_idle_final) begin
              backoff_timer<=( backoff_timer==0?backoff_timer:(tsf_pulse_1M?(backoff_timer-1):backoff_timer) );
              increase_cw<=0;
              if(quit_retrans==1) begin
                backoff_state<=BACKOFF_WAIT_1;
                if (last_fcs_valid) begin
                  backoff_wait_timer<=(backoff_timer>difs_time?(difs_time==0?0:(difs_time - difs_advance)):backoff_timer);
                end else begin
                  backoff_wait_timer<=(backoff_timer>eifs_time?(eifs_time==0?0:(eifs_time - difs_advance)):backoff_timer);
                end
              end else begin
                backoff_wait_timer<=backoff_wait_timer;
                if (backoff_timer==0) begin
                  backoff_state<=BACKOFF_WAIT_FOR_OWN;
                end else begin
                  backoff_state<=backoff_state;
                end
              end
            end else begin
              backoff_timer<=backoff_timer;
              backoff_wait_timer<=backoff_wait_timer;
              if (backoff_timer==0) begin
                backoff_state<=BACKOFF_CH_BUSY;
                increase_cw<=1;
              end else begin
                increase_cw<=0;
                backoff_state<=BACKOFF_SUSPEND;
              end
            end
          end // end RUN

          BACKOFF_SUSPEND: begin // data is calculated by calc_phy_header C program
            take_new_random_number<=0;
            backoff_timer<=backoff_timer;
            num_slot_random_log<=((high_trigger || quit_retrans)?0:num_slot_random_log);
            cw_used<=((high_trigger || quit_retrans)?0:1);
            if (ch_idle_final) begin
              if(quit_retrans==1) begin
                backoff_state<=BACKOFF_WAIT_1;
                if (last_fcs_valid) begin
                  backoff_wait_timer<=(backoff_timer>difs_time?(difs_time==0?0:(difs_time - difs_advance)):backoff_timer);
                end else begin
                  backoff_wait_timer<=(backoff_timer>eifs_time?(eifs_time==0?0:(eifs_time - difs_advance)):backoff_timer);
                end
              end else begin
                backoff_state<=BACKOFF_RUN;
                backoff_wait_timer<=backoff_wait_timer;
              end
            end else begin
              backoff_wait_timer<=backoff_wait_timer;
              if(quit_retrans==1) begin
                backoff_state<=BACKOFF_CH_BUSY;
              end else begin
                backoff_state<=backoff_state;
              end
            end
          end // end SUSPEND

          BACKOFF_WAIT_FOR_OWN: begin
            cw_used<=((high_trigger || quit_retrans)?0:cw_used);
            num_slot_random_log<=((high_trigger || quit_retrans)?0:num_slot_random_log);
            if(tx_bb_is_ongoing) begin
                if (ack_tx_flag) begin
                  backoff_state<=BACKOFF_CH_BUSY;
                  increase_cw<=1;
                end else begin
                  increase_cw<=0;
                  backoff_state<=IDLE;
                end
            end
          end     


        endcase
      end
  end
	endmodule
