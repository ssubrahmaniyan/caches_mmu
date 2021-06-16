package nb_icache;
    import icache_tagram    ::*;
    import icache_dataram   ::*;
    import icache_mhb       ::*;
    import icache_types     ::*;
    import icache_tlb       ::*;

    interface Ifc_nb_icache;
        // Inputs
        module Action ma_core_request(ICache_core_request core_req);
        module Action ma_ptw_response(PTW_response ptw_response);
        module Action ma_mem_response(Mem_response mem_response);
        module Action ma_csr_status(Bit#(2) prv, Bit#(`xlen), mstatus, Bit#(`xlen) satp);
        method Action ma_set_issued(Bool valid,Bit#(TLog#(`mhb_size)) mhb_index);
        `ifdef supervisor
            interface Get#(PTWalk_tlb_request#(`vaddr)) get_request_to_ptw;
            interface Put#(PTWalk_tlb_response#(TAdd#(`ppnsize,10), `varpages)) put_response_frm_ptw;
        `endif
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
    Wire#(Bool) wr_stage2_next_cycle_valid <- mkDWire(False);
    //
    Reg#(Bool) rg_fill_valid <- mkReg(False);
    Reg#(Mem_response) rg_fill_data <- mkReg(False);
    // Wires
    Wire#(Bool) wr_icache_status <- mkDWire(False);
    Wire#(Bool) wr_flush <- mKDWire(False);
    Wire#(Bool) wr_replay <- mkDWire(False);
    Wire#(Bool) wr_no_pending_requests <- mkDWire(False);
    Wire#(ICache_core_request) wr_core_req <- mkDWire(unpack(0));
    Wire#(Mem_response) wr_mem_response <- mkDWire(unpack(0));
    // Initialize structures
    Vector#(`numsets, Reg#(Bit#(`numways))) rg_icache_valid <- replicateM(mkReg(0));
    Ifc_icache_tagram ifc_tag <- mkicache_tagram();
    Ifc_icache_dataram ifc_data <- mkicache_dataram();
    Ifc_icache_mhb ifc_mhb <- mkicache_mhb();
    Ifc_replace#(`numsets,`numways) ifc_replacement <- mkreplace(`irepl);
    `ifdef supervisor
        Ifc_icache_itlb ifc_itlb <- mkicache_itlb();
    `endif
    //
    rule rl_check_cache_busy;
        ICache_status lv_status = unpack(0);
        // Cache busy is set if MHB all primary entries full 
        // or valid request to replayed 
        // or a valid request stalled in stage 2
        lv_status.cache_busy = (ifc_mhb.mv_mshr_full || rg_replay_valid || rg_stage2_valid); //register mv mshr full
        lv_status.mshr_status = ifc_mhb.mv_mshr_count_free();
        wr_icache_status <= lv_status; // make rg 
    endrule
    //
    rule rl_check_pending_requests;
        wr_no_pending_requests <= (!rg_stage2.valid && !rg_replay_valid && ifc_mhb.mv_mshr_empty());
    endrule
    //
    rule rl_stage1_no_pending_requests(!wr_flush);
        if(wr_no_pending_requests) begin
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
                    rg_replay_valid <= True; // Is not actually replayed, just to stall Cache till response is received from fabric
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
        end
        // requests pending in pipe
        else begin
            //
            // Case: !rg_replay_valid and !rg_stage2_valid
            // Since mhb_full signal is registered, 
            // core will receive the corresponding cache_busy signal a cycle later.
            // If the core sends a core request in that cycle, it should be saved.
            if(!rg_replay_valid) begin
                if(wr_core_req.valid) begin
                    // All core requests are saved
                    rg_replay_valid <= True;
                    rg_replay_req_data <= wr_core_req;
                end
            end
            // 
            // Cache busy, replay pending requests
            else begin
                wr_replay <= True; 
            end
        end
    endrule
    // replay the pending requests, only if 
    // 1. no request pending in stage 2
    // 2. stage2 is going to be free next cycle (signal comes from rl_stage2)
    rule rl_replay_req(wr_replay && (!rg_stage2_valid || wr_stage2_next_cycle_valid) && !wr_flush );
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
        else if((lv_tlb_hit && !lv_tlb_is_io) && !lv_set_conflict && !ifc_mhb.mv_mshr_full ) begin // TODO  
            rg_stage2_valid <= True;
            rg_stage2_req_data <= //TODO: insert all pertinent data
            rg_replay_valid <= False;
            rg_tlb_miss <= False;
            rg_set_conflict <= False;
        end
        // dummy register for IRQ
        else if((lv_tlb_hit && lv_tlb_is_io) && ifc_mhb.mv_mshr_empty()) begin
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
            wr_stage2_next_cycle_valid <= True;
        end
        // MHB hit and corresponding word filled
        else if(lv_mhb_resp.hit_mhb && lv_mhb_resp.fb_valid) begin
            // TODO return lv_mhb_resp.fb_data to CRQ
            rg_stage2_valid <= False;
            wr_stage2_next_cycle_valid <= True;
        end
        // Cache miss, MHB (miss/hit but word not present)
        else begin
            // Entries available in MHB
            if(lv_mhb_resp.hit_mhb && lv_mhb_resp.free_secondary || !lv_mhb_resp.hit_mhb && !ifc_mhb.mv_mshr_full()) begin
                ifc_mhb.ma_allocate_entry(); // TODO
                rg_stage2_valid <= False;
                wr_stage2_next_cycle_valid <= True;
                // TODO Update replacement on miss (to be implemented)
            end
            // else 
            // Stall stage 2
            // Either it was a MHB hit and no secondary entries were free
            // Or it was a MHB miss and no primary entries were free
        end
    endrule
    // no backpressure (LFB ) so wire works
    rule rl_poll_response_from_memory;
        if(wr_mem_response.valid) begin
            if(rg_replay_valid && rg_io_request_valid) begin
                // TODO send to CRQ
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
    `ifdef supervisor
        interface get_request_to_ptw = ifc_itlb.get_request_to_ptw;
        interface put_response_frm_ptw = ifc_itlb.put_response_frm_ptw;
    `endif
    //
    module ICache_status mv_icache_status();
        return wr_icache_status;
    endmodule
    //
    module ma_core_request(ICache_core_request core_req);
        wr_core_req <= core_req;
    endmodule
    //
endpackage