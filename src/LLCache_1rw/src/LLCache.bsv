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
      doc: subinterface: receive_ca_req
      description: This interface is used to receive the request from the 
      communication assist. 
    */

    interface Put#(
      LLCache_ca_request
      #(`paddr, TMul#(`dblocks, TMul#(`dwords, 8))))
      receive_ca_req;

    interface Get#(
      LLCache_ca_llc_response
      #(TMul#(`dblocks, TMul#(`dwords, 8))))
      send_ca_llc_resp;

  endinterface: Ifc_LLCache

  (* synthesize *)
  module mkLLCache(Ifc_LLCache);

    /* FIFOs to interact with the interface of the module */
    
    /*doc: FIFO: This fifo stores the request from the communication assist*/
    FIFOF#(
      LLCache_ca_request
      #(`paddr, TMul#(`dblocks, TMul#(`dwords, 8)))
    ) ff_ca_request <- mkSizedFIFOF(2);

    /*doc: FIFO: ff_ca_llc_responseo
      desc: Holds outgoing response to the communication assist
    */
    FIFOF#(
      LLCache_ca_llc_response
      #(TMul#(`dblocks, TMul#(`dwords, 8)))
    ) ff_ca_llc_response <- mkSizedFIFOF(2);

    Reg#(TagResponse#(`dways)) rg_waymask <- mkReg(unpack('0));

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
      let lv_request = ff_ca_request.first();
      ff_ca_request.deq();

      let lv_waymask = m_tag.mv_tagmatch_response(lv_request.address);

      rg_waymask <= lv_waymask;
    endrule: rl_latch_tag_match

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

        m_data.ma_request(
          AccessType'(Read) ,
          ?                 , // don't care about wayid on a read
          request.address   ,
          ?                   // don't care about data on a read
        ); 

      endmethod: put

    endinterface: Put;

    interface send_ca_llc_resp = interface Get

      method ActionValue#(LLCache_ca_llc_response#(TMul#(`dblocks, TMul#(`dwords, 8)))) get();

        let lv_data_response = m_data.mv_response(rg_waymask);

        return unpack(pack(lv_data_response));

      endmethod: get

    endinterface: Get;

  endmodule: mkLLCache

endpackage: LLCache
