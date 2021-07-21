package icache_mhb;
    // i-cache miss handling module (MSHR+Line fill buffer)
    `include "icache_parameters.bsv"
    `include "Logger.bsv"
    import nb_icache_types ::*;
    import Vector ::*;
    //
    interface Ifc_icache_mhb;
        method Bool mv_mshr_empty();
        method Bool mv_mshr_full();
        method Bit#(TAdd#(1,TLog#(`mhb_size))) mv_mshr_count_free();
        method MHB_lookup_resp mv_mshr_lookup(Bool valid, Bit#(`paddr) address);
        method Mem_request  mv_fill_request();
        method ActionValue#(Tuple4#(Bool,Bit#(TLog#(`numways)),Bit#(TSub#(`paddr,`offsetbits)),Bit#(`blocksize))) mv_fb_release();
        method ActionValue#(Tuple3#(Bool,Bit#(`reqid_width),Bit#(`wordsize))) mv_miss_response(); 
        method Action ma_allocate_entry(Bool valid, Bool mshr_hit, Bit#(TAdd#(TLog#(`mhb_size),TLog#(`imshr_depth))) mshr_index, Bit#(`paddr) address,Bit#(`reqid_width) req_id,Bit#(TLog#(`numways)) replacement_way);
        method Action ma_fill_from_memory(Bool valid,Mem_response mem_resp);
        method Action ma_set_issued(Bool valid);
        method Action ma_flush(Bool flush);
    endinterface
    (*synthesize*)
    (*conflict_free="ma_flush, ma_allocate_entry"*)
    (*conflict_free="ma_set_issued, ma_allocate_entry"*)
    (*conflict_free="ma_fill_from_memory, ma_allocate_entry"*)
    (*conflict_free="mv_miss_response, ma_allocate_entry"*)
    (*conflict_free="mv_fb_release, ma_allocate_entry"*)
    (*conflict_free="rl_increment_fb_request_ptr, ma_allocate_entry"*)
    (*conflict_free="rl_check_all_served, ma_allocate_entry"*)
    (*conflict_free="rl_set_valid_allocate_entry, rl_set_valid_request_satisfied"*)
    (*conflict_free="rl_set_valid_allocate_entry, rl_set_valid_lfb_release"*)
    (*conflict_free="ma_flush, rl_set_valid_lfb_release"*)
    (*conflict_free="rl_set_valid_allocate_entry, ma_flush"*)
    module mkicache_mhb(Ifc_icache_mhb);
        // MSHR Registers
        Vector#(`mhb_size,Vector#(`imshr_depth,Reg#(Bool))) rg_mshr_valid <- replicateM(replicateM(mkReg(False)));
        Vector#(`mhb_size,Vector#(`imshr_depth,Reg#(Bit#(`reqid_width)))) rg_mshr_req_id <- replicateM(replicateM(mkReg(0)));
        Vector#(`mhb_size,Vector#(`imshr_depth,Reg#(Bit#(`offsetbits)))) rg_mshr_offset <- replicateM(replicateM(mkReg(0)));
        Vector#(`mhb_size,Reg#(Bit#(TLog#(`imshr_depth)))) rg_mshr_req_to_be_served <- replicateM(mkReg(0));
        Vector#(`mhb_size,Reg#(Bit#(TLog#(`numways)))) rg_mshr_replacement_way <- replicateM(mkReg(0));
        Vector#(`mhb_size,Reg#(Bool)) rg_mshr_all_served <- replicateM(mkReg(False));
        
        // Pointers 
        Reg#(Bit#(TLog#(`mhb_size))) rg_mhb_free_entry_ptr <- mkReg(0); //points to next free location
        Reg#(Bit#(TLog#(`mhb_size))) rg_serve_mshr_entry_ptr <- mkReg(0); // points to the request to be served to the CRQ
        Reg#(Bit#(TLog#(`mhb_size))) rg_fill_request_entry_ptr <- mkReg(0); // points to the entry that has to send fill request to Memory
        Reg#(Bit#(TLog#(`mhb_size))) rg_fb_release_ptr <- mkReg(0); // points to the entry to be released to Cache

        // LFB Registers
        Vector#(`mhb_size,Reg#(Bool)) rg_fb_valid <- replicateM(mkReg(False));
        Vector#(`mhb_size,Reg#(Bool)) rg_fb_issued <- replicateM(mkReg(False));
        Vector#(`mhb_size,Reg#(Bool)) rg_fb_flushed <- replicateM(mkReg(False));
        Vector#(`mhb_size,Reg#(Bit#(TSub#(`paddr,`offsetbits)))) rg_fb_block_address <- replicateM(mkReg(0));
        Vector#(`mhb_size,Reg#(Bit#(`fb_depth))) rg_fb_filled <- replicateM(mkReg(0));
        Vector#(`mhb_size,Reg#(Bit#(`wordoffset))) rg_fb_word_to_be_filled <- replicateM(mkReg(0));
        Vector#(`mhb_size,Vector#(`fb_depth,Reg#(Bit#(`wordsize)))) rg_fb_data <- replicateM(replicateM(mkReg('0)));
        
        // Counters
        Reg#(Bool) rg_mshr_full <- mkReg(False);
        Reg#(Bool) rg_mshr_empty <- mkReg(False);
        Reg#(Bit#(TAdd#(1,TLog#(`mhb_size)))) rg_mshr_free_count <- mkReg(0);
        
        // Wires
        Wire#(Bool) wr_flush <- mkDWire(False);
        Vector#(`mhb_size,Wire#(Bool)) wr_fb_valid <- replicateM(mkDWire(False));
        Vector#(`mhb_size,Wire#(Bool)) wr_fb_flushed <- replicateM(mkDWire(False));
        Vector#(`mhb_size,Wire#(Bool)) wr_fb_issued <- replicateM(mkDWire(False));
        Vector#(`mhb_size,Vector#(`imshr_depth,Wire#(Bool))) wr_mshr_valid <- replicateM(replicateM(mkDWire(False))); // read corresponding register in the beginning of the cycle
        Vector#(`mhb_size,Wire#(Bit#(TLog#(`imshr_depth)))) wr_mshr_req_to_be_served <- replicateM(mkDWire(0)); // read corresponding register in the beginning of the cycle
        Wire#(Bool) wr_new_entry_serve_conflict <- mkDWire(False); // if a new entry arrives to same index as the one being served
        //
        Wire#(Bool) wr_req_satisfied <- mkDWire(False); // when serving miss requests to CRQ
        Wire#(Bit#(TLog#(`mhb_size))) wr_satisfied_req_primary_idx <- mkDWire(0);
        Wire#(Bit#(TLog#(`imshr_depth))) wr_satisfied_req_secondary_idx <- mkDWire(0);
        //
        Wire#(Bool) wr_allocate_entry <- mkDWire(False);
        Wire#(Bit#(TLog#(`mhb_size))) wr_allocate_entry_primary_idx <- mkDWire(0);
        Wire#(Bit#(TLog#(`imshr_depth))) wr_allocate_entry_secondary_idx <- mkDWire(0);
        //
        Wire#(Bool) wr_releasing <- mkDWire(False); // releasing block from LFB to cache after all requests are served/invalid
        Wire#(Bit#(TLog#(`mhb_size))) wr_releasing_primary_index <- mkDWire(0);
        //
        Wire#(Bool) wr_set_issued <- mkDWire(False);
        Wire#(Bool) wr_increment_free_entry_ptr <- mkDWire(False);
        Wire#(Bit#(TLog#(`mhb_size))) wr_mhb_free_entry_ptr <- mkDWire(0);
        //
        // Rules
        //
        //
        rule rl_display_mhb_array;
            for(Integer i=0;i<`mhb_size;i=i+1) begin
                Bit#(`paddr) lv_paddr = zeroExtend(rg_fb_block_address[i]) << `offsetbits;
                `logLevel( icache, 1, $format("ICACHE: MHB: LFB[%2d]: Status: valid %b flushed %b issued %b all_served %b serve_next %d paddr %h filled %b word_next %d data[3] %h data[2] %h data[1] %h data[0] %h", i, rg_fb_valid[i], rg_fb_flushed[i], rg_fb_issued[i], rg_mshr_all_served[i], rg_mshr_req_to_be_served[i], lv_paddr, rg_fb_filled[i], rg_fb_word_to_be_filled[i], rg_fb_data[i][3], rg_fb_data[i][2], rg_fb_data[i][1], rg_fb_data[i][0]))
                `logLevel( icache, 1, $format("\tICACHE: MHB: MSHR[%2d]: Status: val %b req %d ofs %d # val %b req %d ofs %d # val %b req %d ofs %d # val %b req %d ofs %d", i, rg_mshr_valid[i][0], rg_mshr_req_id[i][0], rg_mshr_offset[i][0], rg_mshr_valid[i][1], rg_mshr_req_id[i][1], rg_mshr_offset[i][1], rg_mshr_valid[i][2], rg_mshr_req_id[i][2], rg_mshr_offset[i][2], rg_mshr_valid[i][3], rg_mshr_req_id[i][3], rg_mshr_offset[i][3]))
            end
        endrule
        //
        rule rl_display_mhb_pointers;
            Bit#(`offsetbits) lv_offset = '0;
            Bit#(`paddr) lv_paddr = '0;
            lv_offset = zeroExtend(rg_fb_word_to_be_filled[rg_fill_request_entry_ptr]) << `byteoffset;
            lv_paddr = {rg_fb_block_address[rg_fill_request_entry_ptr],lv_offset};

            `logLevel( icache, 1, $format("ICACHE: MHB: rg_mhb_free_entry_ptr %d rg_serve_mshr_entry_ptr %d rg_fill_request_entry_ptr %d rg_fb_release_ptr", rg_mhb_free_entry_ptr, rg_serve_mshr_entry_ptr, rg_fill_request_entry_ptr, rg_fb_release_ptr))
            `logLevel( icache, 1, $format("ICACHE: MHB: fill_req laddr %h offset %d paddr %h", rg_fb_block_address[rg_fill_request_entry_ptr], lv_offset, lv_paddr))
        endrule
        //
        rule rl_handle_flush;
          if (wr_flush) begin
              for(Integer i=0;i<`mhb_size;i=i+1) begin
                  for(Integer j=0;j<`imshr_depth;j=j+1) begin
                      rg_mshr_valid[i][j] <= False;
                  end
              end
              //
              for(Integer i=0;i<`mhb_size;i=i+1) begin
                  if(!wr_fb_issued[i]) begin
                      rg_fb_valid[i] <= False;
                  end
                  else begin
                      rg_fb_flushed[i] <= True;
                  end
              end
          end
        endrule
        //
        rule rl_read_registers_into_wires;
            for(Integer i=0;i<`mhb_size;i=i+1) begin
                wr_fb_valid[i] <= rg_fb_valid[i];
                wr_fb_flushed[i] <= rg_fb_flushed[i];
                wr_fb_issued[i] <= rg_fb_issued[i];
                wr_mshr_req_to_be_served[i] <= rg_mshr_req_to_be_served[i];
                for(Integer j=0;j<`imshr_depth;j=j+1) begin
                    wr_mshr_valid[i][j] <= rg_mshr_valid[i][j];
                end
            end
            wr_mhb_free_entry_ptr <= rg_mhb_free_entry_ptr;
        endrule
        //
        rule rl_mhb_counters;
            Bool lv_is_full = True;
            Bit#(TAdd#(1,TLog#(`mhb_size))) lv_count_free = '0;
            if(wr_flush) begin
                for(Integer i=0;i<`mhb_size;i=i+1) begin
                    if(!wr_fb_valid[i] || (wr_fb_valid[i] && !wr_fb_issued[i])) begin // flush will invalidate entries which haven't yet been issued to memory
                        lv_is_full = False;
                        lv_count_free = lv_count_free + 1;
                    end
                end
            end
            else begin
                for(Integer i=0;i<`mhb_size;i=i+1) begin
                    if(!wr_fb_valid[i]) begin
                        lv_is_full = False;
                        lv_count_free = lv_count_free + 1;
                    end
                end
            end 
            rg_mshr_free_count <= lv_count_free;
            rg_mshr_full <= lv_is_full;
            rg_mshr_empty <= (lv_count_free == `mhb_size);
        endrule
        //
        rule rl_set_valid_allocate_entry(!wr_flush);
            if(wr_allocate_entry) begin
                rg_mshr_valid[wr_allocate_entry_primary_idx][wr_allocate_entry_secondary_idx] <= True;
                rg_fb_valid[wr_allocate_entry_primary_idx] <= True;
            end
        endrule
        //
        rule rl_set_valid_request_satisfied(!wr_flush);
            if(wr_req_satisfied) begin
                rg_mshr_valid[wr_satisfied_req_primary_idx][wr_satisfied_req_secondary_idx] <= False;
            end
        endrule
        //
        rule rl_set_valid_lfb_release;
            if(wr_releasing) begin
                rg_fb_valid[wr_releasing_primary_index] <= False;
            end
        endrule
        //
        rule rl_increment_fb_request_ptr;
            if(wr_set_issued) begin
                rg_fb_issued[rg_fill_request_entry_ptr] <= wr_set_issued;
                rg_fill_request_entry_ptr <= rg_fill_request_entry_ptr + 1;
            end
            else if(!wr_fb_valid[rg_fill_request_entry_ptr]) begin
                rg_fill_request_entry_ptr <= rg_fill_request_entry_ptr + 1;
            end
        endrule
        //
        rule rl_increment_mhb_free_entry_ptr;
            Bit#(TLog#(`mhb_size)) lv_free_index = rg_mhb_free_entry_ptr;
            for(Integer i=0;i<`mhb_size;i=i+1) begin
                if(wr_increment_free_entry_ptr && !wr_fb_valid[i] && (rg_mhb_free_entry_ptr != fromInteger(i))) begin
                    lv_free_index = fromInteger(i);
                end
            end
            rg_mhb_free_entry_ptr <= lv_free_index;
        endrule
        //
        rule rl_check_all_served;

            Bit#(TLog#(`mhb_size)) lv_mhb_index = rg_serve_mshr_entry_ptr;
            Bit#(TLog#(`imshr_depth)) lv_mshr_req_to_be_served  = wr_mshr_req_to_be_served[lv_mhb_index];
            Bit#(TAdd#(1,TLog#(`imshr_depth))) lv_mshr_pending_count = 0;
            Bool lv_all_served = False;

            for(Integer i=0;i<`imshr_depth;i=i+1) begin
                if(wr_mshr_valid[lv_mhb_index][i] && !wr_flush) begin // flush will invalidate all mshr entries
                    lv_mshr_pending_count = lv_mshr_pending_count + 1;
                end
            end
            //
            if(!wr_new_entry_serve_conflict) begin  // if there is no new entry arriving into the same mhb_index
                // NOTE: turning off 2nd condition below for the current implementation: next serve ptr moves sequentially
                //       and wr_req_satisfied can be 1 on an earlier invalid entry while a later valid entry is still pending
                //lv_all_served = (lv_mshr_pending_count==0 || (lv_mshr_pending_count == 1) && wr_req_satisfied);
                lv_all_served = (lv_mshr_pending_count==0);
                rg_mshr_all_served[lv_mhb_index] <= lv_all_served;
                //
                rg_serve_mshr_entry_ptr <= (lv_all_served)?lv_mhb_index+1:lv_mhb_index;
                //
                rg_mshr_req_to_be_served[lv_mhb_index] <= (wr_req_satisfied)?lv_mshr_req_to_be_served+1:lv_mshr_req_to_be_served;  // rg_serve_mshr pointer (miss response pointer) can increment further with enhancements
            end
            `logLevel( icache, 1, $format("ICACHE: MHB: rl_check_all_served: mhb_index %h serve_next %d pending %d serve_conflict %b req_sat %b # all_served %b", lv_mhb_index, lv_mshr_req_to_be_served, lv_mshr_pending_count, wr_new_entry_serve_conflict, wr_req_satisfied, lv_all_served))
        endrule
        //
        method Bool mv_mshr_empty();
            return rg_mshr_empty;
        endmethod
        //
        method Bool mv_mshr_full();
            return rg_mshr_full;
        endmethod
        //
        method Bit#(TAdd#(1,TLog#(`mhb_size))) mv_mshr_count_free();
            return rg_mshr_free_count;
        endmethod
        //
        // Check if the entry for the given physical address already exists in MSHR 
        // If exists
        // check if there is a free slot for a secondary request -> if True, return indices
        // check if the requested word is already filled in LFB -> if True, return word
        method MHB_lookup_resp mv_mshr_lookup(Bool valid, Bit#(`paddr) address);
            //
            Bit#(TLog#(`mhb_size)) primary_index = 0;
            Bit#(TLog#(`imshr_depth)) secondary_index = 0;
            Bit#(`wordoffset) requested_word = address[`wordoffset+`byteoffset-1:`byteoffset];
            Bit#(TSub#(`paddr,`offsetbits)) block_addr = truncateLSB(address);
            MHB_lookup_resp resp = unpack(0);
            resp.valid = valid;
            //
            if(valid) begin
                for(Integer i=0;i<`mhb_size;i=i+1) begin
                    // hit/miss in MSHR
                    if(rg_fb_valid[i] && rg_fb_block_address[i]==block_addr) begin
                        resp.hit_mhb = True;
                        primary_index = fromInteger(i);
                    end
                end
            end
            // check if more entries can be accepted for the same block address
            for(Integer j=1;j<`imshr_depth;j=j+1) begin
                if(!wr_mshr_valid[primary_index][j]) begin 
                    resp.free_secondary = valid;
                    secondary_index = fromInteger(j);
                end
            end

            resp.mhb_index = {primary_index,secondary_index};

            // check if the requested word is filled in LFB
            if(rg_fb_valid[primary_index] && rg_fb_filled[primary_index][requested_word]==1'b1) begin
                //
                Bit#(`byteoffset) lv_req_byteoffset = truncate(address);
                // read the corresponding fill buffer entry
                Vector#(`fb_depth,Bit#(`wordsize)) lv_fb_data = readVReg(rg_fb_data[primary_index]);
                Bit#(`fb_depth) lv_fb_filled = rg_fb_filled[primary_index];
                Bit#(`wordoffset) lv_fb_word_to_be_filled = rg_fb_word_to_be_filled[primary_index];
                // see if the data already exists for the address in LFB
                // if request is for the first byte of the requested word, send the requested word
                // if request is for the last word, send the requested bytes appended with 0s
                // if requested byte is somewhere in the middle, send part of the requested word appended with the next word (if available/filled)
                resp.fb_valid = valid &&
                        (((lv_req_byteoffset == 0) && (lv_fb_filled[requested_word] == 1)) 
                            || ((requested_word == '1) && (lv_fb_filled[requested_word] == 1))   
                            || ((lv_fb_filled[requested_word] == 1) && (lv_fb_filled[requested_word+1] == 1))); 
                
                Bit#(TLog#(`wordsize)) lv_shift_amt = zeroExtend(lv_req_byteoffset) << 3;
                Bit#(`wordsize) lv_selected_word = lv_fb_data[requested_word];
                Bit#(`wordsize) lv_selected_word_next = (requested_word == '1) ? '0 : lv_fb_data[requested_word+1];
                Bit#(TMul#(2,`wordsize)) lv_selected_word_double = {lv_selected_word_next, lv_selected_word} >> lv_shift_amt;
                resp.fb_data = lv_selected_word_double[`wordsize-1:0];
            end
            //
            return resp;
        endmethod
        //
        method Action ma_allocate_entry(Bool valid, Bool mshr_hit, Bit#(TAdd#(TLog#(`mhb_size),TLog#(`imshr_depth))) mshr_index, Bit#(`paddr) address,Bit#(`reqid_width) req_id,Bit#(TLog#(`numways)) replacement_way);
            // (mshr and fb valid bits are set separately in a rule to avoid conflicts)

            if(valid && !wr_flush) begin 
                wr_allocate_entry <= valid;
                if(mshr_hit) begin // Allocate a secondary MSHR entry, LFB entry exists 
                    Bit#(TLog#(`mhb_size)) lv_primary_index = truncateLSB(mshr_index);
                    Bit#(TLog#(`imshr_depth)) lv_secondary_index = truncate(mshr_index);
                    rg_mshr_offset[lv_primary_index][lv_secondary_index] <= truncate(address);
                    rg_mshr_req_id[lv_primary_index][lv_secondary_index] <= req_id;

                    // If the new request arrives before the block has been released and after all the requests for the index were already served or are being served
                    // then, reset "all_served" and "req_to_be_served" 
                    // 
                    if(lv_primary_index == rg_serve_mshr_entry_ptr) begin
                        wr_new_entry_serve_conflict <= True;
                        rg_mshr_all_served[lv_primary_index] <= False;
                        rg_mshr_req_to_be_served[lv_primary_index] <= (rg_mshr_all_served[lv_primary_index])?lv_secondary_index:
                                                                                    ((wr_req_satisfied)?wr_mshr_req_to_be_served[lv_primary_index]+1:wr_mshr_req_to_be_served[lv_primary_index]);
                    end

                    // if a secondary request arrives after the LFB has been marked "flushed", reset the flushed bit (response required for new request)
                    rg_fb_flushed[lv_primary_index] <= False;

                    wr_allocate_entry_primary_idx <= lv_primary_index;
                    wr_allocate_entry_secondary_idx <= lv_secondary_index;
                end

                else begin  // Allocate a new MSHR entry
                    //MSHR Entry
                    rg_mshr_replacement_way[wr_mhb_free_entry_ptr] <= replacement_way;
                    rg_mshr_req_to_be_served[wr_mhb_free_entry_ptr] <= 0;
                    rg_mshr_all_served[wr_mhb_free_entry_ptr] <= False;
                    rg_mshr_offset[wr_mhb_free_entry_ptr][0] <= truncate(address);
                    rg_mshr_req_id[wr_mhb_free_entry_ptr][0] <= req_id;
                    // LFB entry
                    rg_fb_issued[wr_mhb_free_entry_ptr] <= False;
                    rg_fb_flushed[wr_mhb_free_entry_ptr] <= False;
                    rg_fb_block_address[wr_mhb_free_entry_ptr] <= truncateLSB(address);
                    rg_fb_filled[wr_mhb_free_entry_ptr] <= '0;
                    rg_fb_word_to_be_filled[wr_mhb_free_entry_ptr] <= address[`wordoffset+`byteoffset-1:`byteoffset]; 
                    for(Integer i=0;i<`fb_depth;i=i+1)
                        rg_fb_data[wr_mhb_free_entry_ptr][i] <= unpack(0);
                    //
                    wr_allocate_entry_primary_idx <= wr_mhb_free_entry_ptr;
                    wr_allocate_entry_secondary_idx <= 0;
                    //
                    wr_increment_free_entry_ptr <= True;
                end
            end
        endmethod
        //
        method Action ma_fill_from_memory(Bool valid,Mem_response mem_resp);
            Bit#(TLog#(`mhb_size)) mhb_index = mem_resp.mhb_id;
            Bit#(`wordoffset) lv_fb_word_to_be_filled = rg_fb_word_to_be_filled[mhb_index];
            if(valid && mem_resp.valid) begin
                // Update LFB
                rg_fb_data[mhb_index][lv_fb_word_to_be_filled] <= mem_resp.data;
                rg_fb_filled[mhb_index][lv_fb_word_to_be_filled] <= 1;
                rg_fb_word_to_be_filled[mhb_index] <= lv_fb_word_to_be_filled + 1;  
            end
        endmethod
        //
        // NOTE (POSSIBLE OPTIMIZATION): Instead of servicing requests sequentially, we can try to service all secondary entries in a single cycle
        method ActionValue#(Tuple3#(Bool,Bit#(`reqid_width),Bit#(`wordsize))) mv_miss_response(); 
            // read the request to be served for the mhb entry
            Bit#(TLog#(`mhb_size)) lv_primary_index = rg_serve_mshr_entry_ptr;
            Bit#(TLog#(`imshr_depth)) lv_mshr_req_to_be_served  = wr_mshr_req_to_be_served[lv_primary_index];
            Bit#(`reqid_width) lv_reqid = rg_mshr_req_id[lv_primary_index][lv_mshr_req_to_be_served];
            
            Bool lv_entry_valid = wr_mshr_valid[lv_primary_index][lv_mshr_req_to_be_served]; 
            Bool lv_flushed = rg_fb_flushed[lv_primary_index];
            Bit#(`wordoffset) lv_req_word = truncateLSB(rg_mshr_offset[lv_primary_index][lv_mshr_req_to_be_served]);
            Bit#(`byteoffset) lv_req_byteoffset = truncate(rg_mshr_offset[lv_primary_index][lv_mshr_req_to_be_served]);
            
            // read the corresponding fill buffer entry
            Vector#(`fb_depth,Bit#(`wordsize)) lv_fb_data = readVReg(rg_fb_data[lv_primary_index]);
            Bit#(`fb_depth) lv_fb_filled = rg_fb_filled[lv_primary_index];

            // see if the request is satisfied
            // if requested entry is not flushed
            // if request is for the first byte of the requested word, 
            // if request is for the last word, send the requested bytes appended with 0s
            // if requested byte is somewhere in the middle, send part of the requested word appended with the next word (if available/filled)
            Bool lv_req_satisfied = lv_entry_valid && !lv_flushed && 
                    (((lv_req_byteoffset == 0) && (lv_fb_filled[lv_req_word] == 1)) 
                        || ((lv_req_word == '1) && (lv_fb_filled[lv_req_word] == 1))   
                        || ((lv_fb_filled[lv_req_word] == 1) && (lv_fb_filled[lv_req_word+1] == 1))); 
            
            Bit#(TLog#(`wordsize)) lv_shift_amt = zeroExtend(lv_req_byteoffset) << 3;
            Bit#(`wordsize) lv_selected_word = lv_fb_data[lv_req_word];
            Bit#(`wordsize) lv_selected_word_next = (lv_req_word == '1) ? '0 : lv_fb_data[lv_req_word+1];
            Bit#(TMul#(2,`wordsize)) lv_selected_word_double = {lv_selected_word_next, lv_selected_word} >> lv_shift_amt;
            lv_selected_word = lv_selected_word_double[`wordsize-1:0];
            //
            wr_req_satisfied <= (lv_req_satisfied || !lv_entry_valid);
            wr_satisfied_req_primary_idx <= lv_primary_index;
            wr_satisfied_req_secondary_idx <= lv_mshr_req_to_be_served;
            //
            return tuple3(lv_req_satisfied,lv_reqid,lv_selected_word);
        endmethod
        //
        method Mem_request mv_fill_request();
            Mem_request mem_req = unpack(0);
            Bit#(`offsetbits) lv_offset = '0;
            Bit#(`paddr) lv_paddr = '0;

            // valid, not issued and no flush
            if(wr_fb_valid[rg_fill_request_entry_ptr] && !wr_fb_issued[rg_fill_request_entry_ptr] && !wr_flush) begin
                lv_offset = zeroExtend(rg_fb_word_to_be_filled[rg_fill_request_entry_ptr]) << `byteoffset;
                lv_paddr = {rg_fb_block_address[rg_fill_request_entry_ptr],lv_offset};
                mem_req = Mem_request{
                            valid: True,
                            paddr: lv_paddr,
                            mhb_id: rg_fill_request_entry_ptr,
                            burst_len: fromInteger(`wordsperblock/valueOf(TDiv#(`ibuswidth,`wordsize))-1),
                            burst_size: fromInteger(valueOf(TLog#(TDiv#(`ibuswidth,8)))),
                            io: False
                        };                
            end
            return mem_req;
        endmethod
        //                         valid,   replacement_way   ,block_address,                 ,release_data
        method ActionValue#(Tuple4#(Bool,Bit#(TLog#(`numways)),Bit#(TSub#(`paddr,`offsetbits)),Bit#(`blocksize))) mv_fb_release();
            Bit#(`blocksize) lv_blockdata = '0;
            Bit#(TSub#(`paddr,`offsetbits)) lv_blockaddress = '0;
            Bool lv_releasing = False;
            Bit#(TLog#(`mhb_size)) lv_release_index = '0;
            Bit#(TLog#(`numways)) lv_replacement_way = 0;
            //
            let lv_ptr = rg_fb_release_ptr;
            if(rg_fb_valid[lv_ptr] && (rg_fb_filled[lv_ptr]=='1) && rg_mshr_all_served[lv_ptr]) begin
                lv_releasing = True;
                lv_release_index = lv_ptr;
                lv_blockdata = pack(readVReg(rg_fb_data[lv_ptr]));
                lv_blockaddress = rg_fb_block_address[lv_ptr];
                lv_replacement_way = rg_mshr_replacement_way[lv_ptr];
            end
            //
            if(lv_releasing || !rg_fb_valid[lv_ptr] || rg_fb_filled[lv_ptr]==0 || (rg_fb_release_ptr != rg_fill_request_entry_ptr)) begin
                rg_fb_release_ptr <= rg_fb_release_ptr + 1;
            end
            //
            wr_releasing <= lv_releasing;
            wr_releasing_primary_index <= lv_release_index;
            //
            return tuple4(lv_releasing,lv_replacement_way,lv_blockaddress,lv_blockdata);
        endmethod
        //
        method Action ma_set_issued(Bool valid);
            wr_set_issued <= valid;
        endmethod
        //
        method Action ma_flush(Bool flush);
            wr_flush <= flush;
        endmethod
        //
    endmodule
endpackage
