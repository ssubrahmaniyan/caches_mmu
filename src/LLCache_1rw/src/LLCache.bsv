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
  import LLCache_mhb      ::*;
  `include "LLCache.defines"
 // TODO: add doc
  interface Ifc_LLCache;

    /* 
      doc: subinterface: ca_llcache_req 
      description: This interface is used to receive the request from the 
      communication assist. 
    */

    interface Put#(
      CA_LLCache_request_t
      #(`paddr, TMul#(`dblocks, TMul#(`dwords, 8)), `ncores))
      ca_llcache_req;

    /*
      doc: subinterface: llcache_ca_resp
      desc: This interface is used to put responses to the CA for requests
    */

    interface Get#(
      LLCache_CA_response_t
      #(TMul#(`dblocks, TMul#(`dwords, 8)), `paddr, `ncores))
      llcache_ca_resp;

    /*
      doc: subinterface: llcache_ca_req
      desc: This interface is used to put requests to the CA for memory access
    */

    interface Get#(
      LLCache_CA_request_t
      #(`paddr, TMul#(`dblocks, TMul#(`dwords, 8))))
      llcache_ca_req; 

    /*
      doc: subinterface: ca_llcache_response
      desc: Interface to put responses from memory to fill into cache lines
    */

    interface Put#(
      CA_LLCache_response_t
      #(`paddr, TMul#(`dblocks, TMul#(`dwords, 8)), `ncores))
      ca_llcache_resp;

  endinterface: Ifc_LLCache

  (* synthesize *)
  module mkLLCache(Ifc_LLCache)
    provisos(
      // Numeric Alias for better readability
      NumAlias#(TMul#(`dblocks, TMul#(`dwords, 8)), dataWidth),
      NumAlias#(`paddr, paddrWidth)
    );
    /* FIFOs to interact with the interface of the module */
    
    /*doc: FIFO: This fifo stores the request from the communication assist*/
    FIFOF#(
      CA_LLCache_request_t
      #(`paddr, TMul#(`dblocks, TMul#(`dwords, 8)), `ncores)
    ) ff_ca_llcache_request <- mkSizedFIFOF(2);

    /*
      doc: FIFO: ff_llcache_ca_response
      desc: Holds outgoing response to the communication assist
    */
    FIFOF#(
      LLCache_CA_response_t
      #(TMul#(`dblocks, TMul#(`dwords, 8)), `paddr, TLog#(`ncores))
    ) ff_llcache_ca_response <- mkSizedFIFOF(2);

    /*
      doc: FIFO: ff_llcache_ca_request
      desc: Holds outgoing requests to the communication assist
    */
    
    FIFOF#(
      LLCache_CA_request_t
      #(`paddr, TMul#(`dblocks, TMul#(`dwords, 8)))
    ) ff_llcache_ca_request <- mkSizedFIFOF(2);

    /*
      doc: FIFO: ff_ca_llcache_response
      desc: Holds incoming memory fill responses
    */

    FIFOF#(
      CA_LLCache_response_t
      #(`paddr, TMul#(`dblocks, TMul#(`dwords, 8)), `ncores)
    ) ff_ca_llcache_response <- mkSizedFIFOF(2);
   
    /*
      doc: FIFO: ff_data_response
      desc: Holds the data response for the read method to access. Useful to handle 
            hit and miss cases
    */

    FIFOF#(
      LLCache_CA_response_t#(TMul#(`dblocks, TMul#(`dwords, 8)), `paddr, `ncores)     
    ) ff_data_response <- mkSizedFIFOF(2);

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

    // Instance of the Miss Handling Buffer
    Ifc_LLCache_mhb#(
      `mhbsize,
      dataWidth,
      `ncores,
      paddrWidth
    ) m_mhb <- mkLLCache_mhb;

    let waymask = m_tag.mv_tagmatch_response(ff_ca_llcache_request.first.address);
    let is_hit  = (reduceOr(pack(waymask)) == 1); //performs a bitwise OR on the waymask
    //TODO: add assertion to check that waymask does not have more than one hits.

    rule rl_hit(is_hit);
      // retrive and dequeue the request
      let lv_request <- toGet(ff_ca_llcache_request).get();

      // get data using waymask
      let lv_data_response = m_data.mv_response(waymask);

      let resp = LLCache_CA_response_t {
          data: pack(lv_data_response),
          address: lv_request.address,
          hart_id: lv_request.hart_id
      };

      // enqueue the response to the response FIFO
      ff_data_response.enq(resp);
    endrule: rl_hit

    rule rl_miss(!is_hit);
      // retrieve and dequeue the request
      let lv_request <- toGet(ff_ca_llcache_request).get();

      // allocate an entry in the MHB for this miss
      m_mhb.ma_allocate_mhb_entry(
        lv_request.address,
        lv_request.hart_id
      );

      // enqeue a request to the CA for the data on a miss.
      ff_llcache_ca_request.enq(LLCache_CA_request_t{
        address: lv_request.address,
        access: AccessType_t'(Read),
        data: 0 // don't care about data on a read
      });

    endrule: rl_miss

    /*
      doc: rule: fill_mhb
      desc: dequeues entry from the response buffer and updates the mhb
    */
    rule fill_mhb(!m_mhb.mv_mhb_empty() && ff_ca_llcache_response.notEmpty());

      let lv_response = ff_ca_llcache_response.first();
      ff_ca_llcache_response.deq();

      // TODO: add assertion for fills being in same order as requests
      m_mhb.ma_update_mhb_entry(lv_response.data);

    endrule: fill_mhb
    
    rule update_cache(m_mhb.mv_mhb_full());
      // TODO: make update controlled on cache status
      // TODO: ensure data is also sent to apt hart
      let lv_entry <- m_mhb.mav_mhb_release();
      
      m_tag.ma_request(
        AccessType_t'(Write),
        lv_entry.address,
        unpack('0) // TODO: choose way aptly
      );

      m_data.ma_request(
        AccessType_t'(Write),
        unpack('0), // TODO: choose way aptly
        lv_entry.address,
        lv_entry.data
      );
    endrule: update_cache
    
    interface Put ca_llcache_req;
      method Action put(request);

        ff_ca_llcache_request.enq(request);

        m_tag.ma_request(
          AccessType_t'(Read),
          request.address,
          ?  
        );

        m_data.ma_request(
          AccessType_t'(Read) ,
          ?                   , // don't care about wayid on a read
          request.address     ,
          ?                     // don't care about data on a read
        ); 

      endmethod: put
  endinterface

  // Exposes the internal response FIFO as a 
  // standardized Get interface using the toGet transformer.
  // The top value of the response FIFO is returned on a get,
  // and the FIFO is dequeued.
  interface Get llcache_ca_resp = toGet(ff_data_response);
  
  // Exposes the internal response FIFO as a 
  // standardized Get interface using the toGet transformer.
  // The top value of the response FIFO is returned on a get,
  // and the FIFO is dequeued.
  interface Get llcache_ca_req  = toGet(ff_llcache_ca_request);

  interface Put ca_llcache_resp = toPut(ff_ca_llcache_response);

endmodule: mkLLCache

endpackage: LLCache
