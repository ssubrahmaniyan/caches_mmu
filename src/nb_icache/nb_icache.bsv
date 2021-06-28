package nb_icache;
    import icache_tagram    ::*;
    import icache_dataram   ::*;
    import icache_mhb       ::*;
    import icache_types     ::*;
    import icache_tlb       ::*;

    interface Ifc_nb_icache;
        // Inputs
        module Action ma_core_request(ICache_core_request core_req);
        module Action ma_csr_status(Bit#(2) prv, Bit#(`xlen), mstatus, Bit#(`xlen) satp);
        interface Put#(PTWalk_tlb_response#(TAdd#(`ppnsize,10), `varpages)) put_response_frm_ptw;
        interface Put#(ICache_mem_readresp#(`ibuswidth)) put_read_mem_resp;
        // Outputs 
        module ICache_core_response mv_core_response();
        module ICache_status mv_icache_status();
        interface Get#(ICache_mem_readreq#(`paddr)) get_read_mem_req;
        interface Get#(PTWalk_tlb_request#(`vaddr)) get_request_to_ptw;
    endinterface
    //
    (*synthesize*)
    module mknb_icache(Ifc_nb_icache);

    // Fifos
    FIFOF#(ICache_mem_readreq#(`paddr)) ff_mem_request <- mkPipelineFIFOF();

    // Stage 1 Registers 
    Reg#(Bool) rg_replay_stage1_valid <- mkReg(False);
    Reg#(Bool) rg_stage1_flushed <- mkReg(False);
    Reg#(Stage1) rg_replay_stage1_req_data <- mkReg(unpack(0));
    Reg#(Bool) rg_tlb_miss <- mkReg(False);
    Reg#(Bool) rg_fence <- mkReg(False);
    Reg#(Bool) rg_sfence  <- mkReg(False);
    Reg#(Bool) rg_set_conflict <- mkReg(False);
    
    // IRQ registers
    Reg#(Bool) rg_io_request_valid <- mkReg(False);
    Reg#(Bool) rg_io_request_issued <- mkReg(False);
    // Stage 2 registers
    Reg#(Bool) rg_stage2_valid <- mkReg(False);
    Reg#(Stage2) rg_stage2_req_data <- mkReg(unpack(0));
    Wire#(Bool) wr_stage2_next_cycle_valid <- mkDWire(False);
    // LFB registers 
    Reg#(Bool) rg_fill_valid <- mkReg(False);
    Reg#(Mem_response) rg_fill_data <- mkReg(False);
    // Lookup registers
    Reg#(Bool) rg_lookup_valid <- mkDReg(False);
    Reg#(Bit#(`paddr)) rg_lookup_paddr <- mkReg(0);
    Reg#(Stage2) rg_lookup_stage2 <- mkReg(unpack(0));

    // Wires
    Wire#(Bool) wr_icache_status <- mkDWire(False);
    Wire#(Bool) wr_flush <- mKDWire(False);
    Wire#(Bool) wr_replay <- mkDWire(False);
    Wire#(Bool) wr_no_pending_requests <- mkDWire(False);
    Wire#(ICache_core_request) wr_core_req <- mkDWire(unpack(0));
    Wire#(Mem_response) wr_mem_response <- mkDWire(unpack(0));
    
    Wire#(Bool) wr_fb_release_valid <- mkDWire(False);
    Wire#(Bit#(`setbits)) wr_fb_release_index <- mkDWire(0);

    Wire#(Bool) wr_lookup_arrays_valid <- mkDWire(False);
    Wire#(Bit#(`paddr)) wr_lookup_paddr <- mkDWire(0);
    Wire#(Bit#(`reqid_width)) wr_lookup_reqid <- mkDWire(0);
    Wire#(Stage2) wr_stage2_data <- mkDWire(unpack(0));

    Wire#(Bool) wr_ptwalk_valid_response <- mkDWire(False);


    // Initialize structures
    Vector#(`numsets, Vector#(`numways,Reg#(Bit#(1)))) rg_icache_valid <- replicateM(replicateM(mkReg(0)));
    Ifc_icache_tagram ifc_tag <- mkicache_tagram();
    Ifc_icache_dataram ifc_data <- mkicache_dataram();
    Ifc_icache_mhb ifc_mhb <- mkicache_mhb();
    Ifc_replace#(`numsets,`numways) ifc_replacement <- mkreplace(`irepl);
    Ifc_icache_itlb ifc_itlb <- mkicache_itlb();
    //
    //
    // Cache busy is set if MHB all primary entries full, 
    //                      valid request pending to be replayed,
    //                      a valid request stalled in stage 2
    rule rl_check_cache_busy;
        ICache_status lv_status = unpack(0);
        lv_status.cache_busy = (ifc_mhb.mv_mshr_full || rg_replay_stage1_valid || rg_stage2_valid); //register mv mshr full
        lv_status.mshr_status = ifc_mhb.mv_mshr_count_free();
        wr_icache_status <= lv_status; 
    endrule
    //
    //
    rule rl_check_pending_requests;
        wr_no_pending_requests <= (!rg_stage2.valid && ifc_mhb.mv_mshr_empty());
    endrule
    //
    rule rl_lookup_arrays;
        if(wr_lookup_arrays_valid) begin
            Bit#(`setbits) lv_set_index= wr_lookup_paddr[v_setbits+v_blockbits+v_wordbits-1:v_blockbits+v_wordbits];
            Vector#(`numways,Bit#(1)) lv_way_valid = readVReg(rg_icache_valid[lv_set_index]);
            //
            Stage2 lv_stage2_data = unpack(0);
            lv_stage2_data.paddr = wr_lookup_paddr;
            lv_stage2_data.req_id = wr_lookup_reqid;
            lv_stage2_data.replacement_way <- ifc_replacement.line_replace(lv_set_index,lv_way_valid);
            lv_stage2_data.way_valid = lv_way_valid;
            //
            // send BRAM request
            ifc_tag.ma_read_request(wr_lookup_arrays_valid,wr_lookup_paddr);
            ifc_data.ma_read_request(wr_lookup_arrays_valid,wr_lookup_paddr);
            //
            rg_lookup_valid <= wr_lookup_arrays_valid;
            rg_lookup_stage2 <= lv_stage2_data; // contains partial data
        end
    endrule
    //
    rule rl_lookup_response;
        if(rg_lookup_valid) begin
            Bit#(`numways) lv_tagram_response = '0;
            Bit#(`numways) lv_hitmask = '0;
            //
            Stage2 lv_stage2_data = rg_lookup_stage2;
            //
            lv_tagram_response = ifc_tag.mv_read_response();
            lv_hitmask = (lv_tag_response & lv_stage2_data.way_valid);
            lv_stage2_data.tag_hit = unpack(|hitmask);
            lv_stage2_data.data = m_data.mv_read_response(hitmask);
            //
            wr_stage2_data <= lv_stage2_data; 
        end
        else begin
            wr_stage2_data <= rg_stage2_req_data;
        end
    endrule
    //
    rule rl_allow_tlb_miss_replay;
        // TLB miss causes rl_replay_req to stall till iTLB receives a valid response from PTWalk
        // Reset rg_tlb_miss when a valid ptwalk response is received
        //
        if(rg_tlb_miss && wr_ptwalk_valid_response) begin
            rg_tlb_miss <= False; 
        end
    endrule
    //
    rule rl_stage1;

        if(wr_flush) begin // No new requests are accepted from core in flush cycle
            if(rg_replay_stage1_valid) begin
                if(!rg_tlb_miss && !rg_io_request_issued && !rg_replay_stage1_req_data.fence && !rg_replay_stage1_req_data.sfence) begin
                    rg_replay_stage1_valid <= False;
                end
                if(rg_tlb_miss || rg_io_request_issued) begin // set request as flushed, it will be executed but response will not be sent to core
                    rg_stage1_flushed <= True;
                end
            end
        end
        else begin
            if(wr_no_pending_requests) begin
                let lv_core_req = wr_core_req;
                if(lv_core_req.valid) begin
                    Bool lv_set_conflict =  False;
                    Bool lv_tlb_hit = False; // TODO  
                    Bool lv_tlb_is_io = False; // TODO  
                    //
                    let lv_itlb_response <- ifc_itlb.mav_core_request(fn_get_tlb_packet(lv_core_req)); // lookup TLB // TODO
                    //
                    wr_lookup_arrays_valid <= lv_core_req.valid; // index into 4 arrays: status, repl, tag, data.
                    wr_lookup_paddr <= lv_itlb_response.address;
                    wr_lookup_reqid <= lv_core_req.req_id;
                    //
                    if(wr_fb_release_valid && (wr_fb_release_index == lv_core_req.vaddr[`setbits+`wordoffset+`byteoffset-1:`wordoffset+`byteoffset])) begin
                        lv_set_conflict = True;
                    end
                    // 
                    if(lv_core_req.fence) begin
                        // invalidate all cache entries
                        rg_icache_valid <= unpack(0);  
                    end
                    // else if(lv_core_req.sfence) begin
                    //     //invalidate TLB (Happens through core request)
                    // end
                    else if(lv_tlb_hit && !lv_tlb_is_io && !lv_set_conflict && !ifc_mhb.mv_mshr_full) begin // TODO  
                        rg_stage2_valid <= True;
                    end
                    else if(lv_tlb_hit && lv_tlb_is_io) begin
                        // send request to fabric //TODO
                        ff_mem_request.enq(lv_core_req);  
                        rg_replay_stage1_valid <= True; // request is not actually replayed, just to stall Cache till response is received from fabric
                        rg_io_request_valid <= True; 
                        rg_replay_stage1_req_data <= lv_core_req;
                        rg_io_request_issued <= True;
                    end
                    else begin
                        rg_replay_stage1_valid <= True;
                        rg_replay_stage1_req_data <= lv_core_req;
                        if(!lv_tlb_hit) begin
                            rg_tlb_miss <= True; // takes priority over set_conflict
                        end
                        else if(lv_set_conflict) begin
                            rg_set_conflict <= True;
                        end    
                    end
                end
            end
            //
            // requests pending in pipe
            else begin
            //
                // implicit condition: !rg_replay_stage1_valid && !rg_stage2_valid (otherwise cache would be busy)
                if(wr_core_req.valid) begin 
                    Bool lv_set_conflict =  False;
                    Bool lv_tlb_hit = False; // TODO  
                    Bool lv_tlb_is_io = False; // TODO  
                    //
                    let lv_itlb_response <- ifc_itlb.mav_core_request(fn_get_tlb_packet(lv_core_req)); // lookup TLB // TODO
                    //
                    wr_lookup_arrays_valid <= lv_core_req.valid; // index into 4 arrays: status, repl, tag, data.
                    wr_lookup_paddr <= lv_itlb_response.address;
                    wr_lookup_reqid <= lv_core_req.req_id;
                    //
                    if(wr_fb_release_valid && (wr_fb_release_index == lv_core_req.vaddr[`setbits+`wordoffset+`byteoffset-1:`wordoffset+`byteoffset])) begin
                        lv_set_conflict = True;
                    end
                    // 
                    if(lv_tlb_hit && !lv_tlb_is_io && !lv_set_conflict && !ifc_mhb.mv_mshr_full ) begin // TODO  
                        rg_stage2_valid <= True;
                    end
                    else if(lv_tlb_hit && lv_tlb_is_io) begin
                        rg_replay_stage1_valid <= True; 
                        rg_io_request_valid <= True;
                        rg_io_request_issued <= False; 
                        rg_replay_stage1_req_data <= wr_core_req;
                    end
                    else begin
                        rg_replay_stage1_valid <= True;
                        rg_replay_stage1_req_data <= wr_core_req;
                        if(!lv_tlb_hit) begin
                            rg_tlb_miss <= True; // takes priority over set_conflict
                        end
                        else if(lv_set_conflict) begin
                            rg_set_conflict <= True;
                        end    
                    end
                end
                // 
                // replay pending requests, if any
                else begin
                    wr_replay <= rg_replay_stage1_valid && !rg_tlb_miss && (!rg_stage2_valid || !wr_stage2_next_cycle_valid); 
                end
            end
        end
    endrule
    //
    // replay the pending requests (if stage2 free and no tlb_miss)
    rule rl_replay_req(wr_replay && !wr_flush);

        let lv_core_req = rg_replay_stage1_req_data; 
        Bool lv_set_conflict =  False;  
        Bool lv_tlb_hit = False; // TODO  
        Bool lv_tlb_is_io = False; // TODO  
        //
        let lv_itlb_response <- ifc_itlb.mav_core_request(fn_get_tlb_packet(lv_core_req)); // lookup TLB // TODO
        //
        wr_lookup_arrays_valid <= lv_core_req.valid; // index into 4 arrays: status, repl, tag, data.
        wr_lookup_paddr <= lv_itlb_response.address;
        wr_lookup_reqid <= lv_core_req.req_id;
        //
        if(wr_fb_release_valid && (wr_fb_release_index == lv_core_req.vaddr[`setbits+`wordoffset+`byteoffset-1:`wordoffset+`byteoffset])) begin
            lv_set_conflict = True;
        end
        // 
        if(lv_core_req.fence && ifc_mhb.mv_mshr_empty()) begin
            // invalidate all cache entries
            rg_icache_valid <= unpack(0);  
            rg_replay_stage1_valid <= False;
        end
        else if(lv_core_req.sfence && ifc_mhb.mv_mshr_empty()) begin
            //invalidate TLB (Happens through core request)
            rg_replay_stage1_valid <= False;
        end
        else if((lv_tlb_hit && !lv_tlb_is_io) && !lv_set_conflict 
                                              && !ifc_mhb.mv_mshr_full ) begin // TODO  
            if(rg_stage1_flushed) begin // if Ptwalk response has been stored in tlb for the flushed request, drop it.
                rg_stage1_flushed <= False;
                rg_replay_stage1_valid <= False;
            end
            else begin
                rg_stage2_valid <= True;
                rg_replay_stage1_valid <= False;
                rg_set_conflict <= False;
            end
        end
        else if((lv_tlb_hit && lv_tlb_is_io) && ifc_mhb.mv_mshr_empty()) begin
            // send request to fabric //TODO
            ff_mem_request.enq(lv_core_req);  
            // rg_replay_stage1_valid and rg_io_request_valid aren't reset till a valid i/o response is received
            if(!rg_io_request_issued) begin
                rg_io_request_valid <= True;
                rg_io_request_issued <= True;
            end
        end
        else begin // had another "set conflict" or "tlb_miss" or "fence/sfence/io and cache not empty"
            rg_replay_stage1_valid <= True;
            rg_replay_stage1_req_data <= lv_core_req;
            if((lv_tlb_hit && lv_tlb_is_io)) begin
                rg_io_request_valid <= True;
            end
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
    rule rl_stage_2;
        Bool lv_stage2_next_cycle_valid = rg_stage2_valid;
        if(wr_flush) begin
            rg_stage2_valid <= False;
            lv_stage2_next_cycle_valid = False;
        end
        else if(rg_stage2_valid) begin
            let stage2_data = wr_stage2_data;
            MHB_lookup_resp lv_mhb_resp = ifc_mhb.mv_mshr_lookup(rg_stage2_valid,stage2_data.paddr);
            // cache hit
            if(stage2_data.tag_hit) begin
                // TODO return stage2_data.data_response to CRQ
                // TODO Update replacement data with selected way
                rg_stage2_valid <= False;
                lv_stage2_next_cycle_valid = False;
            end
            // MHB hit and corresponding word filled
            else if(lv_mhb_resp.hit_mhb && lv_mhb_resp.fb_valid) begin
                // TODO return lv_mhb_resp.fb_data to CRQ
                rg_stage2_valid <= False;
                lv_stage2_next_cycle_valid = False;
            end
            // Cache miss, MHB (miss/hit but word not filled)
            else begin
                // Entries available in MHB
                if(lv_mhb_resp.hit_mhb && lv_mhb_resp.free_secondary || !lv_mhb_resp.hit_mhb && !ifc_mhb.mv_mshr_full()) begin
                    //
                    ifc_mhb.ma_allocate_entry(True,lv_mhb_resp.hit_mhb,lv_mhb_resp.mhb_index,
                                            stage2_data.paddr,stage2_data.req_id,stage2_data.replacement_way);
                    rg_stage2_valid <= False;
                    lv_stage2_next_cycle_valid <= True;
                    // TODO Update replacement on miss (to be implemented)
                end
                else begin
                    rg_stage2_req_data <= wr_stage2_data; // Stall stage 2
                end
            end
        end
        // Convey to stage 1 in the current cycle that stage 2 will be free next cycle
        // So that stage 1 can latch a request for stage 2 in the current cycle itself.
        wr_stage2_next_cycle_valid <= lv_stage2_next_cycle_valid;
    endrule
    //
    // Fill Pipeline
    rule rl_serve_mshr_requests;
        match {.valid,.req_id,.crq_data,.all_served} <- ifc_mhb.mv_miss_response();
        // TODO send data and request_id to CRQ
    endrule
    //
    //
    rule rl_fill_request;
        let mhb_mem_req = ifc_mhb.mv_fill_request();
        if(mhb_mem_req.valid) begin
            ff_mem_request.enq(mhb_mem_req); // The rule will only fire if the fifo is empty/or being dequeued by processor
        end
        ifc_mhb.ma_set_issued(mhb_mem_req.valid);
    endrule
    //
    //
    rule rl_poll_response_from_memory;
        if(wr_mem_response.valid) begin
            if(rg_replay_stage1_valid && rg_io_request_valid) begin
                // TODO send to CRQ
                rg_replay_stage1_valid <= False;
                rg_io_request_valid <= False;
                rg_io_request_issued <= False;
            end
            else begin
                // send to LFB
                rg_fill_valid <= True; // don't need backpressure because of current controller design
                rg_fill_data <= wr_mem_response;
            end
        end
    endrule
    //
    //
    rule rl_fill_from_memory;
        ifc_mhb.ma_fill_from_memory(rg_fill_valid,rg_fill_data);
        rg_fill_valid <= False;
    endrule
    //
    //
    rule rl_LFB_release_to_cache;
        match {.valid,.way,.block_addr,.block_data} <- ifc_mhb.mv_fb_release();
        Bit#(`paddr) lv_paddr = {block_addr,'0};
        Bit#(`setbits) set_index = truncate(block_addr);
        if(valid) begin
            rg_icache_valid[set_index][way] <= 1'b1;
            // TODO update replacement
            ifc_tag.ma_write_request(True,lv_paddr,way);
            ifc_data.ma_write_request(True,lv_paddr,block_data,way);
        end
        wr_fb_release_valid <= valid;
        wr_fb_release_index <= set_index;
    endrule
    //
    //
    interface get_request_to_ptw = ifc_itlb.get_request_to_ptw;
    interface put_response_frm_ptw = interface Put
        method Action put(PTWalk_tlb_response#(TAdd#(`ppnsize,10), `varpages) in);
            wr_ptwalk_valid_response <= True;  // resets tlb miss replay stall
            ifc_itlb.put_response_frm_ptw.put(in);
        endmethod
    endinterface
    //
    interface get_read_mem_req = toGet(ff_mem_request);
    interface put_read_mem_resp = interface Put
        method Action put((ICache_mem_readresp#(`ibuswidth) in);
            wr_mem_response <= in;
        endmethod
    endinterface
    //
    module ICache_status mv_icache_status();
        return wr_icache_status;
    endmodule
    //
    //
    module ma_core_request(ICache_core_request core_req);
        wr_core_req <= core_req;
    endmodule
    //
    //
endpackage