package icache_dataram;
    `include "icache_parameters.bsv"
    `include "Logger.bsv"
    import nb_icache_types ::*;
    import Vector ::*;
    import BRAMCore ::*;
    interface Ifc_icache_dataram;
        // method to initiate a read request (read latency 2 cycles)
        method Action ma_read_request( Bool valid,Bit#(`vaddr) address);

        // method to initiate a write.
        method Action ma_write_request( Bool valid,
                              Bit#(`paddr) address,
                              Bit#(`blocksize) data,
                              Bit#(TLog#(`numways)) way);

        //This method will return block from the bank specified by the hitmask
        method Bit#(`blocksize) mv_read_response(Bit#(`numways) hitmask);
    endinterface
    (*synthesize*)
    module mkicache_dataram(Ifc_icache_dataram);
        // Number of BRAMs = `numways
        // BRAM length = `numsets 
        // BRAM width = `blocksize
        // BRAM port a is used for reads and port b is used for writes
        Vector#(`numways,BRAM_DUAL_PORT#(Bit#(`setbits), Bit#(`blocksize))) data_ram <- replicateM(mkBRAMCore2(`numsets, False));
    
        method Action ma_read_request( Bool valid,Bit#(`vaddr) address);
            if(valid) begin
                Bit#(`setbits) index = fn_extract_set(address);
                for (Integer i = 0; i < `numways; i = i + 1) begin
                    data_ram[i].a.put(False,index,0);
                end
                `logLevel( icache, 2, $format("ICACHE: DRAM: Read request for set %d", index))
            end
        endmethod
        //
        method Action ma_write_request( Bool valid,
                                Bit#(`paddr) address,
                                Bit#(`blocksize) data,
                                Bit#(TLog#(`numways)) way);
            if(valid) begin
                Bit#(`setbits) index = fn_extract_set(zeroExtend(address));
                data_ram[way].b.put(True,index,data);
                `logLevel( icache, 2, $format("ICACHE: DRAM: Write request for set %d way %d # data %h", index, way, data))
            end
        endmethod
        //
        method Bit#(`blocksize) mv_read_response(Bit#(`numways) hitmask);                                   
            Vector#(`numways,Bit#(`blocksize)) lv_read_response = replicate(0);
            Bit#(`blocksize) lv_selected = '0;
            for (Integer i = 0; i < `numways; i = i + 1) begin
                lv_read_response[i] = data_ram[i].a.read();
                if(hitmask[i]==1)
                    lv_selected = lv_read_response[i];
            end
            return lv_selected;
        endmethod
    endmodule
    // 
endpackage
