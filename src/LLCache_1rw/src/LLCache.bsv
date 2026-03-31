package LLCache;
  //Library imports
  import GetPut ::  *;
  import FIFOF  ::  *;

  // Project Imports
  import LLCache_types  ::*;
  import LLCache_tagram ::*;

  interface Ifc_LLCache;

    /* 
      doc: subinterface: receive_ca_req
      description: This interface is used to receive the request from the 
      communication assist. 
    */

    interface Put#(
      LLCache_ca_request
      #(`paddr, TMul#(`dblocks, TMul#(`dwords, 8))))
      receive_ca_req;

  endinterface: Ifc_LLCache

  (*synthesize*)
  module mkLLCache(Ifc_LLCache);

    /* FIFOs to interact with the interface of the module */
    
    /*doc: FIFO: This fifo stores the request from the communication assist*/
    FIFOF#(
      LLCache_ca_request
      #(`paddr, TMul#(`dblocks, TMul#(`dwords, 8)))
    ) ff_ca_request <- mkSizedFIFOF(2);


    // State Elements
    // This module is the tag array.
    Ifc_tagram1rw#(
      `dwords ,
      `dblocks,
      `dways  ,
      `dsets  ,
      `paddr
    ) m_tag <- mkLLCache_tagram;



    interface receive_ca_req = interface Put
      method Action put(LLCache_ca_request#(
          `paddr, TMul#(`dblocks, TMul#(`dwords, 8)))
          request);

      ff_ca_request.enq(request);

      m_tag.ma_request(
        AccessType'(Read),
        request.address,
        ?  
      );
      // TODO: latch on data ram also 

      endmethod: put

    endinterface: Put;

  endmodule: mkLLCache

endpackage
