/*
Author: Sanjeev Subrahmaniyan
E-mail: subrahmaniyansanjeev@gmail.com
*/

package LLCache_dataram;
 
  // BSV Lib Imports
  import Vector           :: *;

  // Project Lib Imports
  import LLCache_types    :: *;
  import LLCache_lib      :: *;
  import mem_config       :: *;

  interface Ifc_dataram1rw
    #(numeric type lsize,   // size of a line
      numeric type nsets,
      numeric type nways,
      numeric type naddr    // number of bits to address the RAM 
    );

    /*
      doc: method: ma_data_request
      desc: When a request is enqueued into the LLC FIFO,
            it is also simultaneously inserted into the data ram.
    */
    // TODO: Make input composite Maybe
    method Action ma_data_request(
      AccessType access,
      Bit#(TLog#(nways)) wayid,
      Bit#(naddr) addr,
      Bit#(lsize) data
    );

    /*
      doc: method: mv_data_response
      desc: In the second cycle, the response method must be invoked
            with the waymask to read the data line.
            Returns a Maybe# to accomodate write responses also.
    */
    method DataResponse#(lsize) mv_data_response(
      TagResponse#(nways) waymask
    );

  endinterface: LLCache_dataram

  module mkLLCache_dataram
    (Ifc_dataram1rw#(
      lsize,
      nsets,
      nways, 
      naddr
    ))
    provisos(
     Log#(nsets, set_bits),
     Mul#(lsize, 8, line_bits), // number of bits per line in memory
     Add#(offset, set_bits, _a) // bits to index and offset
    );

    /*
    Local Vars
    */
    let v_sets      = valueOf(nsets);
    let v_ways      = valueOf(nways);
    let v_set_bits  = valueOf(set_bits);
    let v_line_bits = valueOf(line_bits);
    let v_offset    = valueOf(offset);    
    
    /*
    Data lines stored in memory instances
    */
    Vector#(nways, Ifc_mem_config1rw#(nsets,      // number of sets per way
                                      line_bits,  // number of bits per line
                                    1))           // number of banks, defaulting to 1
      v_lines <- replicateM(mkmem_config1rw(
                                      False
                                      `ifdef testmode
                                      , test_mode
                                      `endif
                                      ));
    
    method Action ma_data_request(
      AccessType access,
      Bit#(TLog#(nways)) wayid,
      Bit#(naddr) addr,
      Bit#(lsize) data
    );

      Bit#(set_bits) lv_index = addr[v_set_bits + v_offset - 1 : v_offset];

      if(access == Write) begin
        v_lines[wayid].request(pack(access), lv_index, data, 1);
      end
      else begin
        for (Integer i = 0; i < v_ways; i = i + 1)begin
          v_lines[i].request(pack(access), lv_index, data, 1);
        end
      end

    endmethod: ma_data_request

    method DataResponse#(lsize) mv_data_response(
      TagResponse#(nways) waymask
    );
      
      Bit#(nways)         lv_waymask = waymask;
      Bit#(lsize)         lv_data    = 0;
      
      // TODO: replace with map
      for (Integer i = 0; i < v_ways; i = i + 1) begin
        if (lv_waymask[i] == 1) begin
          lv_data = v_lines[i].read_response;
        end
      end

      return DataResponse{
        data : lv_data
      };

    endmethod: mv_data_response
  
  endmodule: mkLLCache_dataram
  
endpackage: LLCache_dataram