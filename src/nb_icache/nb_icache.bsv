package nb_icache;
    import icache_tagram    ::*;
    import icache_dataram   ::*;
    import icache_mhb       ::*;
    import icache_types     ::*;

    interface Ifc_nb_icache;
        // Inputs
        module ma_core_request(ICache_core_request core_req);
        module ma_ptw_response(PTW_response ptw_response);
        module ma_mem_response(Mem_response mem_response);
        module ma_csr_status(Bit#(2) prv, Bit#(`xlen), mstatus, Bit#(`xlen) satp);
        // Outputs 
        module ICache_core_response mv_core_response();
        module PTW_request mv_ptw_request();
        module Mem_request mv_mem_request();
        module ICache_status mv_icache_status();
    endinterface
    (*synthesize*)
    module mknb_icache(Ifc_nb_icache);
    // Registers 
    Reg#(Bool) rg_replay_valid <- mkReg(False);
    Reg#(Stage1) rg_replay_req_data <- mkReg(unpack(0));
    Reg#(Bool) rg_tlb_miss <- mkReg(False);
    Reg#(Bool) rg_fence <- mkReg(False);
    Reg#(Bool) rg_sfence  <- mkReg(False);
    Reg#(Bool) rg_io_request_valid <- mkReg(False);
    Reg#(Bool) rg_set_conflict <- mkReg(False);
    //
    Reg#(PTW_response) rg_ptw_reponse <- mkReg(unpack(0));
    //
    Reg#(Bool) rg_stage2_valid <- mkReg(False);
    Reg#(Stage2) rg_stage2_req_data <- mkReg(unpack(0));
    //
    Reg#(Bool) rg_fill_valid <- mkReg(False);
    Reg#(Mem_response) rg_fill_data <- mkReg(False);
    // Wires
    Wire#(Bool) wr_flush <- mKDWire(False);
    Wire#(Bool) wr_replay <- mkDWire(False);
    Wire#(Bool) wr_icache_busy <- mkDWire(False);
    Wire#(Bool) wr_no_pending_requests <- mkDWire(False);
    Wire#(ICache_core_request) wr_core_req <- mkDWire(unpack(0));
    Wire#(Mem_response) wr_mem_response <- mkDWire(unpack(0));
    // Initialize structures
    Vector#(`numsets, Reg#(Bit#(`numways))) rg_icache_valid <- replicateM(mkReg(0));
    Ifc_icache_tagram ifc_tag <- mkicache_tagram();
    Ifc_icache_dataram ifc_data <- mkicache_dataram();
    Ifc_icache_mhb ifc_mhb <- mkicache_mhb();
    Ifc_replace#(`numsets,`numways) ifc_replacement <- mkreplace(`irepl);
    //
    rule rl_check_cache_busy;
        ICache_status lv_status = unpack(0);
        // Cache busy is set if MHB all primary entries full 
        // or valid request to replayed 
        // or a valid request stalled in stage 2
        lv_status.cache_busy = (ifc_mhb.mv_mshr_full || rg_replay_valid || rg_stage2_valid);
        lv_status.mshr_status = ifc_mhb.mv_mshr_count_free();
        wr_icache_busy <= lv_status;
    endrule
    //
    rule rl_check_pending_requests;
        wr_no_pending_requests <= (!rg_stage2.valid && !rg_replay_valid && ifc_mhb.mv_mshr_empty());
    endrule
    //
    rule rl_stage1_no_pending_requests_or_replay(wr_no_pending_requests && !wr_flush); // stage 1: no requests pending
        let lv_core_req = wr_core_req;
        if(lv_core_req.valid) begin
            // lookup TLB // TODO  
            Bool lv_set_conflict =  False; // TODO  
            Bool lv_tlb_hit = False; // TODO  
            Bool lv_tlb_is_io = False; // TODO  
            // index into 4 arrays: status, repl, tag, data.  // TODO  
            if(lv_core_req.fence) begin
                // invalidate all cache entries
                rg_icache_valid <= unpack(0);  
            end
            else if(lv_core_req.sfence) begin
                //invalidate TLB // TODO
            end
            else if(lv_tlb_hit && !lv_tlb_is_io && !lv_set_conflict && !ifc_mhb.mv_mshr_full ) begin // TODO  
                rg_stage2_valid <= True;
                rg_stage2_req_data <=  //TODO: insert all pertinent data
            end
            else if(lv_tlb_hit && lv_tlb_is_io) begin
                // send request to fabric //TODO
                rg_replay_valid <= True; // Is not actuall replayed, just to stall Cache till response is received from fabric
                rg_io_request_valid <= True; 
                rg_replay_req_data <= lv_core_req;
            end
            else begin
                rg_replay_valid <= True;
                rg_replay_req_data <= lv_core_req;
                if(!lv_tlb_hit) begin
                    rg_tlb_miss <= True; // takes priority over set_conflict
                end
                else if(lv_set_conflict) begin
                    rg_set_conflict <= True;
                end
                
            end
        end
    endrule
    //
    rule rl_stage1_pending_requests(!wr_no_pending_requests && !wr_flush); // stage 1: requests pending
        // request pending in stage 2 or MHB not empty
        if(!rg_replay_valid) begin
            if(wr_core_req.valid) begin
                // All core requests are saved
                rg_replay_valid <= True;
                rg_replay_req_data <= wr_core_req;
                // tlb_response = lookup TLB // TODO  
                // index into 4 arrays: status, repl, tag, data. & store the response // TODO
                // check for fence/sfence
                if(wr_core_req.fence || wr_core_req.sfence) begin
                    rg_fence <= wr_core_req.fence;
                    rg_sfence <= wr_core_req.sfence;
                end
                else if(tlb_response.hit && tlb_response.is_io) begin 
                    rg_io_request_valid <= True;
                end
            end
        end
        // cache_busy: handling pending requests
        else begin
            wr_replay <= True;
        end 
    endrule
    // replay the pending requests, only if no request pending in stage 2
    rule rl_replay_req(wr_replay && !rg_stage2.valid && !wr_flush );
        let lv_core_req = rg_replay_req_data;
        // lookup TLB // TODO  
        Bool lv_set_conflict =  False; // TODO  
        Bool lv_tlb_hit = False; // TODO  
        Bool lv_tlb_is_io = False; // TODO  
        // index into 4 arrays: status, repl, tag, data.  // TODO  
        if(lv_core_req.fence && ifc_mhb.mv_mshr_empty()) begin
            // invalidate all cache entries
            rg_icache_valid <= unpack(0);  
            rg_fence <= False;
            rg_replay_valid <= False;
        end
        else if(lv_core_req.sfence && ifc_mhb.mv_mshr_empty()) begin
            //invalidate TLB // TODO
            rg_sfence <= False;
            rg_replay_valid <= False;
        end
        else if((rg_ptw_reponse.valid || (lv_tlb_hit && !lv_tlb_is_io)) && !lv_set_conflict && !ifc_mhb.mv_mshr_full ) begin // TODO  
            rg_stage2_valid <= True;
            rg_stage2_req_data <= //TODO: insert all pertinent data
            rg_replay_valid <= False;
            rg_tlb_miss <= False;
            rg_set_conflict <= False;
        end
        else if(rg_io_request_valid && ifc_mhb.mv_mshr_empty()) begin
            // send request to fabric //TODO  
            // TODO: ADD A CONDITION TO MAKE SURE THIS REQUEST ISN'T SET AGAIN
            // rg_stage_valid and rg_io_valid isn't reset till a valid i/o response is received
        end
        else begin // had another set conflict or tlb_miss
            rg_replay_valid <= True;
            rg_replay_req_data <= lv_core_req;
            if(!lv_tlb_hit) begin
                rg_tlb_miss <= True; // takes priority over set_conflict
            end
            else if(lv_set_conflict) begin
                rg_set_conflict <= True;
            end
        end
    endrule
    //
    // Only cacheable requests proceed to this stage
    // Tag, data, status, repl are available in rg_stage2_req_data
    rule rl_stage_2(rg_stage2_valid && !wr_flush);
        let stage2_data = rg_stage2_req_data;
        MHB_lookup_resp lv_mhb_resp = ifc_mhb.mv_mshr_lookup(rg_stage2_valid,stage2_data.paddr);
        // cache hit
        if(|stage2_data.tag_response = 1'b1) begin
            // TODO return stage2_data.data_response to CRQ
            // TODO Update replacement data with selected way
            rg_stage2_valid <= False;
        end
        else if(lv_mhb_resp.hit_mhb) begin
            // TODO return lv_mhb_resp.fb_data to CRQ
            rg_stage2_valid <= False;
        end
        else if(stage2_data.replacement_available) begin // TODO
            if(lv_mhb_resp.hit_mhb && lv_mhb_resp.free_secondary || !lv_mhb_resp.hit_mhb && !ifc_mhb.mv_mshr_full()) begin
                ifc_mhb.ma_allocate_entry(); // TODO
                // TODO Update replacement 
                rg_stage2_valid <= False;
            end
            // else stage2 stalled
        end
        else if(!stage2_data.replacement_available) begin // TODO
            // TODO Assign random replacement way
        end
    endrule
    //
    rule rl_poll_response_from_memory;
        if(wr_mem_response.valid) begin
            if(rg_replay_valid && rg_io_request_valid && wr_mem_response.rid == rg_stage2_req_data.core_req.rid) begin
                // TODO send to IRQ
                rg_replay_valid <= False;
                rg_io_request_valid <= False;
            end
            else begin
                // send to LFB
                rg_fill_valid <= True;
                rg_fill_data <= wr_mem_response;
            end
        end
    endrule
    //
    rule rl_fill_from_memory(rg_fill_valid);
        ifc_mhb.ma_fill_from_memory(rg_fill_valid,rg_fill_data);
        rg_fill_valid <= False;
    endrule
    //
    rule rl_LFB_release_to_cache;
        match {.valid,.block_addr,.block_data} <- ifc_mhb.mv_fb_release();
        if(valid) begin
            Bit#(setbits) set_index = truncate(block_addr);
            rg_icache_valid[set_index] <= '1;
            // TODO update replacement
            // TODO Write into tag
            // TODO Write into data 
        end
    endrule
    //
    module ICache_status mv_icache_status();
        return wr_icache_busy;
    endmodule
    //
    module ma_core_request(ICache_core_request core_req);
            wr_core_req <= core_req;
    endmodule
    //
endpackage