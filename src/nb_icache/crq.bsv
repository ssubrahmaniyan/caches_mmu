package crq;
    // Implements Core response Queue:  
    // A structure that has 2^reqid_width entries and keeps track of requests and 
    // fetched data in order so that responses can be sent to the core in order.
    //
    import nb_icache_types     ::*;
    import Vector              ::*;
    import DReg                ::*;
    `include "icache_parameters.bsv"
    `include "Logger.bsv"
    //
    function CRQ_core_response fn_extract_crq_data(ICache_core_response in);
        CRQ_core_response lv_crq_data = unpack(0);
        lv_crq_data.valid = in.valid;
        lv_crq_data.packet = in.packet;
        lv_crq_data.trap = in.trap;
        lv_crq_data.cause = in.cause;
        return lv_crq_data;
    endfunction
    interface Ifc_crq;
        method Action ma_icache_response(Vector#(`crq_input_size, ICache_core_response)  in);
        method Action ma_flush(Bool flush);
        method ActionValue#(ICache_core_response) mav_crq_response();
    endinterface
    module mk_crq(Ifc_crq);
        // Registers
        Vector#(`crq_size,Reg#(Bool)) rg_crq_valid <- replicateM(mkReg(False));
        Vector#(`crq_size,Reg#(CRQ_core_response)) rg_crq_data <- replicateM(mkReg(unpack(0)));
        Reg# (Bit#(TLog#(`crq_size))) rg_crq_head <- mkReg(0);
        // Wires
        Wire#(Bool) wr_released_head <- mkDWire(False);
        Wire#(Bool) wr_flush <- mkDWire(False);
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
                        rg_crq_data[lv_req_id] <= fn_extract_crq_data(wr_crq_in[i]);
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
                rg_crq_valid[rg_crq_head] <= False;
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
        method Action ma_icache_response(Vector#(`crq_input_size, ICache_core_response)  in);
            `logLevel( icache, 1, $format("ICACHE: CRQ: Status: head %d", rg_crq_head))
            for(Integer i=0 ;i< `crq_input_size; i=i+1) begin
                wr_crq_in[i] <= in[i];
                `logLevel( icache, 1, $format("ICACHE: CRQ: Request to CRQ (enqueue) %d: ", i, fshow(in[i])))
            end
        endmethod
        //
        // Returns data from the head of crq if valid.
        method ActionValue#(ICache_core_response) mav_crq_response();
            CRQ_core_response lv_resp = unpack(0);
            ICache_core_response lv_resp_final= unpack(0);

            // TODO: bypass responses from the same cycle for regular requests
            // NOTE: For fence/sfence, bypassed responses will need a corresponding change in FTQ on the core side
            if(rg_crq_valid[rg_crq_head] && !wr_flush) begin
                lv_resp = rg_crq_data[rg_crq_head];
                wr_released_head <= True;
                `logLevel( icache, 1, $format("ICACHE: CRQ: Response to Core (dequeue): ", fshow(lv_resp)))
            end
            lv_resp_final = ICache_core_response { valid   : lv_resp.valid,
                                                   req_id  : rg_crq_head,
                                                   packet  : lv_resp.packet,
                                                   trap    : lv_resp.trap,
                                                   cause   : lv_resp.cause };
            return lv_resp_final;
        endmethod
        //
        method Action ma_flush(Bool flush);
            wr_flush <= flush;
            if (flush) begin
              `logLevel( icache, 1, $format("ICACHE: CRQ: Flush received."))
            end
        endmethod
    endmodule
endpackage
