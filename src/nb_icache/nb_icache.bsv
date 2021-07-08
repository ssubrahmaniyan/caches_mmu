package nb_icache;
    import icache_tagram    ::*;
    import icache_dataram   ::*;
    import icache_mhb       ::*;
    import itlb             ::*;
    import itlb_types       ::*;
    import nb_icache_types  ::*;
    import common_tlb_types :: * ;
    `include "icache_parameters.bsv"
    //
    import DReg             ::*;
    import GetPut           ::*;
    import Vector           ::*;
    import FIFO             ::*;
    import FIFOF            ::*;
    import SpecialFIFOs     ::*; 
    

    interface Ifc_nb_icache;
        // Inputs
        method Action ma_core_request(ICache_core_request core_req);
        method Action ma_csr_status(Bit#(2) prv, Bit#(`xlen) mstatus, Bit#(`xlen) satp);
        interface Put#(PTWalk_tlb_response#(TAdd#(`ppnsize,10), `varpages)) put_response_from_ptw;
        interface Put#(Mem_response) put_read_mem_resp;
        // Outputs 
        method Vector#(`crq_input_size,ICache_core_response) mv_icache_response();
        method ICache_status mv_icache_status();
        interface Get#(Mem_request) get_read_mem_req;
        interface Get#(PTWalk_tlb_request#(`vaddr)) get_request_to_ptw;
    endinterface
    //
    (*synthesize*)
    (*conflict_free="rl_icache_fence,rl_LFB_release_to_cache"*)
    (*conflict_free="rl_poll_response_from_memory,rl_fill_from_memory"*)
    module mknb_icache(Ifc_nb_icache);

        // Fifos
        FIFOF#(Mem_request) ff_mem_request <- mkPipelineFIFOF();

        // Stage 1 Registers 
        Reg#(Bool) rg_replay_stage1_valid <- mkReg(False);
        Reg#(Bool) rg_stage1_flushed <- mkReg(False);
        Reg#(ICache_core_request) rg_replay_stage1_req_data <- mkReg(unpack(0));
        Reg#(Bool) rg_tlb_miss <- mkReg(False);
        Reg#(Bit#(`paddr)) rg_tlb_miss_response <- mkReg(0);
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
        Reg#(Mem_response) rg_fill_data <- mkReg(unpack(0));
        // Lookup registers
        Reg#(Bool) rg_lookup_valid <- mkDReg(False);
        Reg#(Bit#(`paddr)) rg_lookup_paddr <- mkReg(0);
        Reg#(Stage2) rg_lookup_stage2 <- mkReg(unpack(0));

        // Wires
        Vector#(`crq_input_size,Wire#(ICache_core_response)) wr_crq_response <- replicateM(mkDWire(unpack(0)));
        Wire#(ICache_core_response) wr_stage2_crq_data <- mkDWire(unpack(0));
        Wire#(ICache_core_response) wr_mhb_crq_data <- mkDWire(unpack(0));
        Wire#(ICache_core_response) wr_io_crq_data <- mkDWire(unpack(0));

        Wire#(Bool) wr_flush <- mkDWire(False);
        Wire#(Bool) wr_replay <- mkDWire(False);
        Wire#(Bool) wr_no_pending_requests <- mkDWire(False);
        Wire#(Bool) wr_icache_fence <- mkDWire(False);
        Wire#(ICache_status) wr_icache_status <- mkDWire(unpack(0));
        Wire#(ICache_core_request) wr_core_req <- mkDWire(unpack(0));
        Wire#(Mem_response) wr_mem_response <- mkDWire(unpack(0));
        
        Wire#(Bool) wr_fb_release_valid <- mkDWire(False);
        Wire#(Bit#(`setbits)) wr_fb_release_index <- mkDWire(0);

        Wire#(Bool) wr_lookup_arrays_valid <- mkDWire(False);
        Wire#(Bit#(`paddr)) wr_lookup_paddr <- mkDWire(0);
        Wire#(Bit#(`reqid_width)) wr_lookup_reqid <- mkDWire(0);
        Wire#(Stage2) wr_stage2_data <- mkDWire(unpack(0));
        Wire#(Bool) wr_from_stage1_valid <- mkDWire(False);
        Wire#(Bool) wr_stage2_valid <- mkDWire(False);

        Wire#(Bool) wr_ptwalk_valid_response <- mkDWire(False);
        Wire#(ITLB_core_response#(`paddr)) wr_tlb_miss_response <- mkDWire(unpack(0));
        Wire#(ITLB_core_response#(`paddr)) wr_itlb_response <- mkDWire(unpack(0));
        Wire#(Bool) wr_itlb_sfence <- mkDWire(False);
        //
        Wire#(Bool) wr_preread_replay_stage1_valid <- mkDWire(False);
        Wire#(Bool) wr_preread_tlb_miss <- mkDWire(False);
        Wire#(Bool) wr_preread_stage2_valid <- mkDWire(False);
        Wire#(Bool) wr_preread_stage1_flushed <- mkDWire(False);
        Vector#(`numsets, Vector#(`numways,Wire#(Bit#(1)))) wr_preread_icache_valid <- replicateM(replicateM(mkDWire(0)));




        // Initialize structures
        Vector#(`numsets, Vector#(`numways,Reg#(Bit#(1)))) rg_icache_valid <- replicateM(replicateM(mkReg(0)));
        Ifc_icache_tagram ifc_tag <- mkicache_tagram();
        Ifc_icache_dataram ifc_data <- mkicache_dataram();
        Ifc_icache_mhb ifc_mhb <- mkicache_mhb();
        // Ifc_replace#(`numsets,`numways) ifc_replacement <- mkreplace(`irepl);
        Ifc_itlb ifc_itlb <- mkitlb(0);
        //
        rule rl_pre_read_registers;
            for(Integer i=0;i<`numsets;i=i+1) begin
                for(Integer j=0;j<`numways;j=j+1) begin
                    wr_preread_icache_valid[i][j] <= rg_icache_valid[i][j];
                end
            end
            wr_preread_replay_stage1_valid <= rg_replay_stage1_valid;
            wr_preread_stage2_valid <= rg_stage2_valid;
            wr_preread_tlb_miss <= rg_tlb_miss;
            wr_preread_stage1_flushed <= rg_stage1_flushed;
        endrule
        //
        //
        // Cache busy is set if MHB all primary entries full, 
        //                      valid request pending to be replayed,
        //                      a valid request stalled in stage 2
        rule rl_check_cache_busy;
            ICache_status lv_status = unpack(0);
            lv_status.cache_busy = (ifc_mhb.mv_mshr_full || wr_preread_replay_stage1_valid || wr_preread_stage2_valid);
            lv_status.mshr_status = ifc_mhb.mv_mshr_count_free();
            wr_icache_status <= lv_status; 
        endrule
        //
        rule rl_check_pending_requests;
            wr_no_pending_requests <= (!wr_preread_stage2_valid && ifc_mhb.mv_mshr_empty());
        endrule
        //
        rule rl_lookup_arrays;
            if(wr_lookup_arrays_valid) begin
                Bit#(`setbits) lv_set_index= wr_lookup_paddr[`setbits+`byteoffset+`wordoffset-1:`byteoffset+`wordoffset];
                Vector#(`numways,Bit#(1)) lv_way_valid = readVReg(wr_preread_icache_valid[lv_set_index]);
                //
                Stage2 lv_stage2_data = unpack(0);
                lv_stage2_data.paddr = wr_lookup_paddr;
                lv_stage2_data.req_id = wr_lookup_reqid;
                // lv_stage2_data.replacement_way <- ifc_replacement.line_replace(lv_set_index,lv_way_valid); // TODO
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
                lv_hitmask = (lv_tagram_response & pack(lv_stage2_data.way_valid));
                lv_stage2_data.tag_hit = unpack(|lv_hitmask);
                //     
                // Extracting corresponding word from the block
                //
                Bit#(`blocksize) lv_cache_block = ifc_data.mv_read_response(lv_hitmask);
                Bit#(TAdd#(TAdd#(`wordoffset,`byteoffset),3)) lv_shift_amt = lv_stage2_data.paddr[`wordoffset+`byteoffset+2:0] << 3; // number of bits to shift
                lv_cache_block = lv_cache_block >> lv_shift_amt;
                lv_stage2_data.data = lv_cache_block[`wordsize-1:0];
                //
                wr_stage2_data <= lv_stage2_data; 
            end
            else begin
                wr_stage2_data <= rg_stage2_req_data;
            end
        endrule
        //
        // TLB miss causes rl_replay_req to stall until iTLB receives a valid response from PTWalk
        // Reset rg_tlb_miss when a valid ptwalk response is received and check if request can be sent to stage2
        //
        rule rl_allow_tlb_miss_replay;
            let lv_core_req = rg_replay_stage1_req_data; 
            Bool lv_set_conflict =  False;  
            if(wr_preread_tlb_miss && wr_ptwalk_valid_response) begin 
                //
                rg_tlb_miss <= False;
                if(wr_preread_stage1_flushed) begin // if Ptwalk response has been stored in tlb for the flushed request, drop it.
                    rg_stage1_flushed <= False;
                    // rg_tlb_miss <= False;
                    rg_replay_stage1_valid <= False;
                end
                // else begin
                //     wr_lookup_arrays_valid <= lv_core_req.valid; // index into the arrays in the same cycle when ptw response arrives.
                //     wr_lookup_paddr <= wr_tlb_miss_response.address;
                //     wr_lookup_reqid <= lv_core_req.req_id;
                //     //
                //     if(wr_fb_release_valid && (wr_fb_release_index == lv_core_req.vaddr[`setbits+`wordoffset+`byteoffset-1:`wordoffset+`byteoffset])) begin
                //         lv_set_conflict = True;
                //     end
                //     // 
                //     if(!lv_set_conflict && !ifc_mhb.mv_mshr_full()) begin  
                //         rg_tlb_miss <= False;
                //         rg_replay_stage1_valid <= False;
                //         rg_stage2_valid <= True;
                //     end
                // end
            end
        endrule
        //

        rule rl_icache_fence(wr_icache_fence);
            for(Integer i=0;i<`numsets;i=i+1) begin
                for(Integer j=0;j<`numways;j=j+1) begin
                    rg_icache_valid[i][j] <= 0;  
                end
            end
        endrule
        //
        rule rl_itlb_translate_request;
            ICache_core_request lv_core_req = unpack(0);
            ITLB_core_response#(`paddr) lv_itlb_response = unpack(0);
            if(wr_core_req.valid) begin // valid new core req
                lv_core_req = wr_core_req; 
                lv_itlb_response <- ifc_itlb.translate(lv_core_req.vaddr);
            end
            else if(wr_preread_replay_stage1_valid && !rg_io_request_issued && !wr_preread_tlb_miss && (!wr_preread_stage2_valid || !wr_stage2_next_cycle_valid)) begin // valid replay
                lv_core_req = rg_replay_stage1_req_data;
                lv_itlb_response <- ifc_itlb.translate(lv_core_req.vaddr);
            end
            wr_itlb_response <= lv_itlb_response;
        endrule
        //
        rule rl_itlb_sfence_request(wr_itlb_sfence);
            ifc_itlb.sfence();
        endrule
        //
        // CRQ can accept response from 3 sources: 
        // "Stage 2 hit (MHB/Cache)", "Request served in MHB" , "I/O Response"
        //
        rule rl_accumulate_crq_input;
            wr_crq_response[0] <= wr_stage2_crq_data;
            wr_crq_response[1] <= wr_mhb_crq_data;
            wr_crq_response[2] <= wr_io_crq_data;
        endrule
        //
        rule rl_stage1;

            if(wr_flush) begin // No new requests are accepted from core in flush cycle
                if(wr_preread_replay_stage1_valid) begin
                    if(!wr_preread_tlb_miss && !rg_io_request_issued && !rg_replay_stage1_req_data.fence && !rg_replay_stage1_req_data.sfence) begin
                        rg_replay_stage1_valid <= False;
                    end
                    if(wr_preread_tlb_miss || rg_io_request_issued) begin // set request as flushed, it will be executed but response will not be sent to core
                        rg_stage1_flushed <= True;
                    end
                end
            end
            else begin
                if(wr_no_pending_requests) begin
                    let lv_core_req = wr_core_req;
                    if(lv_core_req.valid) begin
                        Bool lv_set_conflict =  False; 
                        Bool lv_tlb_is_io = False; // TODO  
                        //
                        if(wr_fb_release_valid && (wr_fb_release_index == lv_core_req.vaddr[`setbits+`wordoffset+`byteoffset-1:`wordoffset+`byteoffset])) begin
                            lv_set_conflict = True;
                        end
                        // 
                        if(lv_core_req.fence) begin
                            // invalidate all cache entries
                            wr_icache_fence <= lv_core_req.fence;
                        end
                        else if(lv_core_req.sfence) begin
                            //invalidate TLB 
                            wr_itlb_sfence <= lv_core_req.sfence;
                        end
                        else begin
                            //
                            wr_lookup_arrays_valid <= lv_core_req.valid; // index into 4 arrays: status, repl, tag, data.
                            wr_lookup_paddr <= wr_itlb_response.address;
                            wr_lookup_reqid <= lv_core_req.req_id;
                            //
                            if(wr_itlb_response.hit && !lv_tlb_is_io && !lv_set_conflict && !ifc_mhb.mv_mshr_full) begin  
                                wr_from_stage1_valid <= True; // Stage2 request data will be received through wr_stage2_data in next cycle
                            end
                            else if(wr_itlb_response.hit && lv_tlb_is_io) begin
                                // send request to fabric //TODO -> check struct
                                ff_mem_request.enq( Mem_request{ valid: True,
                                                                paddr: wr_itlb_response.address,
                                                                mhb_id: 0,
                                                                burst_len: 0,
                                                                burst_size: 3'b010,
                                                                io: True} );
                                rg_replay_stage1_valid <= True; // request is not actually replayed, just to stall Cache till response is received from fabric
                                rg_io_request_valid <= True; 
                                rg_replay_stage1_req_data <= lv_core_req;
                                rg_io_request_issued <= True;
                            end
                            else begin
                                rg_replay_stage1_valid <= True;
                                rg_replay_stage1_req_data <= lv_core_req;
                                if(!wr_itlb_response.hit) begin
                                    rg_tlb_miss <= True; // takes priority over set_conflict
                                end
                                else if(lv_set_conflict) begin
                                    rg_set_conflict <= True;
                                end    
                            end
                        end
                    end
                end
                //
                // requests pending in pipe
                else begin
                //  
                    // implicit condition: !rg_replay_stage1_valid && !rg_stage2_valid (otherwise cache would be busy)
                    // can happen as mhb full count is registered
                    if(wr_core_req.valid) begin 
                        Bool lv_set_conflict =  False;
                        Bool lv_tlb_is_io = False; // TODO  
                        //
                        wr_lookup_arrays_valid <= wr_core_req.valid; // index into 4 arrays: status, repl, tag, data.
                        wr_lookup_paddr <= wr_itlb_response.address;
                        wr_lookup_reqid <= wr_core_req.req_id;
                        //
                        if(wr_fb_release_valid && (wr_fb_release_index == wr_core_req.vaddr[`setbits+`wordoffset+`byteoffset-1:`wordoffset+`byteoffset])) begin
                            lv_set_conflict = True;
                        end
                        //
                        if(wr_itlb_response.hit && !lv_tlb_is_io && !lv_set_conflict && !ifc_mhb.mv_mshr_full ) begin  
                            wr_from_stage1_valid <= True;
                        end
                        else if(wr_itlb_response.hit && lv_tlb_is_io) begin
                            rg_replay_stage1_valid <= True; 
                            rg_io_request_valid <= True;
                            rg_io_request_issued <= False; 
                            rg_replay_stage1_req_data <= wr_core_req;
                        end
                        else begin
                            rg_replay_stage1_valid <= True;
                            rg_replay_stage1_req_data <= wr_core_req;
                            if(!wr_itlb_response.hit) begin
                                rg_tlb_miss <= True; // takes priority over set_conflict
                            end
                            else if(lv_set_conflict) begin
                                rg_set_conflict <= True;
                            end    
                        end
                    end
                    // 
                    // replay pending requests, if any
                    // (if "stage2 free" , "No tlb_miss pending", "No issued io request pending")
                    //
                    else if(wr_preread_replay_stage1_valid && !rg_io_request_issued && !wr_preread_tlb_miss && (!wr_preread_stage2_valid || !wr_stage2_next_cycle_valid)) begin
                        let lv_core_req = rg_replay_stage1_req_data; 
                        Bool lv_set_conflict =  False;  
                        Bool lv_tlb_is_io = False; // TODO  
                        //
                        if(wr_fb_release_valid && (wr_fb_release_index == lv_core_req.vaddr[`setbits+`wordoffset+`byteoffset-1:`wordoffset+`byteoffset])) begin
                            lv_set_conflict = True;
                        end
                        // 
                        if(lv_core_req.fence && ifc_mhb.mv_mshr_empty()) begin
                            // invalidate all cache entries
                            wr_icache_fence <= lv_core_req.fence;
                            rg_replay_stage1_valid <= False;
                        end
                        else if(lv_core_req.sfence && ifc_mhb.mv_mshr_empty()) begin
                            //invalidate TLB
                            wr_itlb_sfence <= lv_core_req.sfence;
                            rg_replay_stage1_valid <= False;
                        end
                        else begin
                            //
                            wr_lookup_arrays_valid <= lv_core_req.valid; // index into 4 arrays: status, repl, tag, data.
                            wr_lookup_paddr <= wr_itlb_response.address;
                            wr_lookup_reqid <= lv_core_req.req_id;
                            //
                            if((wr_itlb_response.hit && lv_tlb_is_io) && ifc_mhb.mv_mshr_empty()) begin
                                // send request to fabric //TODO -> check struct
                                ff_mem_request.enq( Mem_request{ valid: True,
                                                                paddr: wr_itlb_response.address,
                                                                mhb_id: 0,
                                                                burst_len: 0,
                                                                burst_size: 3'b010,
                                                                io: True} );
                                // rg_replay_stage1_valid and rg_io_request_valid aren't reset till a valid i/o response is received
                                rg_io_request_valid <= True;
                                rg_io_request_issued <= True;
                            end
                            else if((wr_itlb_response.hit && !lv_tlb_is_io) && !lv_set_conflict 
                                                                && !ifc_mhb.mv_mshr_full ) begin // TODO  
                                if(wr_preread_stage1_flushed) begin // if Ptwalk response has been stored in tlb for the flushed request, drop it.
                                    rg_stage1_flushed <= False;
                                    rg_replay_stage1_valid <= False;
                                end
                                else begin
                                    wr_from_stage1_valid <= True;
                                    rg_replay_stage1_valid <= False;
                                    rg_set_conflict <= False;
                                end
                            end
                            else begin // had another "set conflict" or "tlb_miss" or "req is a fence/sfence/io and the cache is not empty"
                                rg_replay_stage1_valid <= True;
                                rg_replay_stage1_req_data <= lv_core_req;
                                if((wr_itlb_response.hit && lv_tlb_is_io)) begin
                                    rg_io_request_valid <= True;
                                end
                                if(!wr_itlb_response.hit) begin
                                    rg_tlb_miss <= True; // takes priority over set_conflict
                                end
                                else if(lv_set_conflict) begin
                                    rg_set_conflict <= True;
                                end
                            end
                        end
                    end
                end
            end
        endrule
        //
        rule rl_update_rg_stage_2;
            rg_stage2_valid <= (wr_from_stage1_valid)?True:wr_stage2_valid;
        endrule
        //
        // Only cacheable requests proceed to this stage
        rule rl_stage_2;
            Bool lv_stage2_next_cycle_valid = wr_preread_stage2_valid;
            if(wr_flush) begin
                wr_stage2_valid <= False;
                lv_stage2_next_cycle_valid = False;
            end
            else if(wr_preread_stage2_valid) begin
                let stage2_data = wr_stage2_data;
                MHB_lookup_resp lv_mhb_resp = ifc_mhb.mv_mshr_lookup(rg_stage2_valid,stage2_data.paddr);
                // cache hit
                if(stage2_data.tag_hit) begin
                    wr_stage2_crq_data <= ICache_core_response{
                                                valid : stage2_data.tag_hit,
                                                req_id: stage2_data.req_id,
                                                packet: stage2_data.data,
                                                is_io: False,
                                                trap: False,
                                                excp_type: '0
                                                };
                    // TODO Update replacement data with selected way
                    wr_stage2_valid <= False;
                    lv_stage2_next_cycle_valid = False;
                end
                // MHB hit and corresponding word filled
                else if(lv_mhb_resp.hit_mhb && lv_mhb_resp.fb_valid) begin
                    wr_stage2_crq_data <= ICache_core_response{
                                            valid : lv_mhb_resp.hit_mhb,
                                            req_id: stage2_data.req_id,
                                            packet: lv_mhb_resp.fb_data,
                                            is_io: False,
                                            trap: False,
                                            excp_type: '0
                                            };
                    wr_stage2_valid <= False;
                    lv_stage2_next_cycle_valid = False;
                end
                // "Cache miss", "MHB miss" , "MHB hit but word not filled"
                else begin
                    // Entries available in MHB
                    if((lv_mhb_resp.hit_mhb && lv_mhb_resp.free_secondary) || (!lv_mhb_resp.hit_mhb && !ifc_mhb.mv_mshr_full())) begin
                        //
                        ifc_mhb.ma_allocate_entry(True,lv_mhb_resp.hit_mhb,lv_mhb_resp.mhb_index,
                                                stage2_data.paddr,stage2_data.req_id,stage2_data.replacement_way);
                        wr_stage2_valid <= False;
                        lv_stage2_next_cycle_valid = False;
                        // TODO Update replacement on miss (to be implemented)
                    end
                    else begin // Stall stage 2
                        wr_stage2_valid <= lv_stage2_next_cycle_valid;
                        rg_stage2_req_data <= wr_stage2_data; 
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
            match {.valid,.req_id,.crq_data} <- ifc_mhb.mv_miss_response();
            wr_mhb_crq_data <= ICache_core_response{
                                    valid : valid,
                                    req_id: req_id,
                                    packet: crq_data,
                                    is_io: False,
                                    trap: False,
                                    excp_type: '0
                                    };
        endrule
        //
        //
        rule rl_fill_request; // Doesn't compete with io as the io request is designed to be conservative and is only issued when Cache is empty
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
                if(wr_preread_replay_stage1_valid && rg_io_request_valid) begin
                    if(!wr_preread_stage1_flushed) begin
                        wr_io_crq_data <= ICache_core_response{
                                                valid : wr_mem_response.valid,
                                                req_id: '0,
                                                packet: wr_mem_response.data,
                                                is_io: True,
                                                trap: wr_mem_response.err,
                                                excp_type: `Inst_access_fault
                                                };
                    end
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
        interface put_response_from_ptw = interface Put
            method Action put(PTWalk_tlb_response#(TAdd#(`ppnsize,10), `varpages) in);
                wr_ptwalk_valid_response <= True;  // resets tlb miss replay stall
                let lv_tlb_miss_response <- ifc_itlb.response_from_ptw(in);
                wr_tlb_miss_response <= lv_tlb_miss_response;
            endmethod
        endinterface;
        //
        interface get_read_mem_req = toGet(ff_mem_request);
        interface put_read_mem_resp = interface Put
            method Action put(Mem_response in);
                wr_mem_response <= in;
            endmethod
        endinterface;
        //
        method ICache_status mv_icache_status();
            return wr_icache_status;
        endmethod
        //
        //
        method Action ma_core_request(ICache_core_request core_req);
            wr_core_req <= core_req;
        endmethod
        //
        method Vector#(`crq_input_size,ICache_core_response) mv_icache_response();
            return readVReg(wr_crq_response);
        endmethod
        //
        //
    endmodule
endpackage