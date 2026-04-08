// TODO: assertions
// TODO: document idiomatic implementations

package LLCache;
  //Library imports
  import GetPut ::  *;
  import FIFOF  ::  *;

  // Project Imports
  import LLCache_types    ::*;
  import LLCache_tagram   ::*;
  import LLCache_dataram  ::*;

 // TODO: add doc
  interface Ifc_LLCache;

    /* 
      doc: subinterface: ca_llcache_req 
      description: This interface is used to receive the request from the 
      communication assist. 
    */

    interface Put#(
      CA_LLCache_request_t
      #(`paddr, TMul#(`dblocks, TMul#(`dwords, 8))))
      ca_llcache_req;

    /*
      doc: subinterface: llcache_ca_resp
      desc: This interface is used to put responses to the CA for requests
    */

    interface Get#(
      LLCache_CA_response_t
      #(TMul#(`dblocks, TMul#(`dwords, 8))))
      llcache_ca_resp;

    /*
      doc: subinterface: llcache_ca_req
      desc: This interface is used to put requests to the CA for memory access
    */

    interface Get#(
      LLCache_CA_request_t
      #(`paddr, TMul#(`dblocks, TMul#(`dwords, 8))))
      llcache_ca_req; 

  endinterface: Ifc_LLCache

  (* synthesize *)
  module mkLLCache(Ifc_LLCache);

    /* FIFOs to interact with the interface of the module */
    
    /*doc: FIFO: This fifo stores the request from the communication assist*/
    FIFOF#(
      CA_LLCache_request_t
      #(`paddr, TMul#(`dblocks, TMul#(`dwords, 8)))
    ) ff_ca_llcache_request <- mkSizedFIFOF(2);

    /*
      doc: FIFO: ff_llcache_ca_response
      desc: Holds outgoing response to the communication assist
    */
    FIFOF#(
      LLCache_CA_response_t
      #(TMul#(`dblocks, TMul#(`dwords, 8)))
    ) ff_llcache_ca_response <- mkSizedFIFOF(2);

    /*
      doc: FIOF: ff_llcache_ca_request
      desc: Holds outgoing requests to the communication assist
    */
    
    FIFOF#(
      LLCache_CA_request_t
      #(`paddr, TMul#(`dblocks, TMul#(`dwords, 8)))
    ) ff_llcache_ca_request <- mkSizedFIFOF(2);

    Reg#(TagResponse_t#(`dways)) rg_waymask <- mkReg(unpack('0));

// TODO: change dwords to llc
    // State Elements
    // This module is the tag array.
    Ifc_tagram1rw#(
      `dwords ,
      `dblocks,
      `dways  ,
      `dsets  ,
      `paddr
    ) m_tag <- mkLLCache_tagram;

    // Instance of the data array
    Ifc_dataram1rw#(
      TMul#(`dwords, `dblocks),
      `dsets                  ,
      `dways                  ,
      `paddr
    ) m_data <- mkLLCache_dataram;

    rule rl_latch_tag_match;
      let lv_request = ff_ca_llcache_request.first();
      ff_ca_llcache_request.deq();

      let lv_waymask = m_tag.mv_tagmatch_response(lv_request.address);

      rg_waymask <= lv_waymask;
    endrule: rl_latch_tag_match

    interface ca_llcache_req = interface Put

      method Action put(CA_LLCache_request_t#(
          `paddr, TMul#(`dblocks, TMul#(`dwords, 8)))
          request);

        ff_ca_llcache_request.enq(request);

        m_tag.ma_request(
          AccessType_t'(Read),
          request.address,
          ?  
        );

        m_data.ma_request(
          AccessType_t'(Read) ,
          ?                 , // don't care about wayid on a read
          request.address   ,
          ?                   // don't care about data on a read
        ); 

      endmethod: put

    endinterface: Put;

    interface llcache_ca_resp = interface Get

      method ActionValue#(LLCache_CA_response_t#(TMul#(`dblocks, TMul#(`dwords, 8)))) get();

        let lv_data_response = m_data.mv_response(rg_waymask);

        return unpack(pack(lv_data_response));

      endmethod: get

    endinterface: Get;

  endmodule: mkLLCache

endpackage: LLCache
