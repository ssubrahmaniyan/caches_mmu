/*
Author: Abhinav I S
Email ID : abhinavis2005@gmail.com
*/

package LLCache_tagram;
  // Library Imports
  import Vector         :: *;
  // Project Imports
  import LLCache_types  :: *;
  import LLCache_lib    :: *;
  
  interface Ifc_tagram1rw
    #(numeric type offset   , // number of bits needed to index a byte in a line
      numeric type ways     ,
      numeric type sets     ,
      numeric type paddr    
  );

    /* 
      doc: method: ma_request
      description: This method is used to send
      the request to the tag array for read and write operation. 
      A read is latched on all ways, Write is latched only on one way.
    */
    method Action ma_request(
      AccessType access,
      Bit#(TLog#(sets)) index,
      Bit#(paddr) address,
      Bit#(TLog#(ways)) way);


    /*
      doc: method: mv_tagmatch_response
      description: This method is used to get the tag match response from the tag array.
    */
    method TagResponse#(ways) mv_tagmatch_response(Bit#(paddr) address_in);

    //TODO: Add method for tag select response.

  endinterface: Ifc_tagram1rw

  module mkLLCache_tagram
    (Ifc_tagram1rw#(
      offset,
      ways,
      sets,
      paddr))
    provisos(
      Log#(sets, set_bits),       // setbits is the number of bits used as index in BRAM.
      Add#(offset, set_bits, _a),  // _a bits for index + offset
      Add#(tag_bits, _a, paddr)   // tag bits + index + offset = paddr bits
    );

    /*
    Local Variables
    */
    let v_ways = valueOf(ways);
    let v_sets = valueOf(sets);

    /*
    Block RAMs to store the tags.
    */
    Vector#(ways, Ifc_mem_1rw#(sets,      // number of sets
                               tag_bits,  // size of tag
                               1))          // number of banks
      v_tags <- replicateM(mkmem_1rw); 


    method Action ma_request(
      AccessType access,
      Bit#(TLog#(sets)) index,
      Bit#(paddr) address,
      Bit#(TLog#(ways)) way);
      
      Bit#(tag_bits) tag = truncateLSB(address);
      for (Integer i = 0; i < v_ways; i = i + 1) begin
        v_tags[i].request(access, index, tag, 1);
      end
    endmethod: ma_request

    method TagResponse#(ways) mv_tagmatch_response(Bit#(paddr) address_in);
      Bit#(tag_bits) tag_in = truncateLSB(address_in);
      Bit#(ways) lv_hit_vec = 0;
      Vector#(ways, Bit#(tag_bits)) lv_tags;

      for (Integer i = 0; i < v_ways; i = i + 1) begin
        lv_tags[i] = v_tags[i].read_response;
      end

      for (Integer i = 0; i < v_ways; i = i + 1) begin
        lv_hit_vec[i] = pack(truncate(lv_tags[i]) == tag_in);
      end

      return TagResponse{
        waymask : lv_hit_vec
      };
    endmethod: mv_tagmatch_response

  endmodule: mkLLCache_tagram

endpackage: LLCache_tagram
