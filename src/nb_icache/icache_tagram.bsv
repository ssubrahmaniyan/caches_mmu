package icache_tagram;
    `include "icache_parameters.bsv"
    import nb_icache_types ::*;
    import Vector ::*;
    import BRAMCore ::*;
    
    // Following modules provides the design for the Tag RAM of a non-blocking VIPT cache 
    // The design is built on top of a BRAMCore2 module (1-read, 1-write port)
    interface Ifc_icache_tagram;

    // This method is used to initiate a read on the Tag RAM. Read latency is 2 cycles
    method Action ma_read_request( Bool valid,Bit#(`paddr) address);

    // This method is used to initiate a write on the Tag RAM.
    method Action ma_write_request( Bool valid,
                              Bit#(`paddr) address,
                              Bit#(TLog#(`numways)) way);

    // This method will read the ram output from all ways.  
    // Compare with the input tag and respond with a hit-vector indicating which way was a hit.
    method Bit#(`numways) mv_read_response;
  endinterface

  module mkicache_tagram#(parameter Bit#(32) id)(Ifc_icache_tagram);

    // Number of BRAMs = `numways
    // BRAM length = `numsets 
    // BRAM width = `tagbits
    // BRAM port a is used for reads and port b is used for writes
    // The valid bits are part of a separate structure called "rg_status" (part of nb_icache.bsv)
    Vector#(`numways,BRAM_DUAL_PORT#(Bit#(`setbits), Bit#(`tagbits))) tag_ram <- replicateM(mkBRAMCore2(1, False));
    // Used store the tag from the read request needed for final hitmask generation
    Reg#(Bit#(`tagbits)) rg_read_req_tag  <- mkReg(0);
    //
    method Action ma_read_request( Bool valid,Bit#(`paddr) address);
      Bit#(`setbits) index = fn_extract_set(address);
      if(valid) begin
        for(Integer i=0; i<`numways;i=i+1) begin
          tag_ram[i].a.put(False,index,0); 
        end
        rg_read_req_tag <= truncateLSB(address);
      end
    endmethod
    //
    method Action ma_write_request( Bool valid,
                              Bit#(`paddr) address,
                              Bit#(TLog#(`numways)) way);
      Bit#(`setbits) index = fn_extract_set(address);                
      Bit#(`tagbits) writetag = truncateLSB(address);
      if(valid) begin
          tag_ram[way].b.put(True,index,writetag); 
      end
    endmethod
    //
    method Bit#(`numways) mv_read_response;

      Bit#(`tagbits) tag_in = rg_read_req_tag;
      Bit#(`numways) lv_hitmask = 0;

      Vector#(`numways, Bit#(`tagbits)) lv_tags;
      for (Integer i = 0; i<`numways; i = i + 1) begin
        lv_tags[i] = tag_ram[i].a.read();
      end
      // compare all tags with request tag to generate hitmask
      for (Integer i = 0; i<`numways; i = i + 1) begin
        lv_hitmask[i] = pack(truncate(lv_tags[i]) == tag_in);
      end
      return lv_hitmask;
    endmethod
  endmodule
  //
    (*synthesize*)
  module mkicache_tag#(parameter Bit#(32) id)(Ifc_icache_tagram);
    let ifc();
    mkicache_tagram _temp(id,ifc);
    return (ifc);
  endmodule
endpackage