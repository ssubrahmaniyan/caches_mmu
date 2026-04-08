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
  import mem_config     :: *;
  
  interface Ifc_tagram1rw
    #(numeric type wordsize , 
      numeric type blocksize,
      numeric type nways     ,
      numeric type nsets     ,
      numeric type paddr    
  );

    /* 
      doc: method: ma_request
      description: This method is used to send
      the request to the tag array for read and write operation. 
      A read is latched on all ways, Write is latched only on one way.
    */
    method Action ma_request(
      AccessType_t        access,
      Bit#(paddr)         address,
      Bit#(TLog#(nways))  way);


    /*
      doc: method: mv_tagmatch_response
      description: This method is used to get the tag match response from the tag array.
    */
    method TagResponse_t#(nways) mv_tagmatch_response(Bit#(paddr) address_in);

    //TODO: Add method for tag select response.

  endinterface: Ifc_tagram1rw

  module mkLLCache_tagram
    (Ifc_tagram1rw#(
      wordsize,
      blocksize,
      nways,
      nsets,
      paddr))
    provisos(
      Log#(nsets, set_bits),       // setbits is the number of bits used as index in BRAM.
      Log#(wordsize, word_bits),   // wordbits is the number of bit sneeded to index a byte in a word
      Log#(blocksize, block_bits), // blockbits is the number of bits needed to index a word in a block
      Add#(word_bits, block_bits, offset),  
      Add#(offset, set_bits, _a),  // _a bits for index + offset
      Add#(tag_bits, _a, paddr),   // tag bits + index + offset = paddr bits
      Alias#(Vector#(nways, Bit#(TLog#(nways))), wayVec)
    );

    /*
    Local Variables
    */
    let v_ways      = valueOf(nways);
    let v_sets      = valueOf(nsets);
    let v_offset    = valueOf(offset);
    let v_set_bits  = valueOf(set_bits);

    /*
    Block RAMs to store the tags.
    */
    Vector#(nways, Ifc_mem_config1rw#(nsets,      // number of sets
                               tag_bits,          // size of tag
                               1))                // number of banks
      v_tags <- replicateM(mkmem_config1rw(
                          False
                          `ifdef testmode
                          ,test_mode
                          `endif
                          )); 


    method Action ma_request(
      AccessType_t        access,
      Bit#(paddr)         address,
      Bit#(TLog#(nways))  way);
      
      Bit#(tag_bits) tag      = truncateLSB(address);
      Bit#(set_bits) lv_index = address[v_set_bits + v_offset - 1 : v_offset];

      function Action req_way(Bit#(TLog#(nways)) w);
        action
          v_tags[w].request(pack(access), lv_index, tag, 1);
        endaction
      endfunction

      case (access) 
        Read : mapM_(req_way, wayVec'(genWith(fromInteger)));
        Write: req_way(way);
      endcase

    endmethod: ma_request

    method TagResponse_t#(nways) mv_tagmatch_response(
      Bit#(paddr) address_in);

      Bit#(tag_bits)  tag_in      = truncateLSB(address_in);

      function Bool is_hit(Ifc_mem_config1rw#(nsets, tag_bits, 1) way_ifc);
        return (way_ifc.read_response == tag_in);
      endfunction

      return TagResponse_t{
        waymask : pack(map(is_hit, v_tags))
      };
    endmethod: mv_tagmatch_response

  endmodule: mkLLCache_tagram

endpackage: LLCache_tagram
