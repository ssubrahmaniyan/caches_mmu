/*
see LICENSE.iitm

Author : Sujay Pandit, Nitya Ranganathan
Email id : contact.sujaypandit@gmail.com, nitya.ranganathan@gmail.com
Details : Non-Blocking I-Cache
          // Components: ITLB, Data Array, Tag Array, Valid bits, Replacement Bits, MHB, CRQ
          // VIPT cache supporting multiple misses under a miss
          // Requests from core received in-order
          // Responses to core sent in-order
          // TODO: Performance enhancements, Cache-side prefetch support

--------------------------------------------------------------------------------------------------
*/
package nb_icache;
    import icache_tagram      ::*;
    import icache_dataram     ::*;
    import icache_replacement ::*;
    import icache_mhb         ::*;
    import itlb               ::*;
    import io_func            ::*;
    import itlb_types         ::*;
    import nb_icache_types    ::*;
    import common_tlb_types   ::*;
    import crq                ::*;
    `include "icache_parameters.bsv"
    `include "Logger.bsv"
    //
    import DReg               ::*;
    import GetPut             ::*;
    import Vector             ::*;
    //import FIFO               ::*;
    import FIFOF              ::*;
    import SpecialFIFOs       ::*; 
    

    interface Ifc_nb_icache;
        // Inputs
        method Action ma_core_request(ICache_core_request core_req);
        method Action ma_csr_status(Bit#(2) prv, Bit#(`xlen) satp);
        interface Put#(PTWalk_tlb_response#(TAdd#(`ppnsize,10), `varpages)) put_response_from_ptw;
        interface Put#(Mem_response) put_read_mem_resp;
        // Outputs 
        method ActionValue#(ICache_core_response) mav_core_response();
        method ICache_status mv_icache_status();
        interface Get#(Mem_request) get_read_mem_req;
        interface Get#(PTWalk_tlb_request#(`vaddr)) get_request_to_ptw;
    endinterface
    //
    (*synthesize*)
    module mknb_icache(Ifc_nb_icache);

        // Fifos
        FIFOF#(Mem_request) ff_mem_request <- mkPipelineFIFOF();
        Wire#(Mem_request) wr_io_mem_request <- mkDWire(unpack(0));
        Wire#(Mem_request) wr_fill_mem_request <- mkDWire(unpack(0));

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
        Reg#(Bit#(`paddr)) rg_io_request_paddr <- mkReg(0);

        // Stage 2 registers
        Reg#(Bool) rg_stage2_valid <- mkReg(False);
        Reg#(Stage2) rg_stage2_req_data <- mkReg(unpack(0));
        Reg#(Bool) rg_stage2_next_cycle_stall <- mkReg(unpack(0));

        // LFB registers 
        Reg#(Bool) rg_fill_valid <- mkReg(False);
        Reg#(Mem_response) rg_fill_data <- mkReg(unpack(0));

        // Lookup registers
        Reg#(Bool) rg_lookup_valid <- mkDReg(False);
        Reg#(Bit#(`tagbits)) rg_lookup_ptag <- mkReg(0);
        Reg#(Stage2) rg_lookup_stage2 <- mkReg(unpack(0));

        // Wires
        Vector#(`crq_input_size,Wire#(ICache_core_response)) wr_crq_response <- replicateM(mkDWire(unpack(0)));
        Wire#(ICache_core_response) wr_stage1_crq_data <- mkDWire(unpack(0));
        Wire#(ICache_core_response) wr_stage2_crq_data <- mkDWire(unpack(0));
        Wire#(ICache_core_response) wr_mhb_crq_data <- mkDWire(unpack(0));
        Wire#(ICache_core_response) wr_io_crq_data <- mkDWire(unpack(0));

        Wire#(Bool) wr_flush <- mkDWire(False);
        //Wire#(Bool) wr_replay <- mkDWire(False);
        Wire#(Bool) wr_no_pending_requests <- mkDWire(False);
        Wire#(Bool) wr_icache_fence <- mkDWire(False);
        Wire#(ICache_status) wr_icache_status <- mkDWire(unpack(0));
        Wire#(ICache_core_request) wr_core_req <- mkDWire(unpack(0));
        Wire#(Mem_response) wr_mem_response <- mkDWire(unpack(0));
        
        Wire#(Bool) wr_fb_release_valid <- mkDWire(False);
        Wire#(Bit#(`setbits)) wr_fb_release_index <- mkDWire(0);

        Wire#(Bool) wr_lookup_arrays_valid <- mkDWire(False);
        Wire#(Bit#(`vaddr)) wr_lookup_vaddr <- mkDWire(0);
        Wire#(Bit#(`reqid_width)) wr_lookup_reqid <- mkDWire(0);
        Wire#(Bit#(TLog#(`numways))) wr_replacement_way <- mkDWire(0);

        Wire#(Bool) wr_replay_stage1_valid <- mkDWire(False);
        Wire#(Bool) wr_replay_stage1_tlb_response <- mkDWire(False);
        Wire#(Bool) wr_replay_stage1_io_response <- mkDWire(False);
        Wire#(ICache_core_request) wr_replay_stage1_req_data <- mkDWire(unpack(0));
        Wire#(Bool) wr_stage2_next_cycle_stall <- mkDWire(False);
        Wire#(Stage2) wr_stage2_data <- mkDWire(unpack(0));
        Wire#(Bool) wr_from_stage1_valid <- mkDWire(False);
        Wire#(Bool) wr_stage2_valid <- mkDWire(False);

        Wire#(Bool) wr_ptwalk_valid_response <- mkDWire(False);
        Wire#(ITLB_core_response#(`paddr)) wr_tlb_lookup_response <- mkDWire(unpack(0));
        Wire#(ITLB_core_response#(`paddr)) wr_tlb_miss_response <- mkDWire(unpack(0));
        Wire#(ITLB_core_response#(`paddr)) wr_tlb_response <- mkDWire(unpack(0));
        Wire#(Bool) wr_itlb_sfence <- mkDWire(False);
        //
        Wire#(Bool) wr_preread_replay_stage1_valid <- mkDWire(False);
        Wire#(ICache_core_request) wr_preread_replay_stage1_req_data <- mkDWire(unpack(0));
        Wire#(Bool) wr_preread_tlb_miss <- mkDWire(False);
        Wire#(Bool) wr_preread_stage2_valid <- mkDWire(False);
        Wire#(Bool) wr_preread_stage2_next_cycle_stall <- mkDWire(False);
        Wire#(Bool) wr_preread_stage1_flushed <- mkDWire(False);
        Vector#(`numsets, Vector#(`numways,Wire#(Bit#(1)))) wr_preread_icache_valid <- replicateM(replicateM(mkDWire(0)));
        Wire#(Bool) wr_preread_io_valid <- mkDWire(False);
        Wire#(Bool) wr_preread_io_issued <- mkDWire(False);

        // I-Cache structures
        Vector#(`numsets, Vector#(`numways,Reg#(Bit#(1)))) rg_icache_valid <- replicateM(replicateM(mkReg(0)));
        Ifc_icache_tagram ifc_tag <- mkicache_tagram();
        Ifc_icache_dataram ifc_data <- mkicache_dataram();
        Ifc_icache_mhb ifc_mhb <- mkicache_mhb();
        Ifc_icache_replacement ifc_replacement <- mkicache_replacement();
        Ifc_itlb ifc_itlb <- mkitlb(0);
        Ifc_crq ifc_crq <- mk_crq();


        rule rl_pre_read_registers;
            for(Integer i=0;i<`numsets;i=i+1) begin
                for(Integer j=0;j<`numways;j=j+1) begin
                    wr_preread_icache_valid[i][j] <= rg_icache_valid[i][j];
                end
            end
            wr_preread_replay_stage1_valid <= rg_replay_stage1_valid;
            wr_preread_replay_stage1_req_data <= rg_replay_stage1_req_data;
            wr_preread_stage2_valid <= rg_stage2_valid;
            wr_preread_stage2_next_cycle_stall <= rg_stage2_next_cycle_stall;
            wr_preread_tlb_miss <= rg_tlb_miss;
            wr_preread_stage1_flushed <= rg_stage1_flushed;
            wr_preread_io_valid <= rg_io_request_valid;
            wr_preread_io_issued <= rg_io_request_issued;
        endrule
        //
        //
        rule rl_set_replay_registers;
          // stage2 stall next cycle
          if (wr_stage2_next_cycle_stall) begin
            // NOTE: CHECK
            rg_replay_stage1_valid <= wr_core_req.valid ? True : (wr_replay_stage1_io_response ? False : wr_preread_replay_stage1_valid);
            rg_replay_stage1_req_data <= wr_core_req.valid ? wr_core_req : rg_replay_stage1_req_data;
          end
          else begin
            rg_replay_stage1_valid <= wr_replay_stage1_io_response ? False : wr_replay_stage1_valid;
            rg_replay_stage1_req_data <= wr_replay_stage1_req_data;
          end
          `logLevel( icache, 1, $format("ICACHE: set_replay: wr_stage2_next_stall %b wr_core_req_valid %b wr_stage1_io_resp %b rg_replay_stage1 %b wr_replay_stage1 %b rg_stage1_flushed %b rg_io_valid %b rg_io_issued %b", wr_stage2_next_cycle_stall, wr_core_req.valid, wr_replay_stage1_io_response, wr_preread_replay_stage1_valid, wr_replay_stage1_valid, wr_preread_stage1_flushed, wr_preread_io_valid, wr_preread_io_issued))
        endrule
        //
        //
        // Cache busy is set if MHB all primary entries full, 
        //                      valid request pending to be replayed,
        //                      a valid request stalled in stage 2
        rule rl_check_cache_busy;
            ICache_status lv_status = unpack(0);
            lv_status.cache_busy = (ifc_mhb.mv_mshr_full || wr_preread_replay_stage1_valid || wr_preread_stage2_next_cycle_stall);
            lv_status.mshr_status = ifc_mhb.mv_mshr_count_free();
            wr_icache_status <= lv_status; 
            `logLevel( icache, 1, $format("ICACHE: Status: busy %b # mhb_full %b replay_valid %b stage2_stall %b", lv_status.cache_busy, ifc_mhb.mv_mshr_full(), wr_preread_replay_stage1_valid, wr_preread_stage2_next_cycle_stall))
        endrule
        //
        rule rl_check_pending_requests;
            wr_no_pending_requests <= (!wr_preread_stage2_valid && ifc_mhb.mv_mshr_empty());
            `logLevel( icache, 1, $format("ICACHE: Status: pending_requests? %b", (wr_preread_stage2_valid || !ifc_mhb.mv_mshr_empty())))
        endrule
        //
        rule rl_lookup_replacement;
          Bit#(`setbits) lv_set_index = wr_lookup_vaddr[`setbits+`byteoffset+`wordoffset-1:`byteoffset+`wordoffset];
          Vector#(`numways,Bit#(1)) lv_way_valid = readVReg(wr_preread_icache_valid[lv_set_index]);
          Bit#(TLog#(`numways)) lv_replacement_way = '0;

          lv_replacement_way <- ifc_replacement.mav_replace_way(lv_set_index, lv_way_valid); // TODO
          wr_replacement_way <= lv_replacement_way;
        endrule
        //
        rule rl_lookup_arrays;
            if(wr_lookup_arrays_valid) begin
                Bit#(`setbits) lv_set_index = wr_lookup_vaddr[`setbits+`byteoffset+`wordoffset-1:`byteoffset+`wordoffset];
                Vector#(`numways,Bit#(1)) lv_way_valid = readVReg(wr_preread_icache_valid[lv_set_index]);
                //
                Stage2 lv_stage2_data = unpack(0);
                lv_stage2_data.paddr = wr_tlb_response.address;
                lv_stage2_data.req_id = wr_lookup_reqid;
                if (`numways == 1) begin // direct-mapped
                  lv_stage2_data.replacement_way = 0; // always way = 0
                end
                else begin // set-associative
                  lv_stage2_data.replacement_way = wr_replacement_way;
                end
                lv_stage2_data.way_valid = lv_way_valid;
                //
                // send BRAM request
                ifc_tag.ma_read_request(wr_lookup_arrays_valid,wr_lookup_vaddr);
                ifc_data.ma_read_request(wr_lookup_arrays_valid,wr_lookup_vaddr);
                //
                rg_lookup_valid <= wr_lookup_arrays_valid; // TODO
                rg_lookup_stage2 <= lv_stage2_data; // contains partial data
                `logLevel( icache, 1, $format("ICACHE: Stage1: Read arrays: req_id %d set %d way_valid %b vaddr %h", lv_stage2_data.req_id, lv_set_index, lv_way_valid, wr_lookup_vaddr))
            end
        endrule
        //
        rule rl_lookup_response;
            if(rg_lookup_valid && !wr_preread_stage2_next_cycle_stall) begin
                Bit#(`numways) lv_tagram_response = '0;
                Bit#(`numways) lv_hitmask = '0;
                //
                Stage2 lv_stage2_data = rg_lookup_stage2;
                //
                lv_tagram_response = ifc_tag.mv_read_response(rg_lookup_ptag);
                lv_hitmask = (lv_tagram_response & pack(lv_stage2_data.way_valid));
                lv_stage2_data.tag_hit = unpack(|lv_hitmask);

                lv_stage2_data.hit_way = '0;
                for (Integer i=0; i<`numways; i=i+1) begin
                  if (lv_hitmask[i] == 1) begin
                    lv_stage2_data.hit_way = fromInteger(i);
                  end
                end
                //     
                // Extracting corresponding word from the block
                //
                Bit#(`blocksize) lv_cache_block = ifc_data.mv_read_response(lv_hitmask);
                Bit#(`blocksize) lv_cache_block_original = lv_cache_block;
                Bit#(TAdd#(TAdd#(`wordoffset,`byteoffset),3)) lv_shift_amt = lv_stage2_data.paddr[`wordoffset+`byteoffset+2:0] << 3; // number of bits to shift
                lv_cache_block = lv_cache_block >> lv_shift_amt;
                lv_stage2_data.data = lv_cache_block[`wordsize-1:0];
                //
                wr_stage2_data <= lv_stage2_data; 
                `logLevel( icache, 1, $format("ICACHE: Stage2: Read response: req_id %d hit_mask %b hit %b way %d # paddr %h ptag %h data %h shift %d packet %h", lv_stage2_data.req_id, lv_hitmask, lv_stage2_data.tag_hit, lv_stage2_data.hit_way, lv_stage2_data.paddr, rg_lookup_ptag, lv_cache_block_original, lv_shift_amt, lv_stage2_data.data))
            end
            else begin
                wr_stage2_data <= rg_stage2_req_data;
                `logLevel( icache, 1, $format("ICACHE: Stage2: No read response: lookup_valid %b req_id %d", rg_lookup_valid, rg_stage2_req_data.req_id))
            end
        endrule
        //
        // TLB miss causes rl_replay_req to stall until ITLB receives a valid response from PTWalk
        // Reset rg_tlb_miss when a valid ptwalk response is received and check if request can be sent to stage2
        //
        rule rl_allow_tlb_miss_replay;
            let lv_core_req = wr_preread_replay_stage1_req_data; 
            Bool lv_set_conflict =  False;  
            if(wr_preread_tlb_miss && wr_ptwalk_valid_response) begin 
                //
                rg_tlb_miss <= False;
                if(wr_preread_stage1_flushed) begin // if Ptwalk response has been stored in tlb for the flushed request, drop it.
                    rg_stage1_flushed <= False;
                    // rg_tlb_miss <= False;
                    //wr_replay_stage1_valid <= False;
                    wr_replay_stage1_tlb_response <= True;
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
                //         wr_replay_stage1_valid <= False;
                //         rg_stage2_valid <= True;
                //     end
                // end
            end
        endrule
        //
        //
        rule rl_icache_fence(wr_icache_fence);
            // reset valid bits
            for(Integer i=0;i<`numsets;i=i+1) begin
                for(Integer j=0;j<`numways;j=j+1) begin
                    rg_icache_valid[i][j] <= 0;  
                end
            end
            // reset replacement
            if (`numways > 1) begin
              ifc_replacement.ma_reset();
            end
            `logLevel( icache, 1, $format("ICACHE: Fence: Invalidating all sets."))
        endrule
        //
        rule rl_itlb_translate_request;
            ICache_core_request lv_core_req = unpack(0);
            ITLB_core_response#(`paddr) lv_itlb_response = unpack(0);
            if(wr_core_req.valid && !wr_core_req.flush && !wr_core_req.fence && !wr_core_req.sfence) begin // valid new regular core req (not flush/fence/sfence)
                lv_core_req = wr_core_req; 
                lv_itlb_response <- ifc_itlb.translate(lv_core_req.vaddr);
                `logLevel( icache, 1, $format("ICACHE: Stage1: ITLB lookup (current) vaddr %h: ", lv_core_req.vaddr, fshow(lv_itlb_response)))
            end
            else if(wr_preread_replay_stage1_valid && !wr_preread_replay_stage1_req_data.fence && !wr_preread_replay_stage1_req_data.sfence 
                    && !wr_preread_io_valid && !wr_preread_tlb_miss) begin // valid replay
                lv_core_req = wr_preread_replay_stage1_req_data;
                lv_itlb_response <- ifc_itlb.translate(lv_core_req.vaddr);
                `logLevel( icache, 1, $format("ICACHE: Stage1: ITLB lookup (replay) vaddr %h: ", lv_core_req.vaddr, fshow(lv_itlb_response)))
            end
            wr_tlb_lookup_response <= lv_itlb_response;
        endrule
        //
        // Select response from itlb or ptw
        rule rl_itlb_select_response;
          // send tlb response in the same cycle for both lookup and response from PTW (fault response won't be installed in tlb)
          // response from ptw is latched response
          wr_tlb_response <= (wr_ptwalk_valid_response) ? wr_tlb_miss_response : (rg_tlb_miss ? unpack(0) : wr_tlb_lookup_response);
        endrule
        //
        rule rl_itlb_sfence_request(wr_itlb_sfence);
            ifc_itlb.sfence();
            `logLevel( icache, 1, $format("ICACHE: Sfence: Invalidating TLB."))
        endrule
        //
        // CRQ can accept response from 4 sources: 
        // "Stage 2 hit (MHB/Cache)", "Request served in MHB" , "I/O Response", "Stage1 (ITLB trap/Fences)"
        //
        rule rl_send_responses_to_crq;
            Vector#(`crq_input_size, ICache_core_response) lv_cache_response;

            lv_cache_response[0] = wr_stage2_crq_data;
            lv_cache_response[1] = wr_mhb_crq_data;
            lv_cache_response[2] = wr_io_crq_data;
            lv_cache_response[3] = wr_stage1_crq_data;
            ifc_crq.ma_icache_response (lv_cache_response);
        endrule
        //
        rule rl_send_flush_to_crq;
            ifc_crq.ma_flush(wr_flush);
        endrule
        //
        rule rl_send_flush_to_mhb;
          ifc_mhb.ma_flush(wr_flush);
        endrule
        //
        //
        rule rl_stage1;
            Bool lv_stage1_enabled = False;

            // pick latched request or current cycle's core request
            let lv_core_req = wr_preread_replay_stage1_valid ? wr_preread_replay_stage1_req_data : wr_core_req;

            if(wr_flush) begin // No new requests are accepted from core in flush cycle
                `logLevel( icache, 1, $format("ICACHE: Stage1: Flush."))

                // invalidate pending request if it's a fence/sfence/not-tlb-miss/not-io-issued
                if(wr_preread_replay_stage1_valid) begin
                    if(!wr_preread_tlb_miss && !wr_preread_io_issued && !lv_core_req.fence && !lv_core_req.sfence) begin
                        wr_replay_stage1_valid <= False;
                        rg_io_request_valid <= False;
                        `logLevel( icache, 1, $format("ICACHE: Stage1: Setting replay request as invalid (case 1)."))
                    end
                    // After flush cycle, fence, sfence, ptw response and io response need to processed => set replay valid
                    else begin
                        // fence and sfence are always valid
                        if (lv_core_req.fence || lv_core_req.sfence) begin
                          wr_replay_stage1_valid <= True;
                          wr_replay_stage1_req_data <= lv_core_req;
                          `logLevel( icache, 1, $format("ICACHE: Stage1: Setting replay request as valid."))
                        end
                        // set replay valid and request as flushed, it will be executed but response will not be sent to core
                        // exclude the case when response and flush arrive in the same cycle (responses will also be dropped in crq)
                        else if((wr_preread_tlb_miss && !wr_ptwalk_valid_response) || (wr_preread_io_issued && !wr_mem_response.valid)) begin
                          wr_replay_stage1_valid <= True;
                          wr_replay_stage1_req_data <= lv_core_req;
                          rg_stage1_flushed <= True;
                          `logLevel( icache, 1, $format("ICACHE: Stage1: Setting replay request as valid and flushed."))
                        end
                        else begin
                          wr_replay_stage1_valid <= False;
                          `logLevel( icache, 1, $format("ICACHE: Stage1: Setting replay request as invalid (case 2)."))
                        end
                    end // valid after flush for special cases
                end // replay valid
            end // flush

            // Regular request (no flush)
            else begin
                if (wr_preread_replay_stage1_valid) begin
                  `logLevel( icache, 1, $format("ICACHE: Stage1: Replay core_req: ", fshow(lv_core_req)))
                end

                // No requests in pipe
                if(wr_no_pending_requests) begin

                    // stage1 gating conditions (TODO: optimization)
                    lv_stage1_enabled = wr_preread_replay_stage1_valid 
                                          ? (rg_tlb_miss ? wr_ptwalk_valid_response : !wr_preread_io_valid)
                                          : lv_core_req.valid;
                    if (!lv_stage1_enabled) begin
                      `logLevel( icache, 1, $format("ICACHE: Stage1 (no pending reqs): Disabled: replay %b tlb_miss %b ptw_resp %b req_valid %b io_valid %b", wr_preread_replay_stage1_valid, rg_tlb_miss, wr_ptwalk_valid_response, lv_core_req.valid, wr_preread_io_valid))
                    end
                    else begin
                      `logLevel( icache, 1, $format("ICACHE: Stage1 (no pending reqs): Enabled: replay %b tlb_miss %b ptw_resp %b req_valid %b io_valid %b", wr_preread_replay_stage1_valid, rg_tlb_miss, wr_ptwalk_valid_response, lv_core_req.valid, wr_preread_io_valid))
                    end

                    // stage1 enabled
                    if (lv_stage1_enabled) begin
                        Bool lv_set_conflict =  False; 
                        Bool lv_is_io = isIO(wr_tlb_response.address, True);  
                        //
                        if(wr_fb_release_valid && (wr_fb_release_index == lv_core_req.vaddr[`setbits+`wordoffset+`byteoffset-1:`wordoffset+`byteoffset])) begin
                            lv_set_conflict = True;
                            `logLevel( icache, 1, $format("ICACHE: Stage1: Set conflict for req_id %d, set %d", lv_core_req.req_id, wr_fb_release_index))
                        end
                        // 
                        if(lv_core_req.fence) begin
                            // invalidate all cache entries
                            wr_icache_fence <= lv_core_req.fence;
                            wr_stage1_crq_data <= ICache_core_response{
                                                valid : lv_core_req.fence,
                                                req_id: lv_core_req.req_id,
                                                packet: '0,
                                                trap: False,
                                                cause: wr_tlb_response.cause
                                                };
                        end
                        else if(lv_core_req.sfence) begin
                            // invalidate TLB 
                            wr_itlb_sfence <= lv_core_req.sfence;
                            wr_stage1_crq_data <= ICache_core_response{
                                                valid : lv_core_req.sfence,
                                                req_id: lv_core_req.req_id,
                                                packet: '0,
                                                trap: False,
                                                cause: wr_tlb_response.cause
                                                };
                        end
                        else begin
                            // TODO: no lookups while waiting for PTW (look up when response is received)
                            // TODO: may need to rearrange code to move lookup earlier unconditionally (if not optimized by tool)
                            wr_lookup_arrays_valid <= lv_core_req.valid; // index into 4 arrays: status, repl, tag, data.
                            wr_lookup_vaddr <= lv_core_req.vaddr;
                            rg_lookup_ptag <= truncateLSB(wr_tlb_response.address);
                            wr_lookup_reqid <= lv_core_req.req_id;
                            //
                            if(wr_tlb_response.trap) begin
                                if (!wr_preread_stage1_flushed) begin
                                  wr_stage1_crq_data <= ICache_core_response{
                                                  valid : wr_tlb_response.trap,
                                                  req_id: lv_core_req.req_id,
                                                  packet: zeroExtend(lv_core_req.vaddr),
                                                  trap: wr_tlb_response.trap,
                                                  cause: wr_tlb_response.cause
                                                  };
                                  `logLevel( icache, 1, $format("ICACHE: Stage1: Exception from TLB sent for req_id %d, cause %d!", lv_core_req.req_id, wr_tlb_response.cause))
                                end
                                else begin
                                  `logLevel( icache, 1, $format("ICACHE: Stage1: Exception from TLB flushed for req_id %d, cause %d!", lv_core_req.req_id, wr_tlb_response.cause))
                                end // flushed
                            end
                            else if(wr_tlb_response.hit && !wr_preread_stage1_flushed && !lv_is_io && !lv_set_conflict) begin  
                                wr_from_stage1_valid <= True; // Stage2 request data will be received through wr_stage2_data in next cycle
                              `logLevel( icache, 1, $format("ICACHE: Stage1: TLB hit for req_id %d, sending to Stage2.", lv_core_req.req_id))
                            end
                            else if(wr_tlb_response.hit && wr_preread_stage1_flushed) begin
                              `logLevel( icache, 1, $format("ICACHE: Stage1: TLB hit for flushed req_id %d, dropping.", lv_core_req.req_id))
                            end
                            else if(wr_tlb_response.hit && lv_is_io) begin
                                rg_io_request_valid <= True; 
                                rg_io_request_issued <= False;
                                rg_io_request_paddr <= wr_tlb_response.address;
                                wr_replay_stage1_valid <= True; // request is not actually replayed, just to stall Cache till response is received from fabric
                                wr_replay_stage1_req_data <= lv_core_req;
                                `logLevel( icache, 1, $format("ICACHE: Stage1: IO request (req_id %d), enqueueing.", lv_core_req.req_id))
                            end
                            else begin
                                wr_replay_stage1_valid <= True;
                                wr_replay_stage1_req_data <= lv_core_req;
                                if(!wr_tlb_response.hit) begin
                                    rg_tlb_miss <= True; // takes priority over set_conflict
                                    `logLevel( icache, 1, $format("ICACHE: Stage1: TLB miss for req_id %d, setting replay.", lv_core_req.req_id))
                                end
                                else if(lv_set_conflict) begin
                                    rg_set_conflict <= True;
                                    `logLevel( icache, 1, $format("ICACHE: Stage1: Set conflict for req_id %d, setting replay.", lv_core_req.req_id))
                                end
                                else begin
                                    // TODO: add assertion
                                    `logLevel( icache, 1, $format("ICACHE: Stage1: Unknown stall for req_id %d, setting replay.", lv_core_req.req_id))
                                    $finish(0);
                                end 
                            end // tlb miss or set conflict
                        end // !fence and !sfence
                    end // stage1 enabled

                    // stage1 gated
                    else begin
                      // Stall on tlb miss, io; TODO: optimize
                      if (lv_core_req.valid) begin
                        if (wr_preread_io_valid) begin
                          wr_replay_stage1_valid <= True;
                          wr_replay_stage1_req_data <= lv_core_req;
                          `logLevel( icache, 1, $format("ICACHE: Stage1: IO request waiting (req_id %d), setting replay.", lv_core_req.req_id))
                        end
                        else begin
                          wr_replay_stage1_valid <= rg_tlb_miss;
                          wr_replay_stage1_req_data <= lv_core_req; 
                          `logLevel( icache, 1, $format("ICACHE: Stage1: TLB waiting for PTW for req_id %d, setting replay.", lv_core_req.req_id))
                        end
                      end
                    end // stage1 gated
                end // no requests pending
                //
                // Requests pending in pipe
                else begin

                    // stage1 gating conditions (TODO: optimization)
                    lv_stage1_enabled = wr_preread_replay_stage1_valid 
                                          ? (rg_tlb_miss ? wr_ptwalk_valid_response : (!lv_core_req.fence && !lv_core_req.sfence && !wr_preread_io_valid))
                                          : (lv_core_req.valid && !lv_core_req.fence && !lv_core_req.sfence);
                    if (!lv_stage1_enabled) begin
                      `logLevel( icache, 1, $format("ICACHE: Stage1 (pending reqs): Disabled: replay %b tlb_miss %b ptw_resp %b req_valid %b fence %b sfence %b io_valid %b", wr_preread_replay_stage1_valid, rg_tlb_miss, wr_ptwalk_valid_response, lv_core_req.valid, lv_core_req.fence, lv_core_req.sfence, wr_preread_io_valid))
                    end
                    else begin
                      `logLevel( icache, 1, $format("ICACHE: Stage1 (pending reqs): Enabled: replay %b tlb_miss %b ptw_resp %b req_valid %b fence %b sfence %b io_valid %b", wr_preread_replay_stage1_valid, rg_tlb_miss, wr_ptwalk_valid_response, lv_core_req.valid, lv_core_req.fence, lv_core_req.sfence, wr_preread_io_valid))
                    end

                    // NOTE: CHECK this assumption: implicit condition: !rg_replay_stage1_valid && !rg_stage2_next_cycle_valid (otherwise cache would be busy)
                    // can happen as mhb full count is registered
                    if (lv_stage1_enabled) begin 
                        Bool lv_set_conflict =  False;
                        Bool lv_is_io = isIO(wr_tlb_response.address, True); 
                        //
                        wr_lookup_arrays_valid <= lv_core_req.valid; // index into 4 arrays: status, repl, tag, data.
                        wr_lookup_vaddr <= lv_core_req.vaddr;
                        rg_lookup_ptag <= truncateLSB(wr_tlb_response.address);
                        wr_lookup_reqid <= lv_core_req.req_id;
                        //
                        if(wr_fb_release_valid && (wr_fb_release_index == lv_core_req.vaddr[`setbits+`wordoffset+`byteoffset-1:`wordoffset+`byteoffset])) begin
                            lv_set_conflict = True;
                            `logLevel( icache, 1, $format("ICACHE: Stage1: Set conflict for req_id %d, set %d", lv_core_req.req_id, wr_fb_release_index))
                        end
                        //
                        if(wr_tlb_response.trap) begin
                            if (!wr_preread_stage1_flushed) begin
                              wr_stage1_crq_data <= ICache_core_response{
                                                    valid : wr_tlb_response.trap,
                                                    req_id: lv_core_req.req_id,
                                                    packet: zeroExtend(lv_core_req.vaddr),
                                                    trap: wr_tlb_response.trap,
                                                    cause: wr_tlb_response.cause
                                                    };
                              `logLevel( icache, 1, $format("ICACHE: Stage1: Exception from TLB sent for req_id %d, cause %d!", lv_core_req.req_id, wr_tlb_response.cause))
                            end
                            else begin
                              `logLevel( icache, 1, $format("ICACHE: Stage1: Exception from TLB flushed for req_id %d, cause %d!", lv_core_req.req_id, wr_tlb_response.cause))
                            end // flushed
                        end
                        else if(wr_tlb_response.hit && !wr_preread_stage1_flushed && !lv_is_io && !lv_set_conflict) begin  
                            wr_from_stage1_valid <= True;
                            `logLevel( icache, 1, $format("ICACHE: Stage1: TLB hit for req_id %d, sending to Stage2.", lv_core_req.req_id))
                        end
                        else if(wr_tlb_response.hit && wr_preread_stage1_flushed) begin
                            `logLevel( icache, 1, $format("ICACHE: Stage1: TLB hit for flushed req_id %d, dropping.", lv_core_req.req_id))
                        end
                        else if(wr_tlb_response.hit && lv_is_io) begin
                            rg_io_request_valid <= True;
                            rg_io_request_issued <= False; 
                            rg_io_request_paddr <= wr_tlb_response.address;
                            wr_replay_stage1_valid <= True; // request is not actually replayed, just to stall Cache till response is received from fabric
                            wr_replay_stage1_req_data <= lv_core_req;
                            `logLevel( icache, 1, $format("ICACHE: Stage1: IO request (req_id %d), enqueueing.", lv_core_req.req_id))
                        end
                        else begin
                            wr_replay_stage1_valid <= True;
                            wr_replay_stage1_req_data <= lv_core_req;
                            if(!wr_tlb_response.hit) begin
                                rg_tlb_miss <= True; // takes priority over set_conflict
                                `logLevel( icache, 1, $format("ICACHE: Stage1: TLB miss for req_id %d, setting replay.", lv_core_req.req_id))
                            end
                            else if(lv_set_conflict) begin
                                rg_set_conflict <= True;
                                `logLevel( icache, 1, $format("ICACHE: Stage1: Set conflict for req_id %d, setting replay.", lv_core_req.req_id))
                            end
                            else begin
                              // TODO: add assertion
                              `logLevel( icache, 1, $format("ICACHE: Stage1: Unknown stall for req_id %d, setting replay.", lv_core_req.req_id))
                              $finish(0);
                            end 
                        end // tlb miss or set conflict
                    end // stage1 enabled

                    // stage1 gated
                    else begin
                      if (lv_core_req.valid) begin
                        // Stall on tlb miss, fence, sfence, io; TODO: optimize
                        if (lv_core_req.fence || lv_core_req.sfence) begin
                          wr_replay_stage1_valid <= True;
                          wr_replay_stage1_req_data <= lv_core_req;
                          `logLevel( icache, 1, $format("ICACHE: Stage1: Pending requests in pipe, setting replay for fence/sfence."))
                        end
                        else if (wr_preread_io_valid) begin
                          wr_replay_stage1_valid <= True;
                          wr_replay_stage1_req_data <= lv_core_req;
                          `logLevel( icache, 1, $format("ICACHE: Stage1: IO request waiting (req_id %d), setting replay.", lv_core_req.req_id))
                        end
                        else begin
                          wr_replay_stage1_valid <= rg_tlb_miss;
                          wr_replay_stage1_req_data <= lv_core_req;
                          `logLevel( icache, 1, $format("ICACHE: Stage1: TLB waiting for PTW for req_id %d, setting replay.", lv_core_req.req_id))
                        end
                      end
                    end // stage1 gated
              end // requests pending

            end // no flush
        endrule
        //
        //
        rule rl_serve_mshr_requests;
            match {.valid,.req_id,.crq_data} <- ifc_mhb.mv_miss_response();
            wr_mhb_crq_data <= ICache_core_response{
                                    valid : valid,
                                    req_id: req_id,
                                    packet: crq_data,
                                    trap: False,
                                    cause: '0
                                    };
            if (valid) begin
              `logLevel( icache, 1, $format("ICACHE: MHB: Read response for req_id %d: ", req_id, fshow(crq_data)))
            end
        endrule
        //
        //
        rule rl_update_rg_stage2;
            //rg_stage2_valid <= (wr_from_stage1_valid)?True:wr_stage2_valid;
            rg_stage2_valid <= wr_stage2_valid ? True : wr_from_stage1_valid;
        endrule
        //
        // Only cacheable requests proceed to this stage
        rule rl_stage2;
            Bool lv_stage2_next_cycle_stall = wr_preread_stage2_valid;
            if(wr_flush) begin
                wr_stage2_valid <= False;
                lv_stage2_next_cycle_stall = False;
                `logLevel( icache, 1, $format("ICACHE: Stage2: Flush."))
            end
            else if(wr_preread_stage2_valid) begin
                let stage2_data = wr_stage2_data;
                Bit#(`setbits) lv_set_index = stage2_data.paddr[`setbits+`byteoffset+`wordoffset-1:`byteoffset+`wordoffset];

                MHB_lookup_resp lv_mhb_resp = ifc_mhb.mv_mshr_lookup(rg_stage2_valid,stage2_data.paddr);
                // cache hit
                if(stage2_data.tag_hit) begin
                    wr_stage2_crq_data <= ICache_core_response{
                                                valid : stage2_data.tag_hit,
                                                req_id: stage2_data.req_id,
                                                packet: stage2_data.data,
                                                trap: False,
                                                cause: '0
                                                };
                    if (`numways > 1) begin
                      ifc_replacement.ma_update(lv_set_index, stage2_data.hit_way, True);
                    end
                    wr_stage2_valid <= False;
                    lv_stage2_next_cycle_stall = False;
                    `logLevel( icache, 1, $format("ICACHE: Stage2: RAM hit for req_id %d data %h", stage2_data.req_id, stage2_data.data))
                end
                // MHB hit and corresponding word filled
                else if(lv_mhb_resp.hit_mhb && lv_mhb_resp.fb_valid) begin
                    wr_stage2_crq_data <= ICache_core_response{
                                            valid : lv_mhb_resp.hit_mhb,
                                            req_id: stage2_data.req_id,
                                            packet: lv_mhb_resp.fb_data,
                                            trap: False,
                                            cause: '0
                                            };
                    if (`numways > 1) begin
                      ifc_replacement.ma_update(lv_set_index, lv_mhb_resp.replacement_way, True);
                    end
                    wr_stage2_valid <= False;
                    lv_stage2_next_cycle_stall = False;
                    `logLevel( icache, 1, $format("ICACHE: Stage2: MHB hit for req_id %d data %h", stage2_data.req_id, lv_mhb_resp.fb_data))
                end
                // "Cache miss", "MHB miss" , "MHB hit but word not filled"
                else begin
                    // Entries available in MHB
                    if((lv_mhb_resp.hit_mhb && lv_mhb_resp.free_secondary) || (!lv_mhb_resp.hit_mhb && !ifc_mhb.mv_mshr_full())) begin
                        //
                        ifc_mhb.ma_allocate_entry(True,lv_mhb_resp.hit_mhb,lv_mhb_resp.mhb_index,
                                                stage2_data.paddr,stage2_data.req_id,stage2_data.replacement_way);
                        wr_stage2_valid <= False;
                        lv_stage2_next_cycle_stall = False;
                        `logLevel( icache, 1, $format("ICACHE: Stage2: Miss for req_id %d, allocating MHB entry: paddr %h hit %b index %h repl_way %d ", stage2_data.req_id, stage2_data.paddr, lv_mhb_resp.hit_mhb, lv_mhb_resp.mhb_index, stage2_data.replacement_way))

                        // update replacement on hit/miss
                        if (`numways > 1) begin
                          if (lv_mhb_resp.hit_mhb) begin
                            ifc_replacement.ma_update(lv_set_index, lv_mhb_resp.replacement_way, True);
                          end
                          else begin
                            ifc_replacement.ma_update(lv_set_index, '0, False);
                          end
                        end
                    end
                    else begin // Stall stage 2
                        //wr_stage2_valid <= lv_stage2_next_cycle_stall; // always True under this condition
                        wr_stage2_valid <= True;
                        rg_stage2_req_data <= wr_stage2_data; 
                        `logLevel( icache, 1, $format("ICACHE: Stage2: Miss for req_id %d, MHB full, stalling.", stage2_data.req_id))
                        // stall => no replacement update
                    end
                end
            end
            // Convey to stage 1 in the current cycle that stage 2 will be free next cycle
            // So that stage 1 can latch a request for stage 2 in the current cycle itself.
            wr_stage2_next_cycle_stall <= lv_stage2_next_cycle_stall;
            rg_stage2_next_cycle_stall <= lv_stage2_next_cycle_stall;
        endrule
        //
        //
        rule rl_handle_fill_request;
            Mem_request lv_stage1_io_request = unpack(0);
            Mem_request lv_mhb_fill_request = unpack(0);
            //
            // no flush, replay valid, io valid and not issued, mshr empty (TODO: stage2)
            if(!wr_flush && wr_preread_replay_stage1_valid && wr_preread_io_valid && !wr_preread_io_issued && ifc_mhb.mv_mshr_empty()) begin
                lv_stage1_io_request = Mem_request{ valid: True,
                                                paddr: rg_io_request_paddr,
                                                mhb_id: 0,
                                                burst_len: 0,
                                                burst_size: 3'b010,
                                                io: True};
            end
            //
            lv_mhb_fill_request = ifc_mhb.mv_fill_request();
            //
            if(lv_stage1_io_request.valid) begin
                ff_mem_request.enq(lv_stage1_io_request);
                rg_io_request_issued <= True;
                `logLevel( icache, 1, $format("ICACHE: Request to IO: ", fshow(lv_stage1_io_request)))
            end
            else if(lv_mhb_fill_request.valid) begin
                ff_mem_request.enq(lv_mhb_fill_request);
                ifc_mhb.ma_set_issued(lv_mhb_fill_request.valid);
                `logLevel( icache, 1, $format("ICACHE: Request to Mem: ", fshow(lv_mhb_fill_request)))
            end
        endrule
        //
        //
        rule rl_poll_response_from_memory;
            if(wr_mem_response.valid) begin
                // valid io request is issued and waiting for response (TODO: optimize)
                if(wr_preread_replay_stage1_valid && wr_preread_io_valid && wr_preread_io_issued) begin
                    if(!wr_preread_stage1_flushed) begin
                        wr_io_crq_data <= ICache_core_response{
                                                valid : wr_mem_response.valid,
                                                req_id: wr_preread_replay_stage1_req_data.req_id,
                                                packet: wr_mem_response.data,
                                                trap: wr_mem_response.err,
                                                cause: `Inst_access_fault
                                                };
                    end
                    else begin
                      rg_stage1_flushed <= False;
                    end
                    //wr_replay_stage1_valid <= False;
                    wr_replay_stage1_io_response <= True;
                    rg_io_request_valid <= False;
                    rg_io_request_issued <= False;
                    `logLevel( icache, 1, $format("ICACHE: Response from IO: ", fshow(wr_mem_response)))
                end
                else begin
                    // send to LFB
                    //rg_fill_valid <= True; // don't need backpressure because of current controller design
                    //rg_fill_data <= wr_mem_response;
                    ifc_mhb.ma_fill_from_memory(True,wr_mem_response);
                    `logLevel( icache, 1, $format("ICACHE: Response from Mem: ", fshow(wr_mem_response)))
                end
            end
        endrule
        //
        //
        //rule rl_fill_from_memory;
        //    ifc_mhb.ma_fill_from_memory(rg_fill_valid,rg_fill_data);
        //    rg_fill_valid <= False;
        //endrule
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
                `logLevel( icache, 1, $format("ICACHE: LFB: Fill (release) set %d way %d data %h", set_index, way, block_data))
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
                `logLevel( icache, 1, $format("ICACHE: Response from PTW: ", fshow(in)))
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
            wr_flush <= core_req.flush;
            `logLevel( icache, 1, $format("ICACHE: Request from core: ", fshow(core_req)))
        endmethod
        //
        method ActionValue#(ICache_core_response) mav_core_response();
            ICache_core_response lv_resp;

            lv_resp <- ifc_crq.mav_crq_response();
            `logLevel( icache, 1, $format("ICACHE: Response to core: ", fshow(lv_resp)))
            return lv_resp;
        endmethod
        //
        method Action ma_csr_status(Bit#(2) prv, Bit#(`xlen) satp);
            ifc_itlb.ma_satp_from_csr(satp);
            ifc_itlb.ma_curr_priv(prv);
        endmethod

// Old requests pending and replay valid moved here
/* /////////////////////////////////////////////
                    // replay pending requests, if any
                    // (if "stage2 free" , "No tlb_miss pending", "No issued io request pending")
                    //else if(wr_preread_replay_stage1_valid && !wr_preread_io_issued && !wr_preread_tlb_miss && !wr_preread_stage2_next_cycle_stall) begin
                    else if(wr_preread_replay_stage1_valid && !wr_preread_io_issued && !wr_preread_tlb_miss) begin
                        let lv_core_req = wr_preread_replay_stage1_req_data; 
                        Bool lv_set_conflict =  False;  
                        Bool lv_is_io = isIO(wr_tlb_response.address, True);
                        //
                        if(wr_fb_release_valid && (wr_fb_release_index == lv_core_req.vaddr[`setbits+`wordoffset+`byteoffset-1:`wordoffset+`byteoffset])) begin
                            lv_set_conflict = True;
                            `logLevel( icache, 1, $format("ICACHE: Stage1: Replay: Set conflict for req_id %d, set %d", lv_core_req.req_id, wr_fb_release_index))
                        end
                        // 
                        if(lv_core_req.fence && ifc_mhb.mv_mshr_empty() && !wr_preread_stage2_valid) begin
                            // invalidate all cache entries
                            wr_icache_fence <= lv_core_req.fence;
                            wr_stage1_crq_data <= ICache_core_response{
                                                valid : lv_core_req.fence,
                                                req_id: lv_core_req.req_id,
                                                packet: '0,
                                                trap: False,
                                                cause: wr_tlb_response.cause
                                                };
                            wr_replay_stage1_valid <= False;
                            `logLevel( icache, 1, $format("ICACHE: Stage1: Replay: Fence."))
                        end
                        else if(lv_core_req.sfence && ifc_mhb.mv_mshr_empty() && !wr_preread_stage2_valid) begin
                            // invalidate TLB
                            wr_itlb_sfence <= lv_core_req.sfence;
                            wr_stage1_crq_data <= ICache_core_response{
                                                valid : lv_core_req.sfence,
                                                req_id: lv_core_req.req_id,
                                                packet: '0,
                                                trap: False,
                                                cause: wr_tlb_response.cause
                                                };
                            wr_replay_stage1_valid <= False;
                            `logLevel( icache, 1, $format("ICACHE: Stage1: Replay: Sfence."))
                        end
                        else begin
                            //
                            wr_lookup_arrays_valid <= lv_core_req.valid; // index into 4 arrays: status, repl, tag, data.
                            wr_lookup_vaddr <= lv_core_req.vaddr;
                            rg_lookup_ptag <= truncateLSB(wr_tlb_response.address);
                            wr_lookup_reqid <= lv_core_req.req_id;
                            //
                            if((wr_tlb_response.hit && !lv_is_io) && !lv_set_conflict && !ifc_mhb.mv_mshr_full ) begin
                                if(wr_preread_stage1_flushed) begin // if Ptwalk response has been stored in tlb for the flushed request, drop it.
                                    rg_stage1_flushed <= False;
                                    wr_replay_stage1_valid <= False;
                                    `logLevel( icache, 1, $format("ICACHE: Stage1: Replay: Dropping flushed request.", lv_core_req.req_id))
                                end
                                else begin
                                    wr_from_stage1_valid <= True;
                                    wr_replay_stage1_valid <= False;
                                    rg_set_conflict <= False;
                                    `logLevel( icache, 1, $format("ICACHE: Stage1: Replay: TLB hit for req_id %d, sending to Stage2.", lv_core_req.req_id))
                                end
                            end
                            else begin // had another "set conflict" or "tlb_miss" or "req is a fence/sfence/io and the cache is not empty"
                                wr_replay_stage1_valid <= True;
                                wr_replay_stage1_req_data <= lv_core_req;
                                if((wr_tlb_response.hit && lv_is_io)) begin
                                    rg_io_request_valid <= True;
                                    `logLevel( icache, 1, $format("ICACHE: Stage1: Replay: IO request, enqueueing.", lv_core_req.req_id))
                                end
                                if(!wr_tlb_response.hit) begin
                                    rg_tlb_miss <= True; // takes priority over set_conflict
                                    `logLevel( icache, 1, $format("ICACHE: Stage1: Replay: TLB miss for req_id %d.", lv_core_req.req_id))
                                end
                                else if(lv_set_conflict) begin
                                    rg_set_conflict <= True;
                                    `logLevel( icache, 1, $format("ICACHE: Stage1: Replay: Set conflict for req_id %d.", lv_core_req.req_id))
                                end
                            end
                        end
                    end  // replay valid and !io and !tlb_miss
                    else if(wr_preread_replay_stage1_valid && (wr_preread_tlb_miss || wr_preread_io_issued)) begin
                      // TODO: optimize
                      wr_replay_stage1_valid <= True;
                      wr_replay_stage1_req_data <= wr_preread_replay_stage1_req_data; 
                    end
                end
*/ /////////////////////////////////////////////

        //
    endmodule
endpackage
