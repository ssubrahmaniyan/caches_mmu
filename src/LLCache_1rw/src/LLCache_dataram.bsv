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
      doc: method: ma_request
      desc: When a request is enqueued into the LLC FIFO,
            it is also simultaneously inserted into the data ram.
    */
    
    method Action ma_request(
      AccessType_t          access,
      Bit#(TLog#(nways))    wayid,
      Bit#(naddr)           addr,
      Bit#(TMul#(lsize, 8)) data
    );

    /*
      doc: method: mv_response
      desc: In the second cycle, the response method must be invoked
            with the waymask to read the data line.
            Returns a Maybe# to accomodate write responses also.
    */
    method DataResponse_t#(lsize) mv_response(
      TagResponse_t#(nways)   waymask
    );

  endinterface: Ifc_dataram1rw

  module mkLLCache_dataram
    (Ifc_dataram1rw#(
      lsize,
      nsets,
      nways, 
      naddr
    ))
    provisos(
     Log#(nsets, set_bits),
     Mul#(lsize, 8, line_bits),     // number of bits per line in memory
     Add#(offset, set_bits, naddr), // bits to index and offset
     Alias#(Vector#(nways, Bit#(TLog#(nways))), wayVec) 
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
                                      1))         // number of banks, defaulting to 1
      v_lines <- replicateM(mkmem_config1rw(
                                      False
                                      `ifdef testmode
                                      , test_mode
                                      `endif
                                      ));
    
    method Action ma_request(
      AccessType_t          access,
      Bit#(TLog#(nways))    wayid,
      Bit#(naddr)           addr,
      Bit#(TMul#(lsize, 8)) data
    );

      Bit#(set_bits) lv_index = addr[v_set_bits + v_offset - 1 : v_offset];

      function Action f_request(Bit#(TLog#(nways)) wid);
        action
          v_lines[wid].request(pack(access), lv_index, data, 1);
        endaction
      endfunction: f_request

      case(access)
        Write : f_request(wayid);
        Read  : mapM_(f_request, wayVec'(genWith(fromInteger)));
      endcase

    endmethod: ma_request

    method DataResponse_t#(lsize) mv_response(
      TagResponse_t#(nways) waymask
    );
      
      Bit#(line_bits)         lv_data    = 0;
      Bit#(nways)             lv_waymask = pack(waymask);

      function Bit#(line_bits) f_read_response(Ifc_mem_config1rw#(nsets, line_bits, 1) mem_ifc);
        return mem_ifc.read_response;
      endfunction: f_read_response

      function Bit#(TLog#(nways)) f_wayid(Bit#(nways) wm);
          Vector#(nways, Bool) v_mask = unpack(wm);
          
          let maybe_idx = findIndex(id, v_mask);
          
          return pack(fromMaybe(0, maybe_idx));
      endfunction: f_wayid      

      // read response from only the matching tag 
      lv_data = select(map(f_read_response, v_lines), f_wayid(lv_waymask));

      return DataResponse_t{
        data : lv_data
      };

    endmethod: mv_response
  
  endmodule: mkLLCache_dataram
  
endpackage: LLCache_dataram