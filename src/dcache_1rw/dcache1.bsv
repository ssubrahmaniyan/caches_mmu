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
package dcache1;
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


  `include "dcache.defines"
  import dcache_types :: * ;
  import dcache_lib :: * ;
  import replacement_dcache :: * ;
  import mem_config :: * ;
  import dcache_storebuffer :: * ;
  import common_tlb_types:: * ;

  import io_func :: * ;
 
  `define respwidth `vaddr
  `define linewidth TMul#(`dblocks, TMul#(`dwords,8))
  `define setbits TLog#(`dsets)
  `define blockbits TLog#(`dblocks)
  `define wordbits TLog#(`dwords)
  `define tagbits TSub#(`paddr, TAdd#(TAdd#(`wordbits, `blockbits),`setbits))

  typedef struct{
    Bit#(besize) init_enable;
    Bit#(TLog#(fbsize)) fbindex;
    Bool io_request;
  } Pending_req#(numeric type besize, numeric type fbsize)
                deriving(Bits, Eq, FShow);

  (*noinline*)
  /*doc:func: This function carries out the atomic operations based on the RISC-V ISA spec*/
  function Bit#(`respwidth) fn_atomic_op (Bit#(5) op,  Bit#(`respwidth) rs2,  Bit#(`respwidth) loaded);
    Bit#(`respwidth) op1 = loaded;
    Bit#(`respwidth) op2 = rs2;
    if(op[4]==0)begin
			op1=signExtend(loaded[31:0]);
      op2= signExtend(rs2[31:0]);
    end
    Int#(`respwidth) s_op1 = unpack(op1);
		Int#(`respwidth) s_op2 = unpack(op2);

    case (op[3:0])
				'b0011:return op2;
				'b0000:return (op1+op2);
				'b0010:return (op1^op2);
				'b0110:return (op1&op2);
				'b0100:return (op1|op2);
				'b1100:return min(op1,op2);
				'b1110:return max(op1,op2);
				'b1000:return pack(min(s_op1,s_op2));
				'b1010:return pack(max(s_op1,s_op2));
				default:return op1;
			endcase
  endfunction

  interface Ifc_dcache;
    interface Put#(DCache_core_request#(`vaddr,TMul#(`dwords,8),`desize)) put_core_req;
    interface Get#(DMem_core_response#(TMul#(`dwords,8),`desize)) get_core_resp;
    interface Get#(DCache_mem_readreq#(`paddr)) get_read_mem_req;
    interface Put#(DCache_mem_readresp#(`dbuswidth)) put_read_mem_resp;
    method DCache_mem_writereq#(`paddr, TMul#(`dblocks, TMul#(`dwords, 8))) mv_write_mem_req;
    method Action ma_write_mem_req_deq;
    interface Put#(DCache_mem_writeresp) put_write_mem_resp;
  `ifdef supervisor
    interface Get#(DMem_core_response#(TMul#(`dwords,8),`desize)) get_ptw_resp;
    interface Put#(DTLB_core_response#(`paddr)) put_pa_from_tlb;
    interface Get#(DCache_core_request#(`vaddr, TMul#(`dwords, 8), `desize)) get_hold_req;
  `endif
  `ifdef perfmonitors
    method Bit#(13) mv_perf_counters;
  `endif
    method Action ma_cache_enable(Bool c);
    method Bool mv_storebuffer_empty;
    method Action ma_perform_store(Bit#(`desize) currepoch);
    method Bool mv_cacheable_store;
    method Bool mv_cache_available;
    method Bool mv_commit_store_ready;
  `ifdef dcache_ecc
    method Maybe#(ECC_dcache_data_ded#(`paddr, `dways, `ddbanks)) mv_ded_data;
    method Maybe#(ECC_dcache_tag_ded#(`paddr, `dways)) mv_ded_tag;
  `endif
  endinterface
  module mkdcache#( parameter Bit#(32) id, 
                    parameter Bool param_onehot)
                    (Ifc_dcache);

    String dcache = "";
    let v_sets=valueOf(`dsets);
    let v_setbits=valueOf(`setbits);
    let v_wordbits=valueOf(`wordbits);
    let v_blockbits=valueOf(`blockbits);
    let v_linewidth=valueOf(`linewidth);
    let v_paddr=valueOf(`paddr);
    let v_ways=valueOf(`dways);
    let v_wordsize=valueOf(`dwords);
    let v_blocksize=valueOf(`dblocks);
    let v_respwidth=valueOf(`respwidth);
    let v_fbsize = valueOf(`dfbsize);
    let v_dbanks = valueOf(`ddbanks);
    let m_data <- mkinst_data;
    let m_tag <- mkinst_tag;
    let m_fillbuffer <- mkinst_fb_v2;
    // ----------------------- FIFOs to interact with interface of the design -------------------//
    /*doc:fifo: This fifo stores the request from the core.*/
    FIFOF#(DCache_core_request#(`vaddr, `respwidth, `desize)) ff_core_request <- mkSizedFIFOF(2);
    /*doc:fifo: This fifo stores the response that needs to be sent back to the core.*/
    FIFOF#(DMem_core_response#(`respwidth,`desize))ff_core_response <- mkBypassFIFOF();
  `ifdef supervisor
    /*doc:fifo: This fifo stores the response that needs to be sent back to the ptw.*/
    FIFOF#(DMem_core_response#(`respwidth,`desize))ff_ptw_response <- mkBypassFIFOF();
  `endif
    /*doc:fifo: this fifo stores the read request that needs to be sent to the next memory level.*/
    FIFOF#(DCache_mem_readreq#(`paddr)) ff_read_mem_request <- mkSizedFIFOF(2);
    /*doc:fifo: This fifo stores the response from the next level memory.*/
    FIFOF#(DCache_mem_readresp#(`dbuswidth)) ff_read_mem_response  <- mkBypassFIFOF();
    /*doc:fifo: this fifo stores the eviction request to be written back*/
    FIFOF#(DCache_mem_writereq#(`paddr, `linewidth)) ff_write_mem_request <- mkSizedFIFOF(1);
    /*doc:fifo: this fifo stores the write response from an eviction or a io write req*/
    FIFOF#(DCache_mem_writeresp) ff_write_mem_response  <- mkBypassFIFOF();
    /*doc:fifo: this fifo holds the request from core when there has been a tlbmiss */
    FIFOF#(DCache_core_request#(`vaddr, `respwidth, `desize)) ff_hold_request <- mkBypassFIFOF();

  `ifdef supervisor
    /*doc:fifo: this fifo receives the physical address from the TLB */
    FIFOF#(DTLB_core_response#(`paddr)) ff_from_tlb <- mkBypassFIFOF();
  `endif

    // ------------------------ FIFOs for internal state-maintenance ---------------------------//
    /*doc:fifo: This fifo holds meta information of the miss/io request that was made by the core*/
    FIFOF#(Pending_req#(TDiv#(`linewidth,8), `dfbsize )) ff_pending_req <- mkUGSizedFIFOF(2);
    
    // -------------------- Register declarations ----------------------------------------------//

    /*doc:reg: register when True indicates a fence is in progress and thus will prevent taking any
     new requests from the core*/
    Reg#(Bool) rg_fence_stall <- mkReg(False);

    /*doc:reg: When tru indicates that a miss is being catered to*/
    Reg#(Bool) rg_handling_miss <- mkReg(False);

    /*doc:reg: */
    Reg#(Bit#(1)) rg_wEpoch <- mkReg(0);
    
    /*doc:reg: this register indicates the read-phase of the release sequence*/
    Reg#(Bool) rg_release_readphase <- mkDReg(False);

    /*doc:reg: This register indicates that the bram inputs are being re-driven by those provided
    from the core in the most recent request. This happens because as the release from the
    fillbuffer happens it is possible that a dirty ways needs to be read out. This will change the
    output of the brams as compared to what the core requested. Thus the core request needs to be
    replayed on these again */
    Reg#(Bool) rg_performing_replay <- mkReg(False);

    /*doc:reg: this register holds the index of the most recent request performed by the core*/
    Reg#(Bit#(`setbits)) rg_recent_req <- mkReg(0);

    /*doc:reg: this register indicates that the line corresponding to the current request to the
    core is already persent however, the necessary is not present. This doesn't generate a miss
    and thus rg_miss_handling cannot be used here. Hence the need for this register*/
    Reg#(Bool) rg_polling_mode <- mkReg(False);

    /*doc:reg: this register selects the way for performing a fence operation */
    Reg#(Bit#(TLog#(`dways))) rg_fence_way <- mkReg(0);

    /*doc:reg: this register selects the set for performing a fence operation */
    Reg#(Bit#(TLog#(`dsets))) rg_fence_set <- mkReg(0);

    /*doc:reg: this register when true indicates that a fence operation has caused a writeback to
     the memory and the response has not been received yet.*/
    Reg#(Bool) rg_fence_pending <- mkReg(False);

    /*doc:reg: This register when true indicates that a there exists alteast one dirty line within
     the data cache */
    Reg#(Bool) rg_globaldirty <- mkReg(False);

    // -------------------- Wire declarations ----------------------------------------------//
    /*doc:wire: boolean wire indicating if the cache is enabled. This is controlled through a csr*/
    Wire#(Bool) wr_cache_enable<-mkWire();
    /*doc:wire: this wire indicates if there was a fault in the address or during translation*/
    Wire#(Bool) wr_fault <- mkDWire(False);
    /*doc:wire: this wire indicates if there was a hit or miss on SRAMs.*/
    Wire#(RespState) wr_ram_state <- mkDWire(None);
    /*doc:wire: this wire holds the response from the RAM in case of a hit in the RAMs*/
    Wire#(DMem_core_response#(`respwidth,`desize)) wr_ram_response <- mkDWire(?);
    /*doc:wire: in case of a hit in the ram, this wire holds the information of which way was a hit.
    This is used for replacement purposes only.*/
    Wire#(Bit#(TLog#(`dways))) wr_ram_hitway <-mkDWire(0);
    /*doc:wire: in case of a store-hit in the RAM, the hit line needs to be transfered to the FB.
    This wire holds that hit line*/
    Wire#(Bit#(`linewidth)) wr_ram_hitline <- mkDWire(?);
    /*doc:wire in case of a hit in the rams, the wire holds the holds the value of the set which
    caused a hit. This is necessary since an eviction from the same set should not affect the
    replacement policy if a hit to the same set has occurred in the same cycle */
    Wire#(Maybe#(Bit#(`setbits))) wr_ram_hitset <- mkDWire(tagged Invalid);

    /*doc:wire: this wire indicates if there was a hit or miss on Fllbuffer.*/
    Wire#(RespState) wr_fb_state <- mkDWire(None);

    /*doc:wire: this wire holds the response data structure in case of a hit from fill-buffers*/
    Wire#(DMem_core_response#(`respwidth,`desize)) wr_fb_response <- mkDWire(?);

    /*doc:wire: this wire indicates if the current request is non-cacheable*/
    Wire#(RespState) wr_nc_state <- mkDWire(None);

    /*doc:wire: this wire holds the response data structure in case of a Non-cacheable access*/
    Wire#(DMem_core_response#(`respwidth,`desize)) wr_nc_response <- mkDWire(?);
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
    /*doc:wire: wire to pulse on every release from fill-buffer to RAMS*/
    Wire#(Bit#(1)) wr_total_fb_releases <- mkDWire(0);
    /*doc:wire: wire to pulse on every hit in fill-buffer for atomic ops*/
    Wire#(Bit#(1)) wr_total_atomic_fb_hits <- mkDWire(0);
    /*doc:wire: wire to pulse on  hit in fill-buffer for read ops*/
    Wire#(Bit#(1)) wr_total_read_fb_hits <- mkDWire(0);
    /*doc:wire: wire to pulse on  hit in fill-buffer for write ops*/
    Wire#(Bit#(1)) wr_total_write_fb_hits <- mkDWire(0);
  `endif
    Wire#(Bool) wr_takingrequest <- mkDWire(False);
    /*doc:wire: boolean wire indicating that a store is under progress*/
    Wire#(Bool) wr_store_in_progress <- mkDWire(False);
    // ----------------------- Storage elements -------------------------------------------//
    /*doc:reg: This is an array of the valid bits. Each entry corresponds to a set and contains
    'way' number of bits in each entry*/
    Vector#(`dsets, Reg#(Bit#(`dways))) v_reg_valid <- replicateM(mkReg(0));

    /*doc:reg: This is an array of the dirty bits. Each entry corresponds to a set and contains
    'way' number of bits in each entry*/
    Vector#(`dsets, Reg#(Bit#(`dways))) v_reg_dirty <- replicateM(mkReg(0));

    Ifc_replace#(`dsets,`dways) replacement <- mkreplace(`drepl);
    // --------------------- Store buffer related structures ----------------------------------//
    Ifc_storebuffer#(`paddr, `dwords, `desize, `dsbsize, `dfbsize) storebuffer <- mk_storebuffer(id);

    /*doc:wire: holds the byte-enables for the store operation being performed*/
    Wire#(Bit#(TDiv#(`linewidth,8))) wr_store_be <- mkDWire(0);

    /*doc:wire: holds the data to be updated in the fill-buffer*/
    Wire#(Bit#(`linewidth)) wr_store_data <- mkDWire(0);

    /*doc:wire: when true indicates that a store-buffer entry is being allocated. This is used to
     ensure that a release of the fill-buffer does not happen.*/
    Wire#(Bool) wr_allocating_storebuffer <- mkDWire(False);

    // --------------------------- Rule operations ------------------------------------- //
    Bool sb_empty = storebuffer.mv_sb_empty;
    Bool sb_full = storebuffer.mv_sb_full;
    Bool fb_full = m_fillbuffer.mv_fbfull;
    Bool fb_empty = m_fillbuffer.mv_fbempty;
    Bool fb_headvalid = m_fillbuffer.mv_fbhead_valid;
    let fb_headaddr = m_fillbuffer.mv_fbhead_address;
    Bit#(`setbits) fillindex = fb_headaddr[v_setbits + v_blockbits + v_wordbits - 1:
                                                                          v_blockbits + v_wordbits];
    /*doc:var: This variable indicates if there is an oppurtunity to perform a release from the
    fill-buffer to the RAMS. This takes advantage of the fact that the cache is idle is not being
    used by the core. The conditions under which an oppurtunity occurs is if all the following
    conditions are met:
      1. there is not core-request pending
      2. The core is not generating any request in the current cycle
      3. Store-buffer is not being allocated in the current cycle
      4. The set being released to is not the most recent set accessed by the core.
    */
    Bool fill_oppurtunity = (!ff_core_request.notEmpty && !wr_takingrequest)  &&
         /*countOnes(fb_valid)>0 &&*/ (fillindex != rg_recent_req) && !wr_store_in_progress;
    
    // --------------------------- Rule operations ------------------------------------- //

    rule rl_fence_operation(rg_fence_stall && fb_empty && sb_empty && !rg_fence_pending 
                                           && !rg_performing_replay) ;
      `logLevel( dcache, 1, $format("[%2d]DCACHE : Fence operation in progress",id))

      let lv_curr_way = rg_fence_way;
      let lv_curr_set = rg_fence_set;

      let lv_next_way = rg_fence_way;
      let lv_next_set = {1'b0,rg_fence_set};

      // done to avoid additional provisos for this combination
      Bit#(TSub#(`paddr, TAdd#(`tagbits, `setbits))) zeros = 'd0;
      Bit#(`dways) _way = 0;
      _way[rg_fence_way] = 1;
      Bit#(`tagbits) tag = truncateLSB(m_tag.mv_read_response(?,rg_fence_way).address);
      Bit#(`linewidth) dataline = m_data.mv_read_response(?,_way).line;
      Bit#(`paddr) final_address={tag, rg_fence_set, zeros};
      Bit#(1) lv_dirty = v_reg_dirty[rg_fence_set][rg_fence_way];
      Bit#(1) lv_valid = v_reg_valid[rg_fence_set][rg_fence_way];
      `logLevel( dcache, 2, $format("[%2d]DCACHE: Fence: CurrWay:%2d CurrSet:%2d Valid:%b \
Dirty:%b Addr:%h Data:%h",id, lv_curr_way,lv_curr_set,lv_valid, lv_dirty, final_address,
dataline ))
      Bool writeback_condition = lv_dirty == 1 && lv_valid == 1;
      if( writeback_condition) begin
        let lv_req = DCache_mem_writereq{address   : final_address,
                                         burst_len  : fromInteger(valueOf(`dblocks) - 1),
                                         burst_size : fromInteger(valueOf(TLog#(`dwords))),
                                         data       : dataline,
                                         io: False
                                          };
        ff_write_mem_request.enq(lv_req);
        `logLevel( dcache, 2, $format("[%2d]DCACHE: Fence: Sending to Memory:",id,fshow(lv_req)))
      end
      if(lv_curr_way == fromInteger(v_ways-1))
        lv_next_set = zeroExtend(lv_curr_set) + 1;

      if(v_ways > 1)
        lv_next_way = lv_curr_way + 1;

      m_tag.ma_request(False, truncate(lv_next_set), ? , ?);
      m_data.ma_request(False, truncate(lv_next_set), ?, ?, '1);

      if((lv_curr_way == fromInteger(v_ways - 1) && lv_next_set== fromInteger(v_sets))
              || !rg_globaldirty) begin
        for (Integer i = 0; i< fromInteger(v_sets); i = i + 1) begin
          v_reg_valid[i] <= 0 ;
          v_reg_dirty[i] <= 0 ;
        end
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
    interface put_core_req=interface Put
      method Action put(DCache_core_request#(`vaddr,`respwidth,`desize) req)
                        if( ff_core_response.notFull && !rg_fence_stall 
                                                     && !fb_full && !rg_performing_replay);
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
        Bit#(`paddr) phyaddr = truncate(req.address);
        Bit#(`setbits) set_index=req.fence?0:phyaddr[v_setbits+v_blockbits+v_wordbits-1:v_blockbits+v_wordbits];
        ff_core_request.enq(req);
        rg_fence_stall<=req.fence;
        rg_recent_req <= set_index;
        m_tag.ma_request(False, set_index, ?, ?);
        m_data.ma_request(False, set_index, ?, ?, '1);
        `logLevel( dcache, 0, $format("[%2d]DCACHE: Receiving request: ",id,fshow(req)))
        `logLevel( dcache, 0, $format("[%2d]DCACHE: set:%d",id,set_index))
        wr_takingrequest <= True;
      endmethod
    endinterface;

    method Action ma_cache_enable(Bool c);
      wr_cache_enable <= c;
    endmethod

    interface get_read_mem_req = toGet(ff_read_mem_request);
    interface put_read_mem_resp = toPut(ff_read_mem_response);
    interface get_core_resp = toGet(ff_core_response);
    method mv_write_mem_req = ff_write_mem_request.first;
    method Action ma_write_mem_req_deq;
      ff_write_mem_request.deq;
    endmethod
    interface put_write_mem_resp = toPut(ff_write_mem_response);
  `ifdef supervisor
    interface get_ptw_resp = toGet(ff_ptw_response);
    interface put_pa_from_tlb = toPut(ff_from_tlb);
    interface get_hold_req = toGet(ff_hold_request);
  `endif
    `ifdef perfmonitors
      method mv_perf_counters = {wr_total_read_access , wr_total_write_access , wr_total_atomic_access
                            , wr_total_io_reads , wr_total_io_writes , wr_total_read_miss ,
                              wr_total_write_miss , wr_total_atomic_miss , wr_total_read_fb_hits,
                              wr_total_write_fb_hits, wr_total_atomic_fb_hits,
                              wr_total_fb_releases, wr_total_evictions };
    `endif
    method mv_storebuffer_empty = storebuffer.mv_sb_empty;
    method mv_cacheable_store = storebuffer.mv_cacheable_store;
    method mv_cache_available = ff_core_response.notFull && ff_core_request.notFull &&
        !rg_fence_stall && !fb_full && !rg_performing_replay && !sb_full;
    method mv_commit_store_ready = ff_write_mem_request.notFull;
  endmodule

  (*synthesize*)
  module mkinst_dcache#(parameter Bit#(32) id)(Ifc_dcache);
    let ifc();
  `ifdef dcache
    mkdcache#(id, unpack(`dcache_onehot)) _temp(ifc);
  `else
    mknull_dcache _temp(ifc);
  `endif
    return (ifc);
  endmodule
endpackage

