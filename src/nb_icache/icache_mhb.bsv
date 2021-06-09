package icache_mhb;
    // i-cache miss handling module (MSHR+Line fill buffer)
    `include "icache_parameters.bsv"
    import nb_icache_types ::*;
    import Vector ::*;
    //
    interface Ifc_icache_mhb;
        method Bool mv_mshr_full();
        method Bit#(TLog#(`mhb_size)) mv_mshr_count_free();
        method Tuple3#(Bool,Bool,Bit#(TAdd#(TLog#(`mhb_size),TLog#(`imshr_depth)))) mv_mshr_lookup(Bool valid, Bit#(TSub#(`paddr,`offsetbits)) block_addr);
        method Action ma_allocate_entry(Bool valid, Bool mshr_hit, Bit#(TAdd#(TLog#(`mhb_size),TLog#(`imshr_depth))) mshr_index, Bit#(TSub#(`paddr,`offsetbits)) block_addr,Bit#(`offsetbits) offset,Bit#(`reqid_size) req_id);
        method ActionValue#(Tuple3#(Bool,Bit#(TSub#(`paddr,`offsetbits)),Bit#(`blocksize))) mv_fb_release();
        method ActionValue#(Tuple3#(Bool,Bit#(`reqid_size),Bit#(`wordsize))) mv_read_response(Bool valid_resp,ICache_mem_readresp mem_resp); 
    endinterface
    (*synthesize*)
    module mkicache_mhb(Ifc_icache_mhb);
        // MSHR Registers
        Vector#(`mhb_size,Vector#(`imshr_depth,Reg#(Bool))) rg_mshr_valid <- replicateM(replicateM(mkReg(False)));
        Vector#(`mhb_size,Vector#(`imshr_depth,Reg#(Bool))) rg_mshr_flushed <- replicateM(replicateM(mkReg(False)));
        Vector#(`mhb_size,Vector#(`imshr_depth,Reg#(Bit#(`reqid_size)))) rg_mshr_req_id <- replicateM(replicateM(mkReg(0)));
        Vector#(`mhb_size,Vector#(`imshr_depth,Reg#(Bit#(`offsetbits)))) rg_mshr_offset <- replicateM(replicateM(mkReg(0)));
        Vector#(`mhb_size,Reg#(Bool)) rg_mshr_issued <- replicateM(mkReg(False));
        Vector#(`mhb_size,Reg#(Bit#(TSub#(`paddr,`offsetbits)))) rg_mshr_block_address <- replicateM(mkReg(0));
        Reg#(Bit#(TLog#(`mhb_size))) rg_mhb_ptr <- mkReg(0); //points to next free location
        // LFB Registers
        Vector#(`mhb_size,Reg#(Bool)) rg_fb_valid <- replicateM(mkReg(False));
        Vector#(`mhb_size,Reg#(Bit#(`fb_depth))) rg_fb_filled <- replicateM(mkReg(0));
        Vector#(`mhb_size,Reg#(Bit#(`wordoffset))) rg_fb_word_to_be_filled <- replicateM(mkReg(0));
        Vector#(`mhb_size,Vector#(`fb_depth,Reg#(Bit#(`wordsize)))) rg_fb_data <- replicateM(replicateM(mkReg('0)));
        // Wires
        Wire#(Bool) wr_mshr_full <- mkDWire(False);
        Wire#(Bit#(TLog#(`mhb_size))) wr_mshr_free_count <- mkDWire(0);
        // Rules
        rule rl_check_mshr_free;
            Bool lv_is_full = True;
            Bit#(TLog#(`mhb_size)) lv_count_free = '0;
            for(Integer i=0;i<`mhb_size;i=i+1) begin
                if(!rg_mshr_valid[i][0]) begin
                    lv_is_full = False;
                    lv_count_free = lv_count_free + 1;
                end
            end
            wr_mshr_free_count <= lv_count_free;
            wr_mshr_full <= lv_is_full;
        endrule
        //
        method Bool mv_mshr_full();
            return wr_mshr_full;
        endmethod
        //
        method Bit#(TLog#(`mhb_size)) mv_mshr_count_free();
            return wr_mshr_free_count;
        endmethod
        //
        method Tuple3#(Bool,Bool,Bit#(TAdd#(TLog#(`mhb_size),TLog#(`imshr_depth)))) mv_mshr_lookup(Bool valid, Bit#(TSub#(`paddr,`offsetbits)) block_addr);
            Bool hit = False;
            Bool if_free_secondary = False;
            Bit#(TLog#(`mhb_size)) hit_index = 0;
            Bit#(TLog#(`imshr_depth)) secondary_index = 0;

            if(valid) begin
                for(Integer i=0;i<`mhb_size;i=i+1) begin
                    // hit/miss in MSHR
                    if(rg_mshr_valid[i][0] && rg_mshr_block_address[i]==block_addr) begin
                        hit = True;
                        hit_index = fromInteger(i);
                    end
                    // check if more entries be accepted for the same block address
                    for(Integer j=1;j<`imshr_depth;j=j+1) begin
                        if(!rg_mshr_valid[i][j]) begin 
                            if_free_secondary = hit;
                            secondary_index = fromInteger(j);
                        end
                    end
                end
            end
            return tuple3(hit,if_free_secondary,{hit_index,secondary_index});
        endmethod
        //
        method Action ma_allocate_entry(Bool valid, Bool mshr_hit, Bit#(TAdd#(TLog#(`mhb_size),TLog#(`imshr_depth))) mshr_index, Bit#(TSub#(`paddr,`offsetbits)) block_addr,Bit#(`offsetbits) offset,Bit#(`reqid_size) req_id);
            if(valid) begin
                // Allocate a secondary entry, LFB entry exists
                if(mshr_hit) begin
                    Bit#(TLog#(`mhb_size)) lv_primary_index = truncateLSB(mshr_index);
                    Bit#(TLog#(`imshr_depth)) lv_secondary_index = truncate(mshr_index);
                    rg_mshr_valid[lv_primary_index][lv_secondary_index] <= valid;
                    rg_mshr_offset[lv_primary_index][lv_secondary_index] <= offset;
                    rg_mshr_req_id[lv_primary_index][lv_secondary_index] <= req_id;
                    rg_mshr_flushed[lv_primary_index][lv_secondary_index] <= False;
                end
                // Allocate a new entry
                else begin 
                    //MSHR Entry
                    rg_mshr_issued[rg_mhb_ptr] <= False;
                    rg_mshr_block_address[rg_mhb_ptr] <= block_addr;
                    rg_mshr_valid[rg_mhb_ptr][0] <= valid;
                    rg_mshr_offset[rg_mhb_ptr][0] <= offset;
                    rg_mshr_req_id[rg_mhb_ptr][0] <= req_id;
                    rg_mshr_flushed[rg_mhb_ptr][0] <= False;
                    // LFB entry
                    rg_fb_valid[rg_mhb_ptr] <= valid;
                    rg_fb_filled[rg_mhb_ptr] <= '0;
                    rg_fb_word_to_be_filled[rg_mhb_ptr] <= truncateLSB(offset); 
                    for(Integer i=0;i<`fb_depth;i=i+1)
                        rg_fb_data[rg_mhb_ptr][i] <= unpack(0);
                    //
                    rg_mhb_ptr <= rg_mhb_ptr+1;
                end
            end
        endmethod
        //
        method ActionValue#(Tuple3#(Bool,Bit#(`reqid_size),Bit#(`wordsize))) mv_read_response(Bool valid_resp,ICache_mem_readresp mem_resp); 
            Bool match_found = False;
            Bool lv_req_satisfied = False;
            Bit#(`wordoffset) lv_req_word = '0;
            Bit#(`byteoffset) lv_req_byteoffset = '0;
            Bit#(`wordoffset) lv_fb_word_to_be_filled = '0;
            Bit#(`fb_depth) lv_fb_filled = '0;
            Integer lv_match_primary_index = 0;
            Integer lv_match_secondary_index = 0;
            Vector#(`fb_depth,Bit#(`wordsize)) lv_fb_data = replicate(0);
            Bit#(TLog#(`wordsize)) lv_shift_amt = 0;
            Bit#(`wordsize) lv_selected_word = '0;
            Bit#(`wordsize) lv_selected_word_next = '0;
            Bit#(TMul#(2,`wordsize)) lv_selected_word_double = '0;
            for(Integer i=0; i<`mhb_size;i=i+1) begin
                for(Integer j=0;j<`imshr_depth;j=j+1) begin
                    // If the memory response is valid, find the valid entry with matching request id in MSHR
                    if(!match_found && valid_resp && rg_mshr_valid[i][j] && rg_mshr_issued[i] && rg_mshr_req_id[i][j] == mem_resp.req_id) begin
                        // read the corresponding mshr request
                        lv_req_word = truncateLSB(rg_mshr_offset[i][j]);
                        lv_req_byteoffset = truncate(rg_mshr_offset[i][j]);
                        // read the corresponding fill buffer entry
                        lv_fb_data = readVReg(rg_fb_data[i]);
                        lv_fb_filled = rg_fb_filled[i];
                        lv_fb_word_to_be_filled = rg_fb_word_to_be_filled[i];
                        // update fill buffer local state
                        lv_fb_filled[lv_fb_word_to_be_filled] =  1;
                        lv_fb_data[lv_fb_word_to_be_filled] = mem_resp.data;
                        // see if the received memory response satifies the request
                        // if request is for the first byte of the received word, send the received word
                        // if request is for the last word, send the requested bytes appended with 0s
                        // if requested byte is somewhere in the middle, send part of the received word appended with the next word (if available/filled)
                        lv_req_satisfied = valid_resp &&
                                (((lv_req_byteoffset == 0) && (lv_fb_filled[lv_req_word] == 1)) 
                                 || ((lv_req_word == '1) && (lv_fb_filled[lv_req_word] == 1))   
                                 || ((lv_fb_filled[lv_req_word] == 1) && (lv_fb_filled[lv_req_word+1] == 1))); 
                        
                        lv_shift_amt = zeroExtend(lv_req_byteoffset) << 3;
                        lv_selected_word = lv_fb_data[lv_req_word];
                        lv_selected_word_next = (lv_req_word == '1) ? '0 : lv_fb_data[lv_req_word+1];
                        lv_selected_word_double = {lv_selected_word_next, lv_selected_word} >> lv_shift_amt;
                        lv_selected_word = lv_selected_word_double[`wordsize-1:0];
                        match_found = True;
                        lv_match_primary_index = i;                      
                        lv_match_secondary_index = j;                      
                    end
                end
            end
            if(valid_resp) begin
                // Update LFB
                rg_fb_data[lv_match_primary_index][lv_fb_word_to_be_filled] <= mem_resp.data;
                rg_fb_filled[lv_match_primary_index][lv_fb_word_to_be_filled] <= 1;
                rg_fb_word_to_be_filled[lv_match_primary_index] <= lv_fb_word_to_be_filled + 1;  
            end
            //
            return tuple3(lv_req_satisfied,rg_mshr_req_id[lv_match_primary_index][lv_match_secondary_index],lv_selected_word);
        endmethod
        //
        method ActionValue#(Tuple3#(Bool,Bit#(TSub#(`paddr,`offsetbits)),Bit#(`blocksize))) mv_fb_release();
            Bit#(`blocksize) lv_blockdata = '0;
            Bit#(TSub#(`paddr,`offsetbits)) lv_blockaddress = '0;
            Bool lv_releasing = False;
            Bit#(TLog#(`mhb_size)) lv_release_index = '0;
            for(Integer i=0;i<`mhb_size;i=i+1) begin
                if(!lv_releasing && rg_fb_valid[i]) begin
                    if(rg_fb_filled[i]=='1) begin
                        lv_releasing = True;
                        lv_release_index = fromInteger(i);
                        lv_blockdata = pack(readVReg(rg_fb_data[i]));
                        lv_blockaddress = rg_mshr_block_address[i];
                    end
                end
            end
            // Invalidate entries
            if(lv_releasing) begin
                rg_fb_valid[lv_release_index] <= False;
                for(Integer j=0;j<`imshr_depth;j=j+1) begin
                    rg_mshr_valid[lv_release_index][j] <= False;
                end
            end
            return tuple3(lv_releasing,lv_blockaddress,lv_blockdata);
        endmethod
    endmodule
endpackage