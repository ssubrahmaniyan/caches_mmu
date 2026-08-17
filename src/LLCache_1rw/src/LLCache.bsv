// TODO: assertions
// TODO: document idiomatic implementations

package LLCache;
  //Library imports
  import GetPut ::  *;
  import FIFOF  ::  *;
  import Vector  ::  *;

  // Project Imports
  import LLCache_types        :: *;
  import LLCache_tagram       :: *;
  import LLCache_dataram      :: *;
  import LLCache_mhb          :: *;
  import LLCache_replacement  :: *;
  import LLCache_lib          :: *;

  `include "LLCache.defines"
  `include "Logger.bsv"
 // TODO: add doc
  interface Ifc_LLCache;

    /* 
      doc: subinterface: ca_llcache_req 
      description: This interface is used to receive the request from the 
      communication assist. 
    */

    interface Put#(
      CA_LLCache_request_t
      #(`paddr, TMul#(`llcblocks, TMul#(`llcwords, 8)), `ncores))
      ca_llcache_req;

    /*
      doc: subinterface: llcache_ca_resp
      desc: This interface is used to put responses to the CA for requests
    */

    interface Get#(
      LLCache_CA_response_t
      #(TMul#(`llcblocks, TMul#(`llcwords, 8)), `paddr, `ncores))
      llcache_ca_resp;

    /*
      doc: subinterface: llcache_ca_req
      desc: This interface is used to put requests to the CA for memory access
    */

    interface Get#(
      LLCache_CA_request_t
      #(`paddr, TMul#(`llcblocks, TMul#(`llcwords, 8))))
      llcache_ca_req; 

    /*
      doc: subinterface: ca_llcache_response
      desc: Interface to put responses from memory to fill into cache lines
    */

    interface Put#(
      CA_LLCache_response_t
      #(`paddr, TMul#(`llcblocks, TMul#(`llcwords, 8)), `ncores))
      ca_llcache_resp;

  endinterface: Ifc_LLCache

  (* synthesize *)
  module mkLLCache(Ifc_LLCache)
    provisos(
      Log#(`llcsets, set_bits),
      // Numeric Alias for better readability
      NumAlias#(TMul#(`llcblocks, TMul#(`llcwords, 8)), dataWidth),
      NumAlias#(`paddr, paddrWidth)
    );
    /* FIFOs to interact with the interface of the module */
    
    /*doc: FIFO: This fifo stores the request from the communication assist*/
    FIFOF#(
      CA_LLCache_request_t
      #(`paddr, TMul#(`llcblocks, TMul#(`llcwords, 8)), `ncores)
    ) ff_ca_llcache_request <- mkSizedFIFOF(2);

    /*
      doc: FIFO: ff_llcache_ca_response
      desc: Holds outgoing response to the communication assist
    */
    FIFOF#(
      LLCache_CA_response_t
      #(TMul#(`llcblocks, TMul#(`llcwords, 8)), `paddr, TLog#(`ncores))
    ) ff_llcache_ca_response <- mkSizedFIFOF(2);

    /*
      doc: FIFO: ff_llcache_ca_request
      desc: Holds outgoing requests to the communication assist
    */
    
    FIFOF#(
      LLCache_CA_request_t
      #(`paddr, TMul#(`llcblocks, TMul#(`llcwords, 8)))
    ) ff_llcache_ca_request <- mkSizedFIFOF(2);

    /*
      doc: FIFO: ff_ca_llcache_response
      desc: Holds incoming memory fill responses
    */

    FIFOF#(
      CA_LLCache_response_t
      #(`paddr, TMul#(`llcblocks, TMul#(`llcwords, 8)), `ncores)
    ) ff_ca_llcache_response <- mkSizedFIFOF(2);
   
    /*
      doc: FIFO: ff_data_response
      desc: Holds the data response for the read method to access. Useful to handle 
            hit and miss cases
    */

    FIFOF#(
      LLCache_CA_response_t#(TMul#(`llcblocks, TMul#(`llcwords, 8)), `paddr, `ncores)     
    ) ff_data_response <- mkSizedFIFOF(2);

    // State Elements
    // This module is the tag array.
    Ifc_tagram1rw#(
      `llcwords ,
      `llcblocks,
      `llcways  ,
      `llcsets  ,
      `paddr
    ) m_tag <- mkLLCache_tagram;

    // Instance of the data array
    Ifc_dataram1rw#(
      `llcwords ,
      `llcblocks,
      `llcsets  ,
      `llcways  ,
      `paddr
    ) m_data <- mkLLCache_dataram;

    // Instance of the Miss Handling Buffer
    Ifc_LLCache_mhb#(
      `mhbsize,
      dataWidth,
      `ncores,
      paddrWidth
    ) m_mhb <- mkLLCache_mhb;

    // Instance of replacement policy module
    Ifc_replace#(
      `llcsets,
      `llcways
    ) m_replace <- mkLLCache_replacement;

    // valid bits for each way in each set
    Vector#(`llcsets, Reg#(Bit#(`llcways))) v_valid <- replicateM(mkReg(0)); 

    Vector#(`llcsets, Reg#(Bit#(`llcways))) v_dirty <- replicateM(mkReg(0)); 

    Vector#(`llcsets, Reg#(Bit#(`llcways))) v_gamma <- replicateM(mkReg(0)); 

    let waymask = m_tag.mv_tagmatch_response(ff_ca_llcache_request.first.address);
    let is_hit  = (reduceOr(pack(waymask)) == 1); //performs a bitwise OR on the waymask
    //TODO: add assertion to check that waymask does not have more than one hits.
    
    (*descending_urgency = "rl_update_cache, rl_hit, rl_miss"*)
    // the update cache rule will respond with data in case of a miss flow
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


      // the replacement module needs to be updated on every access
      m_replace.ma_update_set(
        truncateLSB(lv_request.address),
        waymask.waymask
      );

      // enqueue the response to the response FIFO
      ff_data_response.enq(resp);
    endrule: rl_hit

    rule rl_miss(!is_hit);
      // retrieve and dequeue the request
      let lv_request <- toGet(ff_ca_llcache_request).get();

      let lv_mhb_result <- m_mhb.mav_mhb_manage_miss(
        lv_request.address,
        lv_request.hart_id
      );

      if (lv_mhb_result matches tagged NewlyAllocated) begin
        // if newly allocated then send a request 
        // main memory.
        ff_llcache_ca_request.enq(LLCache_CA_request_t{
          address: lv_request.address,
          access: AccessType_t'(Read),
          data: 0 // don't care about data on a read
        });
      end else if (lv_mhb_result matches tagged DataReady .ret_data) begin
        let resp = LLCache_CA_response_t {
            data: ret_data,
            address: lv_request.address,
            hart_id: lv_request.hart_id
        };
        ff_data_response.enq(resp);
      end

    endrule: rl_miss

    /*
      doc: rule: fill_mhb
      desc: dequeues entry from the response buffer and updates the mhb
    */
    rule rl_fill_mhb(ff_ca_llcache_response.notEmpty());

      let lv_response = ff_ca_llcache_response.first();
      ff_ca_llcache_response.deq();
      `logLevel(llc, 2, $format("[LLC][FILL_DEQUEUE] Addr: %h Data: %h Hart: %0d",
          lv_response.address, lv_response.data, lv_response.hart_id))

      // TODO: add assertion for fills being in same order as requests
      m_mhb.ma_update_mhb_entry(lv_response.data);

    endrule: rl_fill_mhb
    
    rule rl_update_cache;
      // TODO: make update controlled on cache status
      // TODO: ensure data is also sent to apt hart
      let lv_entry <- m_mhb.mav_mhb_release();
      Bit#(set_bits) lv_index = truncateLSB(lv_entry.address);

      let lv_wayidx <- m_replace.mav_line_replace(
        lv_index,
        v_valid[lv_index]
      );

      Bit#(`llcways) lv_waymask = (1 << lv_wayidx);

      // update valid bit for the way being updated
      v_valid[lv_index] <= v_valid[lv_index] | lv_waymask;


      m_tag.ma_request(
        AccessType_t'(Write),
        lv_entry.address,
        lv_wayidx
      );

      m_data.ma_request(
        AccessType_t'(Write),
        lv_wayidx,
        lv_entry.address,
        lv_entry.data
      );

      // respond to CA with the data simultaneously

      let lv_resp = LLCache_CA_response_t {
          data: lv_entry.data,
          address: lv_entry.address,
          hart_id: f_onehot_to_index(lv_entry.hart_id)
      };

      ff_data_response.enq(lv_resp);

    endrule: rl_update_cache
    
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
