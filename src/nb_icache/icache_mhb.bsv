package icache_mhb;
    // i-cache miss handling module (MSHR+Line fill buffer)
    `include "icache_parameters.bsv"
    import nb_icache_types ::*;
    import Vector ::*;
    //
    interface Ifc_icache_mhb;
        method Bool mv_mshr_empty();
        method Bool mv_mshr_full();
        method Bit#(TAdd#(1,TLog#(`mhb_size))) mv_mshr_count_free();
        method MHB_lookup_resp mv_mshr_lookup(Bool valid, Bit#(`paddr) address);
        method ActionValue#(Tuple4#(Bool,Bit#(TLog#(`numways)),Bit#(TSub#(`paddr,`offsetbits)),Bit#(`blocksize))) mv_fb_release();
        method ActionValue#(Tuple3#(Bool,Bit#(`reqid_size),Bit#(`wordsize))) mv_read_response(Bool valid_resp,Bit#(TLog#(`mhb_size)) mhb_index); 
        method Action ma_allocate_entry(Bool valid, Bool mshr_hit, Bit#(TAdd#(TLog#(`mhb_size),TLog#(`imshr_depth))) mshr_index, Bit#(`paddr) address,Bit#(`reqid_size) req_id,Bit#(TLog#(`numways)) replacement_way);
        method Action ma_fill_from_memory(Bool valid,Mem_response mem_resp);
        method Action ma_set_issued(Bool valid,Bit#(TLog#(`mhb_size)) mhb_index);
        method Action ma_flush(Bool flush);
    endinterface
    (*synthesize*)
    (*conflict_free="ma_flush, ma_allocate_entry"*)
    (*conflict_free="ma_fill_from_memory, ma_allocate_entry"*)
    (*conflict_free="ma_set_issued, ma_allocate_entry"*)
    (*conflict_free="mv_read_response, ma_allocate_entry"*)
    (*conflict_free="mv_fb_release, ma_allocate_entry"*)
    module mkicache_mhb(Ifc_icache_mhb);
        // MSHR Registers
        Vector#(`mhb_size,Vector#(`imshr_depth,Reg#(Bool))) rg_mshr_valid <- replicateM(replicateM(mkReg(False)));
        Vector#(`mhb_size,Vector#(`imshr_depth,Reg#(Bool))) rg_mshr_flushed <- replicateM(replicateM(mkReg(False)));
        Vector#(`mhb_size,Vector#(`imshr_depth,Reg#(Bit#(`reqid_size)))) rg_mshr_req_id <- replicateM(replicateM(mkReg(0)));
        Vector#(`mhb_size,Vector#(`imshr_depth,Reg#(Bit#(`offsetbits)))) rg_mshr_offset <- replicateM(replicateM(mkReg(0)));
        Vector#(`mhb_size,Reg#(Bool)) rg_mshr_issued <- replicateM(mkReg(False));
        Vector#(`mhb_size,Reg#(Bit#(TSub#(`paddr,`offsetbits)))) rg_mshr_block_address <- replicateM(mkReg(0));
        Vector#(`mhb_size,Reg#(Bit#(TLog#(`imshr_depth)))) rg_mshr_req_to_be_served <- replicateM(mkReg(0));
        Vector#(`mhb_size,Reg#(Bit#(TLog#(`numways)))) rg_mshr_replacement_way <- replicateM(mkReg(0));
        Reg#(Bit#(TLog#(`mhb_size))) rg_mhb_ptr <- mkReg(0); //points to next free location
        // LFB Registers
        Vector#(`mhb_size,Reg#(Bool)) rg_fb_valid <- replicateM(mkReg(False));
        Vector#(`mhb_size,Reg#(Bit#(`fb_depth))) rg_fb_filled <- replicateM(mkReg(0));
        Vector#(`mhb_size,Reg#(Bit#(`wordoffset))) rg_fb_word_to_be_filled <- replicateM(mkReg(0));
        Vector#(`mhb_size,Vector#(`fb_depth,Reg#(Bit#(`wordsize)))) rg_fb_data <- replicateM(replicateM(mkReg('0)));
        Reg#(Bit#(`mhb_size)) rg_lfb_release_ptr <- mkReg(0);
        // Wires
        Reg#(Bool) rg_mshr_full <- mkReg(False);
        Reg#(Bool) rg_mshr_empty <- mkReg(False);
        Reg#(Bit#(TAdd#(1,TLog#(`mhb_size)))) rg_mshr_free_count <- mkReg(0);
        // Rules
        rule rl_check_mshr_free;
            Bool lv_is_full = True;
            Bit#(TAdd#(1,TLog#(`mhb_size))) lv_count_free = '0;
            for(Integer i=0;i<`mhb_size;i=i+1) begin
                if(!rg_mshr_valid[i][0]) begin
                    lv_is_full = False;
                    lv_count_free = lv_count_free + 1;
                end
            end
            rg_mshr_free_count <= lv_count_free;
            rg_mshr_full <= lv_is_full;
            rg_mshr_empty <= (lv_count_free == `mhb_size);
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
        method MHB_lookup_resp mv_mshr_lookup(Bool valid, Bit#(`paddr) address);
            // Check if the entry for the given physical address exists already exits in MSHR 
            //// If exists
            ////// check if the requested word is already filled in LFB -> if True, return word
            ////// check if there is a free slot for a secondary request -> if True, return indices
            Bit#(TLog#(`mhb_size)) primary_index = 0;
            Bit#(TLog#(`imshr_depth)) secondary_index = 0;
            Bit#(`wordoffset) requested_word = address[`wordoffset+`byteoffset-1:`byteoffset];
            Bit#(TSub#(`paddr,`offsetbits)) block_addr = truncateLSB(address);
            MHB_lookup_resp resp = unpack(0);
            resp.valid = valid;
            if(valid) begin
                for(Integer i=0;i<`mhb_size;i=i+1) begin
                    // hit/miss in MSHR
                    if(rg_mshr_valid[i][0] && rg_mshr_block_address[i]==block_addr) begin
                        resp.hit_mhb = True;
                        primary_index = fromInteger(i);
                    end
                end
            end
            // check if more entries can be accepted for the same block address
            for(Integer j=1;j<`imshr_depth;j=j+1) begin
                if(!rg_mshr_valid[primary_index][j]) begin 
                    resp.free_secondary = valid;
                    secondary_index = fromInteger(j);
                end
            end
            //
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
        method Action ma_set_issued(Bool valid,Bit#(TLog#(`mhb_size)) mhb_index);
            if(valid) begin
                rg_mshr_issued[mhb_index] <= True;
            end
        endmethod
        //
        method Action ma_allocate_entry(Bool valid, Bool mshr_hit, Bit#(TAdd#(TLog#(`mhb_size),TLog#(`imshr_depth))) mshr_index, Bit#(`paddr) address,Bit#(`reqid_size) req_id,Bit#(TLog#(`numways)) replacement_way);
            if(valid) begin
                // Allocate a secondary MSHR entry, LFB entry exists
                if(mshr_hit) begin
                    Bit#(TLog#(`mhb_size)) lv_primary_index = truncateLSB(mshr_index);
                    Bit#(TLog#(`imshr_depth)) lv_secondary_index = truncate(mshr_index);
                    rg_mshr_valid[lv_primary_index][lv_secondary_index] <= valid;
                    rg_mshr_offset[lv_primary_index][lv_secondary_index] <= truncate(address);
                    rg_mshr_req_id[lv_primary_index][lv_secondary_index] <= req_id;
                    rg_mshr_flushed[lv_primary_index][lv_secondary_index] <= False;
                end
                // Allocate a new MSHR entry
                else begin 
                    //MSHR Entry
                    rg_mshr_issued[rg_mhb_ptr] <= False;
                    rg_mshr_block_address[rg_mhb_ptr] <= truncateLSB(address);
                    rg_mshr_replacement_way[rg_mhb_ptr] <= replacement_way;
                    rg_mshr_req_to_be_served[rg_mhb_ptr] <= 0;
                    rg_mshr_valid[rg_mhb_ptr][0] <= valid;
                    rg_mshr_offset[rg_mhb_ptr][0] <= truncate(address);
                    rg_mshr_req_id[rg_mhb_ptr][0] <= req_id;
                    rg_mshr_flushed[rg_mhb_ptr][0] <= False;
                    // LFB entry
                    rg_fb_valid[rg_mhb_ptr] <= valid;
                    rg_fb_filled[rg_mhb_ptr] <= '0;
                    rg_fb_word_to_be_filled[rg_mhb_ptr] <= address[`wordoffset+`byteoffset-1:`byteoffset]; 
                    for(Integer i=0;i<`fb_depth;i=i+1)
                        rg_fb_data[rg_mhb_ptr][i] <= unpack(0);
                    //
                    rg_mhb_ptr <= rg_mhb_ptr+1;
                end
            end
        endmethod
        //
        method Action ma_fill_from_memory(Bool valid,Mem_response mem_resp);
            Bit#(TLog#(`mhb_size)) mhb_index = mem_resp.mhb_id;
            Bit#(`wordoffset) lv_fb_word_to_be_filled = rg_fb_word_to_be_filled[mhb_index];
            if(valid) begin
                // Update LFB
                rg_fb_data[mhb_index][lv_fb_word_to_be_filled] <= mem_resp.data;
                rg_fb_filled[mhb_index][lv_fb_word_to_be_filled] <= 1;
                rg_fb_word_to_be_filled[mhb_index] <= lv_fb_word_to_be_filled + 1;  
            end
        endmethod
        //
        // NOTE (POSSIBLE OPTIMIZATION): Instead of servicing requests sequentially, can service many secondary entries in a single cycle
        method ActionValue#(Tuple3#(Bool,Bit#(`reqid_size),Bit#(`wordsize))) mv_read_response(Bool valid,Bit#(TLog#(`mhb_size)) mhb_index); 
            // read the request to be served corresponding to mhb_index
            Bit#(TLog#(`imshr_depth)) lv_mshr_req_to_be_served  = rg_mshr_req_to_be_served[mhb_index];
            Bit#(`reqid_size) lv_reqid = rg_mshr_req_id[mhb_index][lv_mshr_req_to_be_served];
            // read the corresponding mshr request
            Bool lv_flushed = rg_mshr_flushed[mhb_index][lv_mshr_req_to_be_served];
            Bit#(`wordoffset) lv_req_word = truncateLSB(rg_mshr_offset[mhb_index][lv_mshr_req_to_be_served]);
            Bit#(`byteoffset) lv_req_byteoffset = truncate(rg_mshr_offset[mhb_index][lv_mshr_req_to_be_served]);
            // read the corresponding fill buffer entry
            Vector#(`fb_depth,Bit#(`wordsize)) lv_fb_data = readVReg(rg_fb_data[mhb_index]);
            Bit#(`fb_depth) lv_fb_filled = rg_fb_filled[mhb_index];
            Bit#(`wordoffset) lv_fb_word_to_be_filled = rg_fb_word_to_be_filled[mhb_index];
            // see if the request is satisfied
            // if requested entry is not flushed
            // if request is for the first byte of the requested word, 
            // if request is for the last word, send the requested bytes appended with 0s
            // if requested byte is somewhere in the middle, send part of the requested word appended with the next word (if available/filled)
            Bool lv_req_satisfied = valid && !lv_flushed && 
                    (((lv_req_byteoffset == 0) && (lv_fb_filled[lv_req_word] == 1)) 
                        || ((lv_req_word == '1) && (lv_fb_filled[lv_req_word] == 1))   
                        || ((lv_fb_filled[lv_req_word] == 1) && (lv_fb_filled[lv_req_word+1] == 1))); 
            
            Bit#(TLog#(`wordsize)) lv_shift_amt = zeroExtend(lv_req_byteoffset) << 3;
            Bit#(`wordsize) lv_selected_word = lv_fb_data[lv_req_word];
            Bit#(`wordsize) lv_selected_word_next = (lv_req_word == '1) ? '0 : lv_fb_data[lv_req_word+1];
            Bit#(TMul#(2,`wordsize)) lv_selected_word_double = {lv_selected_word_next, lv_selected_word} >> lv_shift_amt;
            lv_selected_word = lv_selected_word_double[`wordsize-1:0];
            //
            rg_mshr_req_to_be_served[mhb_index] <= (lv_req_satisfied)?lv_mshr_req_to_be_served+1:lv_mshr_req_to_be_served;
            //
            return tuple3(lv_req_satisfied,lv_reqid,lv_selected_word);
        endmethod
        //
        //                         valid.   replacement_way,   block_address,                 , release_data
        method ActionValue#(Tuple4#(Bool,Bit#(TLog#(`numways)),Bit#(TSub#(`paddr,`offsetbits)),Bit#(`blocksize))) mv_fb_release();
            Bit#(`blocksize) lv_blockdata = '0;
            Bit#(TSub#(`paddr,`offsetbits)) lv_blockaddress = '0;
            Bool lv_releasing = False;
            Bit#(TLog#(`mhb_size)) lv_release_index = '0;
            Bit#(TLog#(`numways)) lv_replacement_way = 0;
            let lv_ptr = rg_lfb_release_ptr;
            if(rg_fb_valid[lv_ptr] && !rg_mshr_flushed[lv_ptr][0]) begin
                if(rg_fb_filled[lv_ptr]=='1) begin
                    lv_releasing = True;
                    lv_release_index = fromInteger(i);
                    lv_blockdata = pack(readVReg(rg_fb_data[lv_ptr]));
                    lv_blockaddress = rg_mshr_block_address[lv_ptr];
                    lv_replacement_way = rg_mshr_replacement_way[lv_ptr];
                end
            end
            // Invalidate entries
            if(lv_releasing) begin
                rg_fb_valid[lv_release_index] <= False;
                for(Integer j=0;j<`imshr_depth;j=j+1) begin
                    rg_mshr_valid[lv_release_index][j] <= False;
                end
            end
            else if(!rg_fb_valid[lv_ptr] || rg_mshr_flushed[lv_ptr][0] || rg_fb_filled[lv_ptr]== 0) begin
                rg_lfb_release_ptr <= rg_lfb_release_ptr + 1;
            end
            return tuple4(lv_releasing,lv_replacement_way,lv_blockaddress,lv_blockdata);
        endmethod
        //
        method Action ma_flush(Bool flush);
            // If the request is issued -> just set the flushed bit
            // else flush the entries
            if(flush) begin
                for(Integer i=0;i<`mhb_size;i=i+1) begin
                    for(Integer j=0;j<`imshr_depth;j=j+1) begin
                        if(rg_mshr_valid[i][j]) begin
                            if(rg_mshr_issued[i]) begin
                                rg_mshr_flushed[i][j] <= True;                                
                            end
                            else begin
                                rg_mshr_valid[i][j] <= False;
                            end
                        end
                    end
                end
            end
        endmethod
        //
    endmodule
endpackage