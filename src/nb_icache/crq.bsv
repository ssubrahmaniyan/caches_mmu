package crq;
    // Implements Core response Queue:  
    // A structure that has 2^reqid_width entries and keeps track of requests and 
    // fetched data in order so that responses can be sent to the core in order.
    //
    import icache_types     ::*;
    `include "icache_parameters.bsv"
    //
    interface Ifc_crq;
        method ma_icache_response(Vector#(`crq_input_size, ICache_core_response)  in);
        method ma_flush(Bool flush);
        method ICache_core_response mv_crq_response();
    endinterface
    module mk_crq(Ifc_crq);
        // Registers
        Vector#(`crq_size,Reg#(Bool)) rg_crq_valid <- replicateM(mkReg(False));
        Vector#(`crq_size,Reg#(ICache_core_response)) rg_crq_data <- replicateM(mkReg(unpack(0)));
        Reg# (Bit#(TLog#(`crq_size))) rg_crq_head <- mkReg(0);
        // Wires
        Wire#(Bool) wr_released_head <- mKDWire(False);
        Vector#(`crq_input_size,Wire#(ICache_core_response)) wr_crq_in <- replicateM(mkDWire(unpack(0))); 
        //
        //
        Rules re_enqueue_crq = emptyRules; // Enqueue into CRQ
            for(Integer i=0; i< `crq_input_size; i=i+1) begin
                Rules rg_enqueue_crq = (rules 
                rule rl_crq_enqueue;
                    let lv_req_id = wr_crq_in[i].req_id;
                    if(!wr_flush && wr_crq_in[i].valid) begin
                        rg_crq_valid[lv_req_id] <= wr_crq_in[i].valid;
                        rg_crq_data[lv_req_id] <= wr_crq_in[i];
                    end
                endrule
                endrules);   
            re_enqueue_crq = rJoinConflictFree(rg_enqueue_crq, re_enqueue_crq);
            end
        addRules(re_enqueue_crq);
        //
        //
        rule rl_head_released;
            if(wr_released_head && !wr_flush) begin
                rg_crq_head <= rg_crq_head + 1;
            end
        endrule
        //
        rule rl_flush;
            if(wr_flush) begin
                rg_crq_head <= 0; // invalidate all entries and reset head
                for(Integer i=0;i<`crq_size;i=i+1) begin
                    rg_crq_valid[i] <= False;
                end
            end
        endrule
        //
        // Just enqueue responses from cache into corresponse req_id slot
        method ma_icache_response(Vector#(`crq_input_size, ICache_core_response)  in);
            for(Integer i=0 ;i< `crq_input_size; i=i+1) begin
                wr_crq_in[i] <= in[i];
            end
        endmethod
        //
        // Returns data from the head of crq if valid.
        method ICache_core_response mv_crq_response();
            ICache_core_response lv_resp = unpack(0);
            if(rg_crq_valid[rg_crq_head] && !wr_flush) begin
                lv_resp = rg_crq_data[rg_crq_head];
                wr_released_head <= True;
            end
            return lv_resp;
        endmethod
        //
        method ma_flush(Bool flush);
            wr_flush <= flush;
        endmethod
    endmodule
endpackage