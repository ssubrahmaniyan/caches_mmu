/*
Copyright (c) 2019, IIT Madras All rights reserved.

Redistribution and use in source and binary forms, with or without modification, are permitted
provided that the following conditions are met:

* Redistributions of source code must retain the above copyright notice, this list of conditions
  and the following disclaimer.
* Redistributions in binary form must reproduce the above copyright notice, this list of
  conditions and the following disclaimer in the documentation and/or other materials provided
  with the distribution.
* Neither the name of IIT Madras  nor the names of its contributors may be used to endorse or
  promote products derived from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS
OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY
AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR
CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER
IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT
OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
--------------------------------------------------------------------------------------------------

Author: Neel Gala
Email id: neelgala@gmail.com
Details:

--------------------------------------------------------------------------------------------------
*/
package dcache;
  `include "Logger.bsv"
  import FIFO :: * ;
  import FIFOF :: * ;
  import SpecialFIFOs :: * ;
  import BRAMCore :: * ;
  import Vector :: * ;
  import GetPut :: * ;
  import Assert  :: * ;
  import OInt :: * ;
  import BUtils :: * ;
  import Memory :: * ; // only for the updateDataWithMask function
  import DReg :: * ;
  import coherence_types :: * ;
  import ConfigReg :: * ;
  `include "coherence.defines"


  `include "cache.defines"
  import cache_types :: * ;
  import common_tlb_types :: * ;
  import globals :: * ;
  import replacement_dcache :: * ;
  import mem_config :: * ;
  import storebuffer :: * ;

  typedef struct{
    Bit#(addr)  phyaddr;
    Bit#(besize) init_enable;
    Bit#(TLog#(fbsize)) fbindex;
    Bool io_request;
  } Pending_req#(numeric type addr, numeric type besize, numeric type fbsize) 
                deriving(Bits, Eq, FShow);

  typedef struct{
    Cacheline_state state;
    Access perm;
    Bit#(TLog#(`NrCaches)) acks_expected;
    Bit#(TLog#(`NrCaches)) acks_received;
  } CoherenceMeta deriving(Bits, FShow, Eq);

  interface Ifc_dcache#(numeric type wordsize,
                        numeric type blocksize,
                        numeric type sets,
                        numeric type ways,
                        numeric type paddr,
                        numeric type vaddr,
                        numeric type sbsize,
                        numeric type fbsize,
                        numeric type esize,
                      `ifdef ECC
                        numeric type ecc_wordsize,
                        numeric type ebanks,
                      `endif
                        numeric type dbanks,
                        numeric type tbanks,
                        numeric type buswidth
                           );
    interface Put#(DCache_core_request#(vaddr,TMul#(wordsize,8),esize)) core_req;
    interface Get#(DMem_core_response#(TMul#(wordsize,8),esize)) core_resp;
    interface Get#(Message#(paddr,TMul#(wordsize,blocksize))) mv_request_to_fabric;
    interface Get#(NCAccess#(paddr, TMul#(wordsize,8))) mv_io_request_to_fabric;
    interface Get#(Message#(paddr,TMul#(wordsize,blocksize))) mv_response_to_fabric;
    interface Get#(Message#(paddr,TMul#(wordsize,blocksize))) mv_response2_to_fabric;
    interface Put#(Message#(paddr,TMul#(wordsize,blocksize))) mv_response_from_fabric;
  `ifdef supervisor
    interface Get#(DMem_core_response#(TMul#(wordsize,8),esize)) ptw_resp;
    interface Put#(DTLB_core_response#(paddr)) mav_pa_from_tlb;
    interface Get#(DCache_core_request#(vaddr, TMul#(wordsize, 8), esize)) hold_req;
  `endif
  `ifdef perfmonitors
    method Bit#(9) perf_counters;
  `endif
    method Action ma_cache_enable(Bool c);
    method Bool mv_storebuffer_empty;
    method Action ma_perform_store(Bit#(esize) currepoch);
    method Bool mv_cacheable_store;
    method Bool mv_cache_available;
    method Bool mv_commit_store_ready;
  endinterface

  function Access fn_genAccess(Bit#(2) access);
    case (access)
      'd0: return Load;
      'd1,'d2: return Store;
      default: return None;
    endcase
  endfunction

  function Bool fn_permissions_avail(Bit#(2) a, Access p);
    let access = fn_genAccess(a);
    if( p == Store)
      return True;
    else if( (p == Load || p==Store) && (access == Load))
      return True;
    else
      return False;
  endfunction

  function Bool fn_upgrade_required(Bit#(2) a, Cacheline_state s, Access p);
    let access = fn_genAccess(a);
    return (access == Store && access !=p && s == Cacheline_state_S);
  endfunction

  function Bool fn_is_stable (Cacheline_state curr_state);
    case(curr_state)
      Cacheline_state_I, Cacheline_state_M, Cacheline_state_S: return True;
      default: return False;
    endcase
  endfunction

  /*doc:module: */
  // both update rg_handling_miss but can never fire together
  (*conflict_free="rl_send_memory_request, rl_response_to_core"*)

  // both update different entries of fb
  (*conflict_free="rl_send_memory_request, rl_fill_from_memory"*) 

  // both update fb buffer entries, however both can never fire simultaneously
  (*conflict_free="rl_send_memory_request, rl_release_from_fillbuffer"*)

  //both of these update fillbuffer entries but can never fire simultaneously
  (*conflict_free="rl_response_to_core,rl_fill_from_memory"*)
  (*conflict_free="rl_response_to_core,rl_release_from_fillbuffer"*)

  // the following affect fb and sb. however, store cannot be performed on a line being allotted
  // and similarly a store entry cannot be committed which is just being allotted.
  (*conflict_free="rl_response_to_core,ma_perform_store"*)

  // the following update fb simultaneously. However, if the fb entry updated by the store is the
  // same as the one being ffilled then that is taken care of by using masks during fill
  (*conflict_free="rl_fill_from_memory,ma_perform_store"*)

  // the following conflict in writing the dirty entries of the fb. memory request will assign a new
  // entry in fb while ma_perform_store will update an existing allotted entry in the fb so hence no
  // true conflict detected.
  (*conflict_free="rl_send_memory_request,ma_perform_store"*)

  // the following rules update FB simultaneously. It is possible that fill-from memory tries to
  // change a fb-entry which is in stable state which is also being released in the same cycle. Thus
  // we give preference to the fill_from_memory rule. The release is a polling rule so re-firing
  // will still preserse state. Also, when the release causes an eviction we need acknowledgements
  // from the directory to actually evict. These will arriave through fill_from_memory rule and thus
  // is give more priority.
  (*preempts="rl_fill_from_memory,rl_release_from_fillbuffer"*)

  // the following rules can update the same entry in the SRAMs. Thus we give priority to response
  // core which will cause the entry to move to the fill-buffer and thus cause the rl_update_ram to
  // not fire. The rule rl_fill_from_memory will fire again and will find the entry in the FB
  // instead of the RAM this time.
  (*preempts="rl_response_to_core,rl_update_ram"*)
  
  // the following rules can update the same entry in the SRAMs. Thus we give priority to response
  // core which will cause the entry to move to the fill-buffer and thus cause the rl_update_ram to
  // not fire. The rule rl_fill_from_memory will fire again and will find the entry in the FB
  // instead of the RAM this time.
  (*preempts="rl_send_memory_request,rl_update_ram"*)

  // the below rules both update wr_nc_state but they can never update this together 
  // since fill_memory will update wr_nc_state only if its a IO load request in which case
  // rg_handling_miss is set to true and thus rl_ram_check cannot fire in this conditions
  (*preempts="rl_ram_check, rl_fill_from_memory"*)
  module mkdcache#(function Bool isNonCacheable(Bit#(paddr) addr, Bool cacheable), 
                  parameter String alg, parameter Bit#(32) id)
                  (Ifc_dcache#(wordsize, blocksize, sets, ways, paddr, vaddr, sbsize, fbsize,
                                esize, dbanks, tbanks, buswidth))
    provisos(
          Mul#(wordsize, 8, respwidth),        // respwidth is the total bits in a word
          Mul#(blocksize, respwidth,linewidth),// linewidth is the total bits in a cache line
          Log#(wordsize,wordbits),      // wordbits is no. of bits to index a byte in a word
          Log#(blocksize, blockbits),   // blockbits is no. of bits to index a word in a block
          Log#(sets, setbits),           // setbits is the no. of bits used as index in BRAMs.
          Add#(wordbits,blockbits,_a),  // _a total bits to index a byte in a cache line.
          Add#(_a, setbits, _b),        // _b total bits for index+offset,
          Add#(tagbits, _b, paddr),     // tagbits = 32-(wordbits+blockbits+setbits)
          Div#(buswidth,respwidth,o__),
          Add#(o__, p__, 2),            // ensure that the buswidth is no more than 2 x respwidth

          // required by bsc
          Mul#(TDiv#(linewidth, TDiv#(linewidth, 8)), TDiv#(linewidth, 8),linewidth),
          Add#(a__, paddr, vaddr),
          Add#(b__, respwidth, linewidth),
          Add#(TAdd#(wordbits, blockbits), d__, paddr),
          Add#(e__, TLog#(ways), 4),
          Add#(f__, TLog#(ways), TLog#(TAdd#(1, ways))),
          Add#(g__, respwidth, buswidth),
          Mul#(buswidth, c__, linewidth),
          Add#(j__, 8, respwidth),
          Add#(k__, 16, respwidth),
          Add#(l__, 32, respwidth),
          Add#(m__, respwidth, vaddr),
          Add#(1, r__, respwidth),
          Add#(u__, TLog#(TDiv#(linewidth, buswidth)), paddr),
          Add#(x__, blockbits, paddr),
          Add#(TAdd#(tagbits, setbits), y__, paddr),
          Mul#(TMul#(wordsize, 8), z__, linewidth),
          Mul#(aa__, 8, linewidth),
          Add#(ab__, TLog#(fbsize), TLog#(TAdd#(1, fbsize))),
          Div#(linewidth, 8, aa__),
        `ifdef ASSERT
          Add#(1, n__, TLog#(TAdd#(1, ways))),
        `endif
          Add#(ac__, respwidth, TMul#(8, TMul#(wordsize, blocksize))),

          // for using mem_config
          Mul#(TDiv#(tagbits, tbanks), tbanks, tagbits),
          Add#(h__, TDiv#(tagbits, tbanks), tagbits),
          Mul#(TDiv#(linewidth, dbanks), dbanks, linewidth),
          Add#(i__, TDiv#(linewidth, dbanks), linewidth),
          Add#(q__, TDiv#(linewidth, buswidth), paddr),

          // for using storebuffer
          Add#(s__, wordbits, TMul#(wordbits, 2)),
          Add#(1, t__, sbsize),
          Mul#(16, v__, respwidth),
          Mul#(32, w__, respwidth)

    );

    String dcache = "";
    let v_sets=valueOf(sets);
    let v_setbits=valueOf(setbits);
    let v_wordbits=valueOf(wordbits);
    let v_blockbits=valueOf(blockbits);
    let v_linewidth=valueOf(linewidth);
    let v_tagbits=valueOf(tagbits);
    let v_paddr=valueOf(paddr);
    let v_ways=valueOf(ways);
    let v_wordsize=valueOf(wordsize);
    let v_blocksize=valueOf(blocksize);
    let v_respwidth=valueOf(respwidth);
    let v_fbsize = valueOf(fbsize);
    Integer lv_offset = case(valueOf(respwidth))
      32: 4;
      64: 8;
      128: 16;
    endcase;
    Integer lv_offset1 = case(valueOf(buswidth))
      32: 4;
      64: 8;
      128: 16;
    endcase;

    /*doc:func: This function generates the byte-enable for a data-line sized vector based on the
     * request made by the core */
    function Bit#(TDiv#(linewidth,8)) fn_enable(Bit#(blockbits) word_index);
      Bit#(TDiv#(linewidth,8)) write_enable = 'hF << ({4'b0,word_index}*fromInteger(lv_offset));
      return write_enable;
    endfunction
    
    /*doc:func: This function generates the byte-enable for a data-line sized vector based on the
     * request made by the core */
    function Bit#(TDiv#(linewidth,8)) fn_init_enable(Bit#(TLog#(TDiv#(linewidth,buswidth))) word_index);
      Bit#(TDiv#(linewidth,8)) we = case(valueOf(buswidth))
        32: 'hF;
        64:'hFF;
        default:'hFFFF;
      endcase;
      Bit#(TDiv#(linewidth,8)) write_enable = we << ({4'b0,word_index}*fromInteger(lv_offset1));
      return write_enable;
    endfunction

    // ----------------------- FIFOs to interact with interface of the design -------------------//
    /*doc:fifo: This fifo stores the request from the core.*/
    FIFOF#(DCache_core_request#(vaddr, respwidth, esize)) ff_core_request <- mkSizedFIFOF(2);
    /*doc:fifo: This fifo stores the response that needs to be sent back to the core.*/
    FIFOF#(DMem_core_response#(respwidth,esize))ff_core_response <- mkBypassFIFOF();
  `ifdef supervisor
    /*doc:fifo: This fifo stores the response that needs to be sent back to the ptw.*/
    FIFOF#(DMem_core_response#(respwidth,esize))ff_ptw_response <- mkBypassFIFOF();
  `endif
    FIFOF#(Message#(paddr,TMul#(wordsize,blocksize))) ff_req_to_fabric <- mkSizedFIFOF(2);
    FIFOF#(NCAccess#(paddr,TMul#(wordsize,8))) ff_io_req_to_fabric <- mkSizedFIFOF(2);
    FIFOF#(Message#(paddr,TMul#(wordsize,blocksize))) ff_resp_to_fabric <- mkSizedFIFOF(2);
    FIFOF#(Message#(paddr,TMul#(wordsize,blocksize))) ff_resp2_to_fabric <- mkSizedFIFOF(2);
    FIFOF#(Message#(paddr,TMul#(wordsize,blocksize))) ff_resp_from_fabric <- mkSizedFIFOF(2);
  `ifdef supervisor 
    /*doc:fifo: this fifo receives the physical address from the TLB */
    FIFOF#(DTLB_core_response#(paddr)) ff_from_tlb <- mkBypassFIFOF();
    /*doc:fifo: this fifo holds the request from core when there has been a tlbmiss */
    FIFOF#(DCache_core_request#(vaddr, respwidth, esize)) ff_hold_request <- mkBypassFIFOF();
  `endif

    // ------------------------ FIFOs for internal state-maintenance ---------------------------//
    /*doc:fifo: This fifo holds meta information of the miss/io request that was made by the core*/
    FIFOF#(Pending_req#(paddr, TDiv#(linewidth,8),fbsize)) ff_pending_req <- mkUGSizedFIFOF(2);    

    // -------------------- Register declarations ----------------------------------------------//

    /*doc:reg: register when True indicates a fence is in progress and thus will prevent taking any
     new requests from the core*/
    Reg#(Bool) rg_fence_stall <- mkRegA(False);

    /*doc:reg: When tru indicates that a miss is being catered to*/
    Reg#(Bool) rg_handling_miss <- mkRegA(False);

    /*doc:reg: */
    Reg#(Bit#(1)) rg_wEpoch <- mkReg(0);

    //------------------------- Fill buffer data structures -------------------------------------//
    
    Vector#(fbsize,Reg#(Bool))                      v_fb_valid    <- replicateM(mkReg(False));
    Vector#(fbsize,Reg#(Bit#(linewidth)))           v_fb_data     <- replicateM(mkReg(unpack(0)));
    Vector#(fbsize,Reg#(Bit#(1)))                   v_fb_err      <- replicateM(mkReg(0));
    Vector#(fbsize,Reg#(Bit#(TDiv#(linewidth,8))))  v_fb_enables  <- replicateM(mkReg(0));
    Vector#(fbsize,ConfigReg#(Bit#(paddr)))         v_fb_addr     <- replicateM(mkConfigReg(0));

    /*doc:reg: register pointing to next entry being allotted on the filbuffer*/
    Reg#(Bit#(TLog#(fbsize)))                       rg_fbhead     <- mkReg(0);
    /*doc:reg: register pointing to the next entry being released from the fillbuffer*/
    Reg#(Bit#(TLog#(fbsize)))                       rg_fbtail     <- mkReg(0);
    /*doc:reg: temporary register holding the WE for the data to be updated in the fillbuffer from
    * the memory response*/
    Reg#(Bit#(TDiv#(linewidth,8)))                  rg_temp_enable<- mkReg(0);
    /*doc:reg: this register indicates the read-phase of the release sequence*/
    Reg#(Bool) rg_release_readphase <- mkReg(False);
    /*doc:reg: this register indicates that post eviction a replay to the p1 port is required*/
    Reg#(Bool) rg_replay_required <- mkReg(False);

    /*doc:reg: This register indicates that the bram inputs are being re-driven by those provided
    * from the core in the most recent request. This happens because as the release from the
    * fillbuffer happens it is possible that a dirty ways needs to be read out. This will change the
    * output of the brams as compared to what the core requested. Thus the core request needs to be
    * replayed on these again */
    Reg#(Bool) rg_performing_replay <- mkReg(False);
    /*doc:reg: this register holds the index of the most recent request performed by the core*/
    Reg#(Bit#(setbits)) rg_recent_req <- mkReg(0);
    
    Bit#(tagbits) writetag = truncateLSB(v_fb_addr[rg_fbtail]);
    Bit#(linewidth) writedata = v_fb_data[rg_fbtail];

    /*doc:wire: in case of a hit in fb this wire will hold the index of the fb which was a hit. This
    * value is used to indicate the storebuffer which fb entry it needs to update when committing
    * the store*/
    Wire#(Bit#(TLog#(fbsize))) wr_fb_hitindex <- mkDWire(?);
    
    /*doc:var: variable indicating the fillbuffer is full*/
    Bool fb_full = (all(isTrue, readVReg(v_fb_valid)));
    /*doc:var: variable indicating the fillbuffer is empty*/
    Bool fb_empty=!(any(isTrue, readVReg(v_fb_valid)));
//    Bool fill_oppurtunity = (!ff_core_request.notEmpty ) && !fb_empty &&
//         /*countOnes(fb_valid)>0 &&*/ (fillindex != rg_latest_index);
    // ------------------------------------------------------------------------------------------//
    
    // ----------------------------- structures for fence operation -----------------------------//
    /*doc:reg: this register selects the way for performing a fence operation */
    Reg#(Bit#(TLog#(ways))) rg_fence_way <- mkRegA(0);
    /*doc:reg: this register selects the set for performing a fence operation */
    Reg#(Bit#(TLog#(sets))) rg_fence_set <- mkRegA(0);
    /*doc:reg: This register when true indicates that a there exists alteast one dirty line within
     * the data cache */
    Reg#(Bool) rg_globaldirty <- mkRegA(False);
    /*doc:reg:*/
    Reg#(Bool) rg_fenceinit <- mkRegA(True);
    // ------------------------------------------------------------------------------------------//

    // -------------------- Wire declarations ----------------------------------------------//
    /*doc:wire: boolean wire indicating if the cache is enabled. This is controlled through a csr*/
    Wire#(Bool) wr_cache_enable<-mkWire();

    /*doc:wire: this wire indicates if there was a hit or miss on SRAMs.*/
    Wire#(RespState) wr_ram_state <- mkDWire(None);
    Wire#(DMem_core_response#(respwidth,esize)) wr_ram_response <- mkDWire(?);
    Wire#(Bit#(TLog#(ways))) wr_ram_hitway <-mkDWire(0);
    Wire#(Bit#(linewidth)) wr_ram_hitline <- mkDWire(?);
    Wire#(Maybe#(Bit#(setbits))) wr_ram_hitset <- mkDWire(tagged Invalid);

    /*doc:wire: this wire indicates if there was a hit or miss on Fllbuffer.*/
    Wire#(RespState) wr_fb_state <- mkDWire(None);
    Wire#(DMem_core_response#(respwidth,esize)) wr_fb_response <- mkDWire(?);

    Wire#(RespState) wr_nc_state <- mkDWire(None);
    Wire#(DMem_core_response#(respwidth,esize)) wr_nc_response <- mkDWire(?);
  `ifdef perfmonitors
    /*doc:wire: wire to pulse on every read access*/
    Wire#(Bit#(1)) wr_total_read_access <- mkDWire(0);
    /*doc:wire: wire to pulse on every write access*/
    Wire#(Bit#(1)) wr_total_write_access <- mkDWire(0);
    /*doc:wire: wire to pulse on every atomic access*/
    Wire#(Bit#(1)) wr_total_atomic_access <- mkDWire(0);
    /*doc:wire: wire to pulse on every io read access*/
    Wire#(Bit#(1)) wr_total_io_reads <- mkDWire(0);
    /*doc:wire: wire to pulse on every io write access*/
    Wire#(Bit#(1)) wr_total_io_writes <- mkDWire(0);
    /*doc:wire: wire to pulse on every read miss within the cache*/
    Wire#(Bit#(1)) wr_total_read_miss <- mkDWire(0);
    /*doc:wire: wire to pulse on every write miss within the cache*/
    Wire#(Bit#(1)) wr_total_write_miss <- mkDWire(0);
    /*doc:wire: wire to pulse on every atomic miss within the cache*/
    Wire#(Bit#(1)) wr_total_atomic_miss <- mkDWire(0);
    /*doc:wire: wire to pulse on every eviction from the cache*/
    Wire#(Bit#(1)) wr_total_evictions <- mkDWire(0);
  `endif


    // ----------------------- Storage elements -------------------------------------------//
    /*doc:ram: This the tag array which is dual ported has 'way' number of rams*/
    Ifc_mem_config2rw#(sets, tagbits, tbanks) bram_tag [v_ways];

    /*doc:ram: This the data array which is dual ported has 'way' number of rams*/
    Ifc_mem_config2rw#(sets, linewidth, dbanks) bram_data[v_ways];
    for (Integer i = 0; i<v_ways; i = i + 1) begin
      bram_tag[i]  <- mkmem_config2rw(False,"double");
      bram_data[i] <- mkmem_config2rw(False,"double");
    end
    Ifc_replace#(sets,ways) replacement <- mkreplace(alg);

    // --------------------- Store buffer related structures ----------------------------------//
    Ifc_storebuffer#(paddr, wordsize, esize, sbsize, fbsize) storebuffer <- mk_storebuffer(id);
    Wire#(Bit#(TDiv#(linewidth,8))) wr_store_be <- mkDWire(0);
    Wire#(Bit#(linewidth)) wr_store_data <- mkDWire(0);
    Bool sb_empty = storebuffer.mv_sb_empty;
    Bool sb_full = storebuffer.mv_sb_full;
    Wire#(Bool) wr_allocating_storebuffer <- mkDWire(False);

    // ----------------------- Coherency related structures -----------------------------------//
    /*doc:reg: This is an arry of coherency states for each of the lines in the RAMs*/
    Vector#( sets, Vector#(ways, Reg#(CoherenceMeta) )) v_reg_cmeta 
        <- replicateM(replicateM(mkReg(CoherenceMeta{state: Cacheline_state_I, perm:None, 
                                                    acks_expected:0, acks_received:0})));

    /*doc:reg: This is an arry of coherency states for each of the lines in the FB*/
    Vector#(fbsize, Reg#(CoherenceMeta)) v_fb_cmeta
        <- replicateM(mkReg(CoherenceMeta{state:Cacheline_state_I, perm:None,
                            acks_expected:0, acks_received:0}));
    /*doc:wire: when true indicates that the requested line exists in the RAM but does not hold the
    * required permissions*/
    Wire#(Bool) wr_ram_permission_upgrade <- mkDWire(False);

    /*doc:wire: when Valid indicates that the particular fb entry is a hit but does not have valid
    * permissions to respond to the core as a hit*/
    Wire#(Bool) wr_fb_permission_upgrade <- mkDWire(False);

    Bool fb_stable = fn_is_stable(v_fb_cmeta[rg_fbtail].state);
    /*doc:reg: */
    Reg#(Bool) rg_ram_cc_update <- mkDReg(False);

    // --------------------------- Rule operations ------------------------------------- //

    /*doc:rule: */
    rule rl_print_stats;
      `logLevel( dcache, 2, $format("DCACHE[%2d]: fb_full:%b fb_empty:%b fbhead:%d fbtail:%d\
  fb_stable:%b",id, fb_full, fb_empty, rg_fbhead, rg_fbtail, fb_stable))
      `logLevel( dcache, 2, $format("DCACHE[%2d]: sb_full:%b sb_empty:%b ",
                                    id,sb_full, sb_empty))
    endrule
    /*doc:rule: rule that fences the cache by invalidating all the lines*/
    rule rl_fence_operation(ff_core_request.first.fence && rg_fence_stall && fb_empty &&
                              sb_empty && !rg_performing_replay 
                              && !rg_ram_cc_update) ;
      `logLevel( dcache, 0, $format("DCACHE[%2d] : Fence operation in progress",id))

      let lv_curr_way = rg_fence_way;
      let lv_curr_set = rg_fence_set;
      
      let lv_next_way = rg_fence_way;
      let lv_next_set = {1'b0,rg_fence_set};

      // done to avoid additional provisos for this combination
      Bit#(TSub#(paddr, TAdd#(tagbits, setbits))) zeros = 'd0;

      Bit#(tagbits) tag = bram_tag[rg_fence_way].p1.read_response;
      Bit#(linewidth) dataline = bram_data[rg_fence_way].p1.read_response;
      Bit#(paddr) final_address={tag, rg_fence_set, zeros};
      `logLevel( dcache, 0, $format("DCACHE[%2d]: Fence: CurrWay:%2d CurrSet:%2d Addr:%h Data:%h",
          id, lv_curr_way,lv_curr_set, final_address, dataline ))
      let lv_c_meta = v_reg_cmeta[rg_fence_set][rg_fence_way];
      Bool writeback_condition = lv_c_meta.state == Cacheline_state_M || 
                                 lv_c_meta.state ==  Cacheline_state_S;
      if( writeback_condition) begin
        let _t = ENTRY_Cacheline_state{state:lv_c_meta.state, perm:lv_c_meta.perm, 
                        cl:dataline, acksReceived:lv_c_meta.acks_received,
                        acksExpected:lv_c_meta.acks_expected, id: tagged Caches truncate(id)};

        let {newcle, message} = func_frm_core(_t, final_address, Evict);
        if(message matches tagged Valid .m)
          ff_req_to_fabric.enq(m);
        v_reg_cmeta[rg_fence_set][rg_fence_way] <= CoherenceMeta{state: newcle.state,
            perm:newcle.perm,acks_expected:newcle.acksExpected, acks_received:newcle.acksReceived};
      end
      if( lv_c_meta.state == Cacheline_state_I) begin
        if(lv_curr_way == fromInteger(v_ways-1))
          lv_next_set = zeroExtend(lv_curr_set) + 1;

        if(v_ways > 1)
          lv_next_way = lv_curr_way + 1;
      end

      bram_data[lv_next_way].p1.request(0,truncate(lv_next_set),writedata);
      bram_tag[lv_next_way].p1.request(0, truncate(lv_next_set),writetag);

      if((lv_curr_way == fromInteger(v_ways - 1) && lv_next_set== fromInteger(v_sets))
              || !rg_globaldirty) begin
        rg_globaldirty <= False;
        rg_fence_stall <= False;
        ff_core_request.deq;
        replacement.reset_repl;
        rg_fence_way <= 0;
        rg_fence_set <= 0;
        ff_core_response.enq(DMem_core_response{word:?, trap: False,
                              cause: ?, epochs: ff_core_request.first.epochs});
      end
      else begin
        rg_fence_way <= lv_next_way;
        rg_fence_set <= truncate(lv_next_set);
      end
    endrule

    /*doc:rule: This rule checks the tag rams for a hit*/
    rule rl_ram_check(!ff_core_request.first.fence && !rg_handling_miss && !rg_performing_replay
                      && !fb_full);
      let req = ff_core_request.first;
      // select the physical address and check for any faults
    `ifdef supervisor
      let pa_response = ff_from_tlb.first;
      Bit#(paddr) phyaddr = pa_response.address;
      Bool lv_access_fault = pa_response.trap;
      Bit#(`causesize) lv_cause = lv_access_fault? pa_response.cause:
                                  req.access == 0?`Load_access_fault:`Store_access_fault;
    `else
      Bit#(TSub#(vaddr,paddr)) upper_bits=truncateLSB(req.address);
      Bit#(paddr) phyaddr = truncate(req.address);
      Bool lv_access_fault = unpack(|upper_bits);
      Bit#(`causesize) lv_cause = req.access == 0?`Load_access_fault:`Store_access_fault;
    `endif

      Bit#(TAdd#(3,TAdd#(wordbits,blockbits)))block_offset={phyaddr[v_blockbits+v_wordbits-1:0],3'b0};
      Bit#(tagbits) request_tag = phyaddr[v_paddr-1:v_paddr-v_tagbits];
      Bit#(setbits) set_index= phyaddr[v_setbits+v_blockbits+v_wordbits-1:v_blockbits+v_wordbits];
      
      Vector#(ways, Bit#(respwidth)) dataword;
      Vector#(ways, Bit#(linewidth)) lines;
      Bit#(ways) hit_tag =0;
      for (Integer i = 0; i< v_ways; i = i + 1) begin
        dataword[i] = truncate(bram_data[i].p1.read_response >> block_offset);
        lines[i] = bram_data[i].p1.read_response;
      end
      for (Integer i = 0; i< v_ways; i = i + 1) begin
        hit_tag[i] = pack(bram_tag[i].p1.read_response == request_tag);
      end
      Bit#(respwidth) response_word=select(dataword, unpack(hit_tag));

      let lv_response = DMem_core_response{word:response_word, trap: lv_access_fault,
                                          cause: lv_cause, epochs: req.epochs};
      wr_ram_response <= lv_response;
      wr_ram_hitway<=truncate(pack(countZerosLSB(hit_tag)));
      wr_ram_hitline<=select(lines,unpack(hit_tag));

      let lv_c_meta = select(readVReg(v_reg_cmeta[set_index]),unpack(hit_tag));
      Bool lv_upgrade_required = fn_upgrade_required(req.access, lv_c_meta.state, lv_c_meta.perm);
      Bool lv_permitted = fn_permissions_avail(req.access, lv_c_meta.perm);
      wr_ram_permission_upgrade <= lv_upgrade_required;

      // -------- IO checks -----------------//
      if(isNonCacheable(phyaddr, wr_cache_enable)) begin
        if(req.access == 0)
          wr_nc_state <= Miss;
        else
          wr_nc_state <= Hit;
        wr_ram_state <= Miss;
      end
      else begin
        if(lv_access_fault) begin
          wr_ram_state <= Hit;
        end
        else if(|(hit_tag) == 1)begin
          if (lv_permitted)
            wr_ram_state <= Hit;
          else if(lv_upgrade_required)
            wr_ram_state <= Miss;
        end
        else begin // in case of miss from cache
          wr_ram_state <= Miss;
        end
      end

    `ifdef ASSERT
      dynamicAssert(countOnes(hit_tag) <= 1,"DCACHE: More than one way is a hit in the cache");
    `endif
      `logLevel( dcache, 0, $format("DCACHE[%2d]: RAM For Req:",id,(hit_tag),fshow(req)))
      `logLevel( dcache, 0, $format("DCACHE[%2d]: RAM Hit:%b set:%d tag:%h",id,hit_tag,set_index,
                                    request_tag))
      `logLevel( dcache, 0, $format("DCACHE[%2d]: RAM CMETA: ",id,fshow(lv_c_meta)))
    endrule

    /*doc:rule: This rule will check if the requested word is present in the fill-buffer or not*/
    rule rl_fillbuffer_check(!ff_core_request.first.fence);
      let req = ff_core_request.first;
      `logLevel( dcache, 1, $format("DCACHE[%2d]: FB: processing Req: ",id,fshow(req)))
    `ifdef supervisor
      Bit#(paddr) phyaddr = ff_from_tlb.first.address;
    `else
      Bit#(paddr) phyaddr = truncate(req.address);
    `endif
      let lv_io_req = isNonCacheable(phyaddr, wr_cache_enable);
      
      Bit#(TAdd#(tagbits, setbits)) input_tag = truncateLSB(phyaddr);

      Bit#(blockbits) word_index = truncate(phyaddr >> v_wordbits);
      let required_enable = fn_enable(word_index);
      Bit#(`causesize) lv_cause = req.access == 0? `Load_access_fault: `Store_access_fault;
      Bit#(TAdd#(3,TAdd#(wordbits,blockbits)))block_offset =
                                                      {phyaddr[v_blockbits+v_wordbits-1:0],3'b0};
      
      Vector#(fbsize, Bit#(respwidth)) lv_respwords;
      for (Integer i = 0; i<v_fbsize; i = i + 1) begin
        lv_respwords[i] = truncate(v_fb_data[i] >> block_offset);
      end

      Bit#(fbsize) lv_hit = 0;
      for (Integer i = 0; i<v_fbsize; i = i + 1) begin
        lv_hit[i] = pack((truncateLSB(v_fb_addr[i]) == input_tag) && v_fb_valid[i]);
      end
      Bit#(respwidth) lv_response_word = select(lv_respwords, unpack(lv_hit));
      Bit#(1) lv_response_err = select(readVReg(v_fb_err),unpack(lv_hit));
      wr_fb_hitindex <= truncate(pack(countZerosLSB(lv_hit))); 
      let lv_response = DMem_core_response{word:lv_response_word, trap: unpack(lv_response_err),
                                          cause: lv_cause, epochs: req.epochs};
      wr_fb_response <= lv_response;
      let lv_c_meta = select(readVReg(v_fb_cmeta),unpack(lv_hit));
      Bool lv_upgrade_required = fn_upgrade_required(req.access, lv_c_meta.state, lv_c_meta.perm);
      Bool lv_permitted = fn_permissions_avail(req.access, lv_c_meta.perm);
      wr_fb_permission_upgrade <= lv_upgrade_required;
      `logLevel( dcache, 0, $format("DCACHE[%2d]: FB: CMETA:",id,fshow(lv_c_meta),
                                    " lv_p:%b lv_upg:%b",lv_permitted, lv_upgrade_required))
      if(lv_io_req ) begin
        `logLevel( dcache, 1, $format("DCACHE[%2d]: FB: Detected NC Access",id))
        wr_fb_state <= Miss;
      end
      else if(|lv_hit == 1 )begin
        `logLevel( dcache, 1, $format("DCACHE[%2d]: FB: Hit in Line(%b) for Addr:%h",id,lv_hit,phyaddr))
        if (lv_permitted)
          wr_fb_state <= Hit;
        else if(lv_upgrade_required)
          wr_fb_state <= Miss;
      end
      else begin
        wr_fb_state <= Miss;
        `logLevel( dcache, 1, $format("DCACHE[%2d]: FB: Miss",id))
      end      
    endrule

    /*doc:rule: this rule fires when the requested word is either present in the SRAMs or the
     fill-buffer or if there was an error in the request. Since we are re-using the
    ff_write_mem_response fifo to send out cacheable and MMIO ops, it is necessary that we make sure
    that this fifo is not Full before responding back to the core. If it is not empty then the core
    could initiate a commit-store which could get dropped since the method performing the cannot
    fire since the fifo is full and thus the store being dropped.*/
    rule rl_response_to_core(!ff_core_request.first.fence &&
                      ( wr_nc_state == Hit || wr_ram_state == Hit || wr_fb_state == Hit));

      let req = ff_core_request.first;
    `ifdef supervisor
      let pa_response = ff_from_tlb.first;
      Bit#(paddr) phyaddr = pa_response.address;
      ff_from_tlb.deq;
    `else
      Bit#(paddr) phyaddr = truncate(req.address);
    `endif
      Bit#(setbits) set_index= phyaddr[v_setbits+v_blockbits+v_wordbits-1:v_blockbits+v_wordbits];
      DMem_core_response#(respwidth,esize) lv_response;

      let {storemask, storedata} <- storebuffer.mav_check_sb_hit(phyaddr);

      Bit#(3) onehot_hit = {pack(wr_ram_state==Hit), pack(wr_fb_state==Hit), pack(wr_nc_state==Hit)};
    `ifdef ASSERT
      dynamicAssert(countOnes(onehot_hit) == 1, "More than one data structure shows a hit");
    `endif
      Vector#(3, DMem_core_response#(respwidth,esize)) lv_responses;
      lv_responses[0] = wr_nc_response;
      lv_responses[1] = wr_fb_response;
      lv_responses[2] = wr_ram_response;

      lv_response = select(lv_responses,unpack(onehot_hit));

      if(wr_ram_state == Hit) begin
        `logLevel( dcache, 0, $format("DCACHE[%2d]: Response: Hit from SRAM",id))
        if(alg == "PLRU") begin
          replacement.update_set(set_index, wr_ram_hitway);//wr_replace_line); 
          wr_ram_hitset <= tagged Valid set_index;
        end
      end
      if(wr_fb_state == Hit) begin
        `logLevel( dcache, 0, $format("DCACHE[%2d]: Response: Hit from Fillbuffer",id))
      end
      if(wr_nc_state == Hit) begin
        `logLevel( dcache, 0, $format("DCACHE[%2d]: Response: Hit from NC",id))
      end

      lv_response.word = (storemask & storedata) | (~storemask & lv_response.word);
      // capture the sign bit of the response to the core
      Bit#(1) lv_sign =case(req.size[1:0])
          'b00: lv_response.word[7];
          'b01: lv_response.word[15];
          'b10: lv_response.word[31];
          default: truncateLSB(lv_response.word);
        endcase;
      // manipulate the sign based on the request of the core
      lv_sign = lv_sign & ~req.size[2];

      // generate a mask based on the request of the core.
      Bit#(respwidth) mask = case(req.size[1:0])
        'b00: 'hFF;
        'b01: 'hFFFF;
        'b10: 'hFFFFFFFF;
        default: '1;
      endcase;

      // signmask basically has all bits which are zeros in the mask duplicated with the required
      // sign bit. Theese need to be set in the final response to the core and will thus be ORed
      Bit#(respwidth) signmask = ~mask & duplicate(lv_sign);
      lv_response.word = (lv_response.word & mask) | signmask;
      lv_response.word = lv_response.trap?truncateLSB(req.address):lv_response.word;

      ff_core_request.deq;
    `ifdef supervisor
      if(pa_response.tlbmiss)
        ff_hold_request.enq(ff_core_request.first());
      if(req.ptwalk_req && !pa_response.tlbmiss)
        ff_ptw_response.enq(lv_response);
      else
    `endif
      ff_core_response.enq(lv_response);
      rg_handling_miss <= False;

      // -- allocate store-buffer for stores/atomic ops
      if(req.access != 0 && onehot_hit[2]==1) begin
        if(rg_fbhead == fromInteger(v_fbsize-1))
          rg_fbhead <=0;
        else
          rg_fbhead <= rg_fbhead + 1;
        let lv_c_meta = v_reg_cmeta[set_index][wr_ram_hitway];
        v_fb_valid[rg_fbhead] <= True;
        v_fb_addr[rg_fbhead] <= phyaddr;
        v_fb_err[rg_fbhead] <= 0;
        v_fb_cmeta[rg_fbhead] <= lv_c_meta; 
        v_reg_cmeta[set_index][wr_ram_hitway] <= CoherenceMeta{state:Cacheline_state_I,
                            perm: None, acks_expected:0, acks_received:0};
        v_fb_data[rg_fbhead] <=  wr_ram_hitline;
      end
      if(req.access!=0)begin
        Bit#(TLog#(fbsize)) fbindex = wr_fb_state == Hit? wr_fb_hitindex:rg_fbhead;
        storebuffer.ma_allocate_entry(phyaddr,req.data, req.epochs, fbindex, truncate(req.size),
          wr_nc_state == Hit);
        `logLevel( dcache, 0, $format("DCACHE[%2d]: Response: Allocating Store Buffer",id))
        wr_allocating_storebuffer <= True;        
      end
    endrule

    /*doc:rule: This rule fires when the requested word is a miss in both the SRAMs and the
     * Fill-buffer. This rule thereby forwards the requests to the network. IOs by default should
     * be a miss in both the SRAMs and the FB and thus need to be checked only here */
    rule rl_send_memory_request(wr_ram_state == Miss && wr_fb_state == Miss && wr_nc_state == Miss
            && !fb_full &&  !rg_handling_miss && ff_pending_req.notFull 
            && !ff_core_request.first.fence);
      let req = ff_core_request.first;
    `ifdef supervisor
      let pa_response = ff_from_tlb.first;
      Bit#(paddr) phyaddr = pa_response.address;
    `else
      Bit#(paddr) phyaddr = truncate(req.address);
    `endif
      let lv_busbits = valueOf(TLog#(TDiv#(buswidth,8))); // 4
      Bit#(TLog#(TDiv#(linewidth,buswidth))) word_index= truncate(phyaddr>>lv_busbits);
      let lv_io_req = isNonCacheable(phyaddr, wr_cache_enable);
      let burst_len = lv_io_req?0:(v_blocksize/valueOf(TDiv#(buswidth,respwidth)))-1;
      let burst_size = lv_io_req?v_wordbits:valueOf(TLog#(TDiv#(buswidth,8)));
      let shift_amount = valueOf(TLog#(TDiv#(buswidth,8)));
      // allocate a pending req which points to the new fb entry that is allotted.
      Bit#(setbits) set_index= phyaddr[v_setbits+v_blockbits+v_wordbits-1:v_blockbits+v_wordbits];
      Bit#(tagbits) tag = truncateLSB(phyaddr);
      Bit#(paddr) lv_line_addr = {tag, set_index, 'd0};
      let lv_ram_cmeta = v_reg_cmeta[set_index][wr_ram_hitway];
      let lv_fb_cmeta = v_fb_cmeta[wr_fb_hitindex];
      Cacheline_state lv_curr_state = wr_ram_permission_upgrade? lv_ram_cmeta.state:
                                      wr_fb_permission_upgrade ? lv_fb_cmeta.state:
                                      Cacheline_state_I;
      Access lv_perm = wr_ram_permission_upgrade? lv_ram_cmeta.perm:
                       wr_fb_permission_upgrade ? lv_fb_cmeta.perm: None;
      let _t = ENTRY_Cacheline_state{state:lv_curr_state, perm:lv_perm, cl:wr_ram_hitline, 
                                   acksReceived:0, acksExpected:0, id: tagged Caches truncate(id)};

      let {cacheline, message} = func_frm_core(_t, lv_line_addr, unpack(req.access));
      if(lv_io_req && req.access == 0) begin
        ff_io_req_to_fabric.enq(NCAccess{addr: phyaddr, data:?, read_write:False, 
          size:req.size[1:0]});
        `logLevel( dcache, 0, $format("DCACHE[%2d]: Sending IO Read Request",id))
      end
      else if(message matches tagged Valid .m) begin
        ff_req_to_fabric.enq(m);
        `logLevel( dcache, 0, $format("DCACHE[%2d]: Sending Coherent Req:",id,fshow(m)))
      end
      rg_handling_miss <= True;
      Bit#(TLog#(fbsize)) lv_alotted_fb = (!wr_ram_permission_upgrade && wr_fb_permission_upgrade)?
                      wr_fb_hitindex: rg_fbhead;

      // -- allocate a new entry in the fillbuffer
      if(!lv_io_req) begin

        if(!wr_fb_permission_upgrade)
          if(rg_fbhead == fromInteger(v_fbsize-1))
            rg_fbhead <=0;
          else
            rg_fbhead <= rg_fbhead + 1;
        
        v_fb_valid[lv_alotted_fb] <= True;
        v_fb_addr[lv_alotted_fb] <= phyaddr;
        v_fb_err[lv_alotted_fb] <= 0;
        v_fb_cmeta[lv_alotted_fb] <= CoherenceMeta{state: cacheline.state, perm:cacheline.perm,
                  acks_expected:cacheline.acksExpected, acks_received:cacheline.acksReceived};
        if(wr_ram_permission_upgrade) begin
          v_reg_cmeta[set_index][wr_ram_hitway] <= CoherenceMeta{state:Cacheline_state_I,
                            perm: None, acks_expected:0, acks_received:0};
        end
        `logLevel( dcache, 0, $format("DCACHE[%2d]: MemReq: Allocating Fbindex:%d",id, lv_alotted_fb))
      end
      let pend_req = Pending_req{phyaddr: phyaddr, init_enable:fn_init_enable(word_index), 
                                io_request: lv_io_req, fbindex: lv_alotted_fb};
      ff_pending_req.enq(pend_req);
      if(lv_io_req) begin
        `logLevel( dcache, 0, $format("DCACHE[%2d]: MemReq: Sending NC Request for Addr:%h",id,phyaddr))
      `ifdef perfmonitors
        if(req.access == 0)
          wr_total_io_reads <= 1;
        if(req.access == 1)
          wr_total_io_writes <= 1;
      `endif
      end
      else begin
      `ifdef perfmonitors
        if(req.access == 0)
          wr_total_read_miss <= 1;
        if(req.access == 1)
          wr_total_write_miss <= 1;
        `ifdef atomic
          if(req.access == 2)
            wr_total_atomic_miss <= 1;
        `endif
      `endif
        `logLevel( dcache, 0, $format("DCACHE[%2d] : MemReq: Sending Line Request for Addr:%h",id, phyaddr))
      end
    endrule

    /*doc:rule: */
    rule rl_fill_from_memory (!rg_ram_cc_update);
      let response = ff_resp_from_fabric.first;
      `logLevel( dcache, 0, $format("DCACHE[%2d]: FILL: Response from Memory:",id,fshow(response)))
      Bit#(setbits) set_index = response.address[v_setbits + v_blockbits + v_wordbits - 1 :
                                                                         v_blockbits + v_wordbits];

      Bit#(TAdd#(tagbits,setbits)) inmsg_addr = truncateLSB(response.address);
      let pending_req = ff_pending_req.first;
      function Bool _pred(Bit#(paddr) addr);
        return (inmsg_addr == truncateLSB(addr));
      endfunction

      let _fbindex = findIndex(_pred,readVReg(v_fb_addr));
      Bool fbhit = isValid(_fbindex);
      let fbindex = fromMaybe(?,_fbindex);
      let lv_c_meta = v_fb_cmeta[fbindex];
      if(response.address == pending_req.phyaddr && ff_pending_req.notEmpty &&
                                                                    pending_req.io_request) begin
        let lv_response = DMem_core_response{word:truncate(response.cl), trap: False,
                                            cause: ?, epochs: ?};
        wr_nc_response <= lv_response;
        wr_nc_state <= Hit;
        ff_resp_from_fabric.deq;
      end
      else if(fbhit) begin
        let lv_cle = ENTRY_Cacheline_state{state: lv_c_meta.state,
                                           perm   : lv_c_meta.perm,
                                           cl: v_fb_data[fbindex],
                                           acksReceived: lv_c_meta.acks_received,
                                           acksExpected: lv_c_meta.acks_expected,
                                           id: tagged Caches truncate(id)
                                         };
        let lv_update  = func_Cacheline_state(response, lv_cle);
        let new_cle = lv_update.new_cle;
        if(!lv_update.stall) begin
          ff_resp_from_fabric.deq;
          if(lv_update.send_resp1 matches tagged Valid .m)
            ff_resp_to_fabric.enq(m);
          if(lv_update.send_resp2 matches tagged Valid .m)
            ff_resp2_to_fabric.enq(m);
          v_fb_err[fbindex] <= 0;
          v_fb_data[fbindex] <=  response.cl;
          v_fb_cmeta[fbindex] <= CoherenceMeta{state: new_cle.state, perm: new_cle.perm,
                           acks_expected:new_cle.acksExpected, acks_received:new_cle.acksReceived};
          `logLevel( dcache, 0, $format("DCACHE[%2d]: FILL: fbindex:%d NewCLE: ",id,fbindex,
                                      fshow(new_cle)))
        end
        else begin
          `logLevel( dcache, 0, $format("DCACHE[%2d]: FILL: Stalling:",id,fshow(lv_update)))
        end
      end
      else begin // need to access ram structures
        for(Integer i=0;i<v_ways;i=i+1)begin
          bram_data[i].p2.request(0,set_index,writedata);
          bram_tag[i].p2.request(0,set_index,writetag);
        end
        rg_ram_cc_update <= True;
        `logLevel( dcache, 0, $format("DCACHE[%2d]: FILL: Indexing RAMS set:%d",id,set_index))
      end
      if(inmsg_addr == truncateLSB(pending_req.phyaddr) && ff_pending_req.notEmpty) begin
        ff_pending_req.deq;
        `logLevel( dcache, 0, $format("DCACHE[%2d]: FILL: Dequeing pending_req",id))
      end
      if(rg_release_readphase)
        rg_release_readphase <= False;
    endrule
    rule rl_update_ram(rg_ram_cc_update);
      let response = ff_resp_from_fabric.first;
      let phyaddr = response.address;
      Bit#(TAdd#(3,TAdd#(wordbits,blockbits)))block_offset={phyaddr[v_blockbits+v_wordbits-1:0],3'b0};
      Bit#(tagbits) request_tag = phyaddr[v_paddr-1:v_paddr-v_tagbits];
      Bit#(setbits) set_index= phyaddr[v_setbits+v_blockbits+v_wordbits-1:v_blockbits+v_wordbits];
      Vector#(ways, Bit#(linewidth)) lines;
      Bit#(ways) hit_tag =0;
      for (Integer i = 0; i< v_ways; i = i + 1) begin
        lines[i] = bram_data[i].p2.read_response;
      end
      for (Integer i = 0; i< v_ways; i = i + 1) begin
        hit_tag[i] = pack(bram_tag[i].p2.read_response == request_tag);
      end
      let lv_c_meta = select(readVReg(v_reg_cmeta[set_index]),unpack(hit_tag));
      `logLevel( dcache, 0, $format("DCACHE[%2d]: UPDRAM: hit_tag:%b curr_cle:",id,hit_tag,
        fshow(lv_c_meta)))
      ENTRY_Cacheline_state#(TMul#(wordsize,blocksize)) lv_cle = ENTRY_Cacheline_state{
                          state: lv_c_meta.state,
                          perm: lv_c_meta.perm,
                          cl: select(lines,unpack(hit_tag)),
                          acksReceived: lv_c_meta.acks_received,
                          acksExpected: lv_c_meta.acks_expected,
                          id: tagged Caches truncate(id)
                        };
      let lv_update  = func_Cacheline_state(response, lv_cle);
      let new_cle = lv_update.new_cle;
      if(!lv_update.stall) begin
        ff_resp_from_fabric.deq;
        if(lv_update.send_resp1 matches tagged Valid .m)
          ff_resp_to_fabric.enq(m);
        if(lv_update.send_resp2 matches tagged Valid .m)
          ff_resp2_to_fabric.enq(m);
        Bit#(TLog#(ways)) lv_ram_hitway =truncate(pack(countZerosLSB(hit_tag)));
        `logLevel( dcache, 0, $format("DCACHE[%2d]: CCUPD: OldCLE:",id,fshow(lv_cle)))
        `logLevel( dcache, 0, $format("DCACHE[%2d]: CCUPD: NewCLE:",id,fshow(new_cle)))
        if(|hit_tag == 1)
          v_reg_cmeta[set_index][lv_ram_hitway] <= CoherenceMeta{state:new_cle.state,
                 perm: new_cle.perm, acks_expected:new_cle.acksExpected,
                 acks_received:new_cle.acksReceived};
      end
      else begin
        `logLevel( dcache, 0, $format("DCACHE[%2d]: CCUPD: Stalling:",id,fshow(lv_update)))
      end
    endrule
    /*doc:rule: 
    This rule will evict an entry from the fill - buffer and update it in the cache RAMS.
    Multiple conditions under which this rule can fire:
    1. when the FB is full
    2. when the core is not requesting anything in a particular cycle and there exists a valid
       filled entry in the FB
    3. The rule will not fire when the entry being evicted is a line that has been recently
    requested by the core (present in the ff_core_request). Writing this line would cause a
    replay of the latest request. This would cause another cycle delay which would eventually be
    a hit in the cache RAMS.
    4. If while filling the RAM, it is found that the line being filled is dirty then a read
    request for that line is sent. In the next cycle the read line is sent to memory and the line
    from the FB is written into the RAM. Also in the next cycle a read - request for the latest
    read from the core is replayed again.
    5. If the line being filled in the RAM is not dirty, then the FB line simply ovrwrites the
    line in one = cycle. The latest request from the core is replayed if the replacement was to
    the same index.*/
    rule rl_release_from_fillbuffer((fb_full || rg_fence_stall) && sb_empty && !fb_empty
            && !wr_allocating_storebuffer  && !rg_performing_replay && fb_stable && !rg_ram_cc_update);
      
      let addr = v_fb_addr[rg_fbtail];
      Bit#(setbits) set_index = addr[v_setbits + v_blockbits + v_wordbits - 1 :
                                                                         v_blockbits + v_wordbits];

      Bit#(ways) lv_valid=?, lv_dirty=?;
      for (Integer i = 0; i<v_ways; i = i + 1) begin
        lv_valid[i] = pack(v_reg_cmeta[set_index][i].state != Cacheline_state_I);
        lv_dirty[i] = pack(v_reg_cmeta[set_index][i].state != Cacheline_state_I);
      end
      let waynum <- replacement.line_replace(set_index, lv_valid, lv_dirty);
      `logLevel( dcache, 0, $format("DCACHE[%2d]: Release rule firing. Addr:%h way:%d set:%d",id,
                  addr, waynum, set_index))
      
      if(v_reg_cmeta[set_index][waynum].state == Cacheline_state_I) begin
        let lv_fb_cmeta = v_fb_cmeta[rg_fbtail];
        v_reg_cmeta[set_index][waynum] <= CoherenceMeta{state:lv_fb_cmeta.state,
                                        perm: lv_fb_cmeta.perm, acks_expected:0, acks_received:0};
        bram_tag[waynum].p1.request(1,set_index,writetag);
        bram_data[waynum].p1.request(1,set_index,writedata);
        if(rg_fbtail == fromInteger(v_fbsize-1))
          rg_fbtail <=0;
        else
          rg_fbtail <= rg_fbtail + 1;
        v_fb_valid[rg_fbtail]<=False;
        v_fb_cmeta[rg_fbtail]<= CoherenceMeta{state:Cacheline_state_I, perm:None,
                          acks_expected:0, acks_received:0};
        if(&lv_valid == 1) begin
          if(alg != "PLRU" )
            replacement.update_set(set_index,waynum);
          else begin
            if(wr_ram_hitset matches tagged Valid .i &&& i == set_index) begin
            end
            else
              replacement.update_set(set_index,waynum);
          end
        end
        `logLevel( dcache, 0, $format("DCACHE[%2d]: Release: Writing: set:%d tag:%h way:%d",id,
                                      set_index,writetag,waynum, fshow(lv_fb_cmeta)))
        if(rg_replay_required || set_index == rg_recent_req) begin
          rg_performing_replay <= True;
          `logLevel( dcache, 0, $format("DCACHE[%2d]: Release initiating Replay",id))
          rg_replay_required <= False;
        end
        rg_release_readphase <= False;
      end
      else if(!rg_release_readphase) begin
        bram_tag[waynum].p1.request(0,set_index,writetag);
        bram_data[waynum].p1.request(0,set_index,writedata);
        rg_release_readphase <= True;
        rg_replay_required <= True;
          `logLevel( dcache, 0, $format("DCACHE[%2d]: Release: Reading dirty set:%d way:%d",id,
                                      set_index,waynum))
      end 
      else if(rg_release_readphase && fn_is_stable(v_reg_cmeta[set_index][waynum].state)) begin
        Bit#(TSub#(paddr,TAdd#(tagbits,setbits))) zeros = 0;
        let tag = bram_tag[waynum].p1.read_response;
        let data = bram_data[waynum].p1.read_response;
        Bit#(paddr) lv_evict_address = {tag,set_index,zeros};
        let lv_c_meta   = v_reg_cmeta[set_index][waynum];
        let _t = ENTRY_Cacheline_state{state:lv_c_meta.state, perm:lv_c_meta.perm, 
          cl:data, acksReceived:lv_c_meta.acks_received, acksExpected:lv_c_meta.acks_expected, 
          id: tagged Caches truncate(id)};
        let {cacheline, message} = func_frm_core(_t, lv_evict_address, Evict);
        if(message matches tagged Valid .m)
            ff_req_to_fabric.enq(m);
        v_reg_cmeta[set_index][waynum] <= CoherenceMeta{state:cacheline.state, 
                                        perm: cacheline.perm, acks_expected:cacheline.acksExpected,
                                        acks_received:cacheline.acksReceived};
        `logLevel( dcache, 0, $format("DCACHE[%2d]: Release evict_address:%h",id,lv_evict_address))
        `logLevel( dcache, 0, $format("DCACHE[%2d]: Release: OldCLE:",id,fshow(_t)))
        `logLevel( dcache, 0, $format("DCACHE[%2d]: Release: NewCLE:",id,fshow(cacheline)))
      end
    endrule
    /*doc:rule: */
    rule rl_perform_replay(rg_performing_replay);
      for (Integer i = 0; i<v_ways; i = i + 1) begin
        bram_tag[i].p1.request(0,rg_recent_req,writetag);
        bram_data[i].p1.request(0,rg_recent_req,writedata);
      end
      rg_performing_replay <= False;
      `logLevel( dcache, 0, $format("DCACHE[%2d]: Replaying Req. Index:%d",id,rg_recent_req))
    endrule

    interface core_req=interface Put
      method Action put(DCache_core_request#(vaddr,respwidth,esize) req)if( ff_core_response.notFull &&
                            !rg_fence_stall && !fb_full && !rg_performing_replay);
      `ifdef perfmonitors
          if(req.access == 0)
            wr_total_read_access <= 1;
          if(req.access == 1)
            wr_total_write_access <= 1;
        `ifdef atomic
          if(req.access == 2)
            wr_total_atomic_access <= 1;
        `endif
      `endif
        Bit#(paddr) phyaddr = truncate(req.address);
        Bit#(setbits) set_index=req.fence?0:phyaddr[v_setbits+v_blockbits+v_wordbits-1:v_blockbits+v_wordbits];
        ff_core_request.enq(req);
        rg_fence_stall<=req.fence;
        rg_recent_req <= set_index;
        for(Integer i=0;i<v_ways;i=i+1)begin
          bram_data[i].p1.request(0,set_index,writedata);
          bram_tag[i].p1.request(0,set_index,writetag);
        end
        `logLevel( dcache, 0, $format("DCACHE[%2d]: Receiving request: ",id,fshow(req)))
        `logLevel( dcache, 0, $format("DCACHE[%2d]: set:%d",id,set_index))
      endmethod
    endinterface;
    method Action ma_cache_enable(Bool c);
      wr_cache_enable <= c;
    endmethod

    interface core_resp = toGet(ff_core_response);
    interface mv_request_to_fabric = toGet(ff_req_to_fabric);
    interface mv_io_request_to_fabric = toGet(ff_io_req_to_fabric);
    interface mv_response_to_fabric = toGet(ff_resp_to_fabric);
    interface mv_response2_to_fabric = toGet(ff_resp2_to_fabric);
    interface mv_response_from_fabric = toPut(ff_resp_from_fabric);
  `ifdef supervisor
    interface ptw_resp = toGet(ff_ptw_response);
    interface mav_pa_from_tlb = toPut(ff_from_tlb);
    interface hold_req = toGet(ff_hold_request);
  `endif
    `ifdef perfmonitors
      method perf_counters = {wr_total_read_access , wr_total_write_access , wr_total_atomic_access 
                            , wr_total_io_reads , wr_total_io_writes , wr_total_read_miss , 
                              wr_total_write_miss , wr_total_atomic_miss , wr_total_evictions };
    `endif
    method mv_storebuffer_empty = storebuffer.mv_sb_empty;
    method mv_cacheable_store = storebuffer.mv_cacheable_store;
    method mv_cache_available = ff_core_response.notFull && ff_core_request.notFull && 
        !rg_fence_stall && !fb_full && !rg_performing_replay && !sb_full;
            
    method Action ma_perform_store(Bit#(esize) currepoch);
      let {sb_valid, sb_entry} <- storebuffer.mav_store_to_commit; 
      Bit#(TDiv#(linewidth,8)) mask = sb_entry.size[1 : 0] == 0?'b1 :
                                      sb_entry.size[1 : 0] == 1?'b11 :
                                      sb_entry.size[1 : 0] == 2?'b1111 : '1;

      Bit#(TAdd#(wordbits, blockbits)) block_offset=
                                    {sb_entry.addr[v_blockbits + v_wordbits - 1:0]};
      mask = mask<<block_offset;
      `logLevel( dcache, 0, $format("DCACHE[%2d]: Commit Store entry:",id,fshow(sb_entry)))
      `logLevel( dcache, 0, $format("DCACHE[%2d]: BE:%h blockoffset:%d",id,mask,block_offset))
      if(sb_entry.epoch == currepoch) begin
        if(sb_entry.io) begin
          `logLevel( dcache, 0, $format("DCACHE[%2d]: Store to NC Addr:%h",id,sb_entry.addr))
          ff_io_req_to_fabric.enq(NCAccess{addr: sb_entry.addr, data:sb_entry.data, 
            size: sb_entry.size[1:0], read_write: True});
        end
        else begin
          if(ff_pending_req.notEmpty && ff_pending_req.first.fbindex == sb_entry.fbindex)begin
            `logLevel( dcache, 0, $format("DCACHE[%2d]: Store to Pending line",id))
            wr_store_be<= mask;
            wr_store_data <= duplicate(sb_entry.data);
          end
          else begin
            `logLevel( dcache, 0, $format("DCACHE[%2d]: Store to Available line",id))
            v_fb_data[sb_entry.fbindex] <= updateDataWithMask(v_fb_data[sb_entry.fbindex],
                                                              duplicate(sb_entry.data), mask);
          end
          rg_globaldirty <= True;
        end
      end
      else begin
        `logLevel( dcache, 0, $format("DCACHE[%2d]: Store is being dropped- epoch mismatch",id)) 
      end

    endmethod
    method mv_commit_store_ready = ff_req_to_fabric.notFull;
  endmodule
endpackage

