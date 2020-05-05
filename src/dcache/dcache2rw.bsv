/* 
see LICENSE.incore
see LICENSE.iitm

Author: Neel Gala
Email id: neelgala@gmail.com
Details:

--------------------------------------------------------------------------------------------------
*/
package dcache2rw;
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
  import UniqueWrappers :: * ;


  `include "dcache.defines"
  import dcache_types :: * ;
  import dcache_lib :: * ;
  import replacement_dcache :: * ;
`ifdef supervisor
  import common_tlb_types:: * ;
`endif
`ifdef dcache_ecc
  import ecc_hamming :: * ;
`endif
`ifdef pmp
  import pmp_func :: *;
`endif


  import io_func :: * ;

  typedef struct{
    Bit#(TLog#(banks)) init_bank;
    Bit#(TLog#(fbsize)) fbindex;
    Bool io_request;
  } Pending_req#(numeric type fbsize, numeric type banks)
                deriving(Bits, Eq, FShow);


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
    method Action ma_curr_priv (Bit#(2) c);
    method Bool mv_storebuffer_empty;
    method Action ma_perform_store(Bit#(`desize) currepoch);
    method Bool mv_cacheable_store;
    method Bool mv_cache_available;
    method Bool mv_commit_store_ready;
  `ifdef dcache_ecc
    method Maybe#(ECC_dcache_data#(`paddr, `dways, `dblocks)) mv_ded_data;
    method Maybe#(ECC_dcache_data#(`paddr, `dways, `dblocks)) mv_sed_data;
    method Maybe#(ECC_dcache_tag#(`paddr, `dways)) mv_ded_tag;
    method Maybe#(ECC_dcache_tag#(`paddr, `dways)) mv_sed_tag;
    method Action ma_ram_request(DRamAccess access);
    method Bit#(`respwidth) mv_ram_response;
  `endif
  endinterface
  // both update rg_handling_miss but can never fire together
  (*conflict_free="rl_send_memory_request, rl_response_to_core"*)
  (*conflict_free="rl_response_to_core,rl_ram_check"*)
  (*conflict_free="rl_send_memory_request,rl_release_from_fillbuffer"*)
  (*conflict_free="rl_fill_from_memory, rl_release_from_fillbuffer"*)
`ifdef dcache_ecc
  (*preempts="ma_ram_request,rl_release_from_fillbuffer"*)
  (*conflict_free="rl_perform_correction, ma_perform_store"*)
`endif
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
  (*synthesize*)
  module mkdcache#( parameter Bit#(32) id
    `ifdef pmp ,
        Vector#(`pmpsize, Bit#(8)) pmp_cfg, 
        Vector#(`pmpsize, Bit#(TSub#(`paddr,`pmp_grainbits))) pmp_addr `endif
    )(Ifc_dcache);

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
    let v_tagbits = valueOf(`tagbits);
    let v_ecc_size = valueOf(`deccsize);

    let m_data <- mkdcache_data(id);
    let m_tag <- mkdcache_tag(id);
    let m_fillbuffer <- mkdcache_fb_v2(id);
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
    FIFOF#(DCache_mem_writereq#(`paddr, `linewidth)) ff_write_mem_request <- mkFIFOF1;
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
    FIFOF#(Pending_req#(`dfbsize, `dblocks)) ff_pending_req <- mkUGSizedFIFOF(2);
    
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

  `ifdef dcache_ecc
    /*doc:reg: register to hold the access request performed by the external CCSU module*/
    Reg#(Maybe#(DRamAccess)) rg_access_req <- mkDReg(tagged Invalid);
    /*doc:reg: */
    Reg#(Bool) rg_perform_sec <- mkReg(False);
    /*doc:reg: */
    Reg#(Bool) rg_halt_ram_check <- mkReg(False);
    /*doc:reg: */
    Reg#(Bit#(TLog#(`dfbsize))) rg_sec_fbindex <- mkReg(0);
    /*doc:reg: */
    Reg#(Bit#(TMul#(`dblocks, `deccsize))) rg_sec_storeparity <- mkReg(0);
    Reg#(Bit#(TMul#(`dblocks, `deccsize))) rg_sec_checkparity <- mkReg(0);
    /*doc:reg: */
    Reg#(Bit#(`paddr)) rg_sec_address <- mkReg(0);

  `endif

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
    /*doc:wire: in case of a hit in fb this wire will hold the index of the fb which was a hit. This
    value is used to indicate the storebuffer which fb entry it needs to update when committing
    the store*/
    Wire#(Bit#(TLog#(`dfbsize))) wr_fb_hitindex <- mkDWire(?);
    /*doc:wire: wire holds the current privilege mode of the core*/
    Wire#(Bit#(2)) wr_priv <- mkWire();

  `ifdef dcache_ecc
    /*doc:wire: */
    Wire#(Bool) wr_ecc_fault <- mkDWire(False);
    /*doc:wire: */
    Wire#(Maybe#(ECC_dcache_tag#(`paddr,`dways))) wr_sed_tag_log <- mkDWire(tagged Invalid);
    /*doc:wire: */
    Wire#(Maybe#(ECC_dcache_tag#(`paddr,`dways))) wr_ded_tag_log <- mkDWire(tagged Invalid);
    /*doc:wire: */
    Wire#(Maybe#(ECC_dcache_data#(`paddr,`dways, `dblocks))) wr_sed_data_log <- mkDWire(tagged Invalid);
    /*doc:wire: */
    Wire#(Maybe#(ECC_dcache_data#(`paddr,`dways, `dblocks))) wr_ded_data_log <- mkDWire(tagged Invalid);
  `endif
    // ----------------------- Storage elements -------------------------------------------//
    /*doc:reg: This is an array of the valid bits. Each entry corresponds to a set and contains
    'way' number of bits in each entry*/
    Vector#(`dsets, Reg#(Bit#(`dways))) v_reg_valid <- replicateM(mkReg(0));

    /*doc:reg: This is an array of the dirty bits. Each entry corresponds to a set and contains
    'way' number of bits in each entry*/
    Vector#(`dsets, Reg#(Bit#(`dways))) v_reg_dirty <- replicateM(mkReg(0));

    Ifc_replace#(`dsets,`dways) replacement <- mkreplace(`drepl);
    // --------------------- Store buffer related structures ----------------------------------//
    Ifc_storebuffer#(`paddr, `dwords, `desize, `dsbsize, `dfbsize) m_storebuffer <- mk_storebuffer(id);

    /*doc:wire: holds the byte-enables for the store operation being performed*/
    Wire#(Bit#(TDiv#(`linewidth,8))) wr_store_be <- mkDWire(0);

    /*doc:wire: holds the data to be updated in the fill-buffer*/
    Wire#(Bit#(`linewidth)) wr_store_data <- mkDWire(0);

    /*doc:wire: when true indicates that a store-buffer entry is being allocated. This is used to
     ensure that a release of the fill-buffer does not happen.*/
    Wire#(Bool) wr_allocating_storebuffer <- mkDWire(False);

  `ifdef dcache_ecc
    Vector#(`dblocks, Wrapper3#(Bit#(`deccsize), Bit#(`deccsize), 
      Bit#(`respwidth), Bit#(`respwidth))) fn_ecc_correct_uw <-
      replicateM(mkUniqueWrapper3(fn_ecc_correct));
  `endif

    // --------------------------- global variables ------------------------------------- //
    Bool sb_empty = m_storebuffer.mv_sb_empty;
    Bool sb_full = m_storebuffer.mv_sb_full;
    Bool fb_full = m_fillbuffer.mv_fbfull;
    Bool fb_empty = m_fillbuffer.mv_fbempty;
    Bool fb_headvalid = m_fillbuffer.mv_fbhead_valid;
    // --------- release information 
    let lv_release_line = m_fillbuffer.mv_release_info.dataline;
    let lv_release_addr = m_fillbuffer.mv_release_info.address;
    let lv_release_err  = m_fillbuffer.mv_release_info.err;
    let lv_release_dirty =m_fillbuffer.mv_release_info.dirty; 

    // --------------------------- Rule operations ------------------------------------- //

    rule rl_fence_operation(ff_core_request.first.fence && rg_fence_stall && fb_empty && 
                            sb_empty && !rg_fence_pending 
 			  `ifdef dcache_ecc && !rg_perform_sec && !rg_halt_ram_check `endif ) ;
      `logLevel( dcache, 1, $format("[%2d]DCACHE : Fence operation in progress",id))

      let lv_curr_way = rg_fence_way;
      let lv_curr_set = rg_fence_set;

      let lv_next_way = rg_fence_way;
      let lv_next_set = {1'b0,rg_fence_set};

      // done to avoid additional provisos for this combination
      Bit#(TSub#(`paddr, TAdd#(`tagbits, `setbits))) zeros = 'd0;
      Bit#(`dways) _way = 0;
      _way[rg_fence_way] = 1;
      let lv_tag_resp <-m_tag.mv_read_response_p1(?,rg_fence_way);
      let lv_data_resp = m_data.mv_read_response_p1(?,_way);
      Bit#(`tagbits) tag = truncateLSB(lv_tag_resp.address);
      Bit#(`linewidth) dataline = lv_data_resp.line;
      Bit#(`paddr) final_address={tag, rg_fence_set, zeros};
    `ifdef dcache_ecc
      Bit#(TMul#(`dblocks,TAdd#(2,TLog#(`respwidth)))) stored_parity = lv_data_resp.stored_parity;
      Bit#(TMul#(`dblocks,TAdd#(2,TLog#(`respwidth)))) check_parity = lv_data_resp.check_parity;
      for (Integer i = 0; i< v_blocksize; i = i + 1) begin
        Bit#(ecc_size) _stparity = stored_parity[i*v_ecc_size+v_ecc_size-1:i*v_ecc_size];
        Bit#(ecc_size) _chparity = check_parity[i*v_ecc_size+v_ecc_size-1:i*v_ecc_size];
        Bit#(`respwidth) _data = dataline[i*v_respwidth+v_respwidth-1:i*v_respwidth];
        _data <- fn_ecc_correct_uw[i].func(_chparity, _stparity, _data);
        dataline[i*v_respwidth+v_respwidth-1:i*v_respwidth] = _data;
      end
      if(|lv_tag_resp.ded == 1)
        wr_ded_tag_log <= tagged Valid ECC_dcache_tag{address: final_address, 
                                                     way: lv_tag_resp.ded & v_reg_valid[rg_fence_set]};

      if (|lv_data_resp.line_ded == 1)
        wr_ded_data_log <= tagged Valid ECC_dcache_data{address: final_address, 
                                                       banks: lv_data_resp.line_ded,
                                                       way : _way};
    `endif
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
        `logLevel( dcache, 2, $format("[%2d]DCACHE: Fence: Evicting to Memory:",id,fshow(lv_req)))
      end
      if(lv_curr_way == fromInteger(v_ways-1))
        lv_next_set = zeroExtend(lv_curr_set) + 1;

      if(v_ways > 1)
        lv_next_way = lv_curr_way + 1;

      m_tag.ma_read_p1(truncate(lv_next_set));
      m_data.ma_read_p1(truncate(lv_next_set), '1);

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
    /*doc:rule: */
    rule rl_deq_write_resp(rg_fence_pending && ff_core_request.first.fence);
      rg_fence_pending <= False;
      let x = ff_write_mem_response.first;
    endrule
    /*doc:rule: whether the write response is for a fence or is for eviction it has to be evicted.
     Hence this has been decoupled from the previous rule - which is meant only for fence*/
    rule rl_deq_write_response;
      ff_write_mem_response.deq;
    endrule

  `ifdef dcache_ecc
    /*doc:rule: */
    rule rl_perform_correction(rg_perform_sec);
      rg_perform_sec <= False; 
      m_fillbuffer.mav_perform_sec(rg_sec_fbindex, rg_sec_storeparity, rg_sec_checkparity);
      rg_halt_ram_check <= True;
      `logLevel( dcache, 0, $format("[%2d]DCACHE: Performing SEC for fbindex:%d",id, rg_sec_fbindex))
    endrule
  `endif
    /*doc:rule: This rule checks the tag rams for a hit*/
    rule rl_ram_check(!ff_core_request.first.fence && !rg_handling_miss  
                      && !rg_polling_mode && !fb_full && !m_storebuffer.mv_sb_busy 
                  `ifdef dcache_ecc && !rg_perform_sec && !rg_halt_ram_check `endif );
      let req = ff_core_request.first;
      // select the physical address and check for any faults
    `ifdef supervisor
      let pa_response = ff_from_tlb.first;
      Bit#(`paddr) phyaddr = pa_response.address;
      Bool lv_access_fault = pa_response.trap || pa_response.tlbmiss;
      Bit#(`causesize) lv_cause = lv_access_fault? pa_response.cause:
                                  req.access == 0?`Load_access_fault:`Store_access_fault;
      `logLevel( dcache, 1, $format("[%2d]DCACHE: Response from PA:",id,fshow(pa_response)))
    `else
      Bit#(TSub#(`vaddr,`paddr)) upper_bits=truncateLSB(req.address);
      Bit#(`paddr) phyaddr = truncate(req.address);
      Bool lv_access_fault = unpack(|upper_bits);
      Bit#(`causesize) lv_cause = req.access == 0?`Load_access_fault:`Store_access_fault;
    `endif
    `ifdef pmp
      Bit#(2) pmp_access = req.access == 0 ? 0 : 1;
      let pmpreq = PMPReq{ address: phyaddr, access_type:pmp_access};
      let {pmp_err, pmp_cause} = fn_pmp_lookup(pmpreq, unpack(wr_priv),
                                              pmp_cfg, pmp_addr);
      if (!lv_access_fault && pmp_err)begin
        lv_access_fault = True;
        lv_cause = pmp_cause;
      end
    `endif
      Bit#(`blockbits) lv_blocknum = phyaddr[v_blockbits+v_wordbits-1:v_wordbits];
      Bit#(`wordbits) word_offset = truncate(phyaddr);
      Bit#(`setbits) set_index= phyaddr[v_setbits+v_blockbits+v_wordbits-1:v_blockbits+v_wordbits];

      let lv_tag_resp <- m_tag.mv_read_response_p1(phyaddr,?);
      Bit#(`dways) lv_hitmask = lv_tag_resp.waymask & v_reg_valid[set_index];
      let lv_data_resp = m_data.mv_read_response_p1(lv_blocknum,lv_hitmask);
      let response_word = lv_data_resp.word >> {word_offset,3'b0};

    `ifdef dcache_ecc

      rg_sec_checkparity <= lv_data_resp.check_parity;
      rg_sec_storeparity <= lv_data_resp.stored_parity;

      if(|(lv_tag_resp.ded & v_reg_valid[set_index]) == 1)
        lv_access_fault = True;
      else if(|lv_hitmask == 1 && |lv_data_resp.line_ded == 1)
        lv_access_fault = True;

      if(|lv_tag_resp.ded == 1)
        wr_ded_tag_log <= tagged Valid ECC_dcache_tag{address: phyaddr, 
                                                     way: lv_tag_resp.ded & v_reg_valid[set_index]};

      if (|lv_data_resp.line_ded == 1 && |lv_hitmask == 1)
        wr_ded_data_log <= tagged Valid ECC_dcache_data{address: phyaddr, 
                                                       banks: lv_data_resp.line_ded,
                                                       way : lv_hitmask};

      if (|(lv_tag_resp.sed & lv_hitmask) == 1)
        wr_sed_tag_log <= tagged Valid ECC_dcache_tag{address: phyaddr,
                                                    way: lv_hitmask};

      if (|lv_data_resp.line_sed == 1 && |lv_hitmask == 1)
        wr_sed_data_log <= tagged Valid ECC_dcache_data{address: phyaddr, 
                                                       banks: lv_data_resp.line_sed,
                                                       way : lv_hitmask};
    `endif
      let lv_response = DMem_core_response{word:response_word, trap: lv_access_fault,
                                          cause: lv_cause, epochs: req.epochs};

      wr_ram_response <= lv_response;
      wr_ram_hitway <= truncate(pack(countZerosLSB(lv_hitmask)));
      wr_ram_hitline <= lv_data_resp.line;

      if(lv_access_fault ) begin
        wr_fault <= True;
      end
      else if(|(lv_hitmask) == 1 && wr_cache_enable) begin// trap or hit in RAMs
        wr_ram_state <= Hit;
      end
      else begin // in case of miss from cache
        wr_ram_state <= Miss;
      end

    `ifdef ASSERT
      dynamicAssert(countOnes(lv_hitmask) <= 1,"DCACHE: More than one way is a hit in the cache");
    `endif
      `logLevel( dcache, 2, $format("[%2d]DCACHE: RAM Req:",id,fshow(req)))
      `logLevel( dcache, 2, $format("[%2d]DCACHE: RAM Hit:%b ",id,lv_hitmask))
    endrule
    rule rl_fillbuffer_check(!ff_core_request.first.fence && !m_storebuffer.mv_sb_busy
                             `ifdef dcache_ecc && !rg_perform_sec `endif );
      let req = ff_core_request.first;
      `logLevel( dcache, 2, $format("[%2d]DCACHE: FB Req:",id,fshow(req)))
    `ifdef supervisor
      Bit#(`paddr) phyaddr = ff_from_tlb.first.address;
    `else
      Bit#(`paddr) phyaddr = truncate(req.address);
    `endif
      Bit#(`wordbits) word_offset = truncate(phyaddr);
      Bit#(`causesize) lv_cause = req.access == 0? `Load_access_fault: `Store_access_fault;

      let lv_polling_resp <- m_fillbuffer.mav_polling_response(phyaddr, ff_pending_req.notEmpty, 
                ff_pending_req.first.fbindex);
      let lv_io_req = isIO(phyaddr, wr_cache_enable);

      let lv_response_word = lv_polling_resp.word >> {word_offset, 3'b0};
      let lv_hitmask = lv_polling_resp.waymask;
      let lv_linehit = lv_polling_resp.line_hit;
      let lv_wordhit = lv_polling_resp.word_hit;
      let lv_response_err = lv_polling_resp.err;

      wr_fb_hitindex <= truncate(pack(countZerosLSB(lv_hitmask)));
      let lv_response = DMem_core_response{word:lv_response_word, trap: unpack(lv_response_err),
                                          cause: lv_cause, epochs: req.epochs};
      if(lv_io_req && req.access != 0) begin
        wr_fb_state <= Hit;
        `logLevel( dcache, 1, $format("[%2d]DCACHE: FB: Detected NC Write",id))
      end
      else if(lv_linehit)begin
        `logLevel( dcache, 1, $format("[%2d]DCACHE: FB: Hit in Line:%b for Addr:%h",id, 
                                                                            lv_hitmask, phyaddr))
        if(lv_wordhit)begin
          wr_fb_state <= Hit;
          wr_fb_response <= lv_response;
          `logLevel( dcache, 1, $format("[%2d]DCACHE: FB: Required Word found",id))
          rg_polling_mode <= False;
        end
        else begin
          wr_fb_state <= None;
          rg_polling_mode <= True;
          `logLevel( dcache, 1, $format("[%2d]DCACHE: FB: Required word not available yet",id))
        end
      end
      else begin
        wr_fb_state <= Miss;
        rg_polling_mode <= False;
        `logLevel( dcache, 1, $format("[%2d]DCACHE: FB: Miss",id))
      end
    endrule

    /*doc:rule: this rule fires when the requested word is either present in the SRAMs or the
    fill-buffer or if there was an error in the request. Since we are re-using the
    ff_write_mem_response fifo to send out cacheable and MMIO ops, it is necessary that we make sure
    that this fifo is not Full before responding back to the core. If it is not empty then the core
    could initiate a commit-store which could get dropped since the method performing the cannot
    fire since the fifo is full and thus the store being dropped.*/
    rule rl_response_to_core(!ff_core_request.first.fence && `ifdef dcache_ecc !rg_perform_sec && `endif 
                      ( wr_fault || wr_nc_state == Hit || wr_ram_state == Hit || wr_fb_state == Hit));


    `ifdef dcache_ecc
      Bool lv_tag_sed = isValid(wr_sed_tag_log);
      Bool lv_data_sed = isValid(wr_sed_data_log);
      rg_halt_ram_check <= False;
    `endif
      Bool _faulty =  `ifdef dcache_ecc 
                          ((lv_data_sed || lv_tag_sed) && wr_ram_state == Hit) 
                        `else 
                          False 
                        `endif ;

      let req = ff_core_request.first;
    `ifdef supervisor
      let pa_response = ff_from_tlb.first;
      Bit#(`paddr) phyaddr = pa_response.address;
    `else
      Bit#(`paddr) phyaddr = truncate(req.address);
    `endif
      Bit#(`setbits) set_index= phyaddr[v_setbits+v_blockbits+v_wordbits-1:v_blockbits+v_wordbits];
      Bit#(`wordbits) word_offset = truncate(phyaddr);
      DMem_core_response#(`respwidth,`desize) lv_response;

      let {storemask, storedata} <- m_storebuffer.mav_check_sb_hit(phyaddr);

      Bit#(3) onehot_hit = {pack(wr_ram_state==Hit || wr_fault), 
                            pack(wr_fb_state==Hit && !wr_fault), 
                            pack(wr_nc_state==Hit && !wr_fault)};
    `ifdef ASSERT
      if(!wr_fault)
        dynamicAssert(countOnes(onehot_hit) == 1, "More than one data structure shows a hit");
    `endif
      Vector#(3, DMem_core_response#(`respwidth,`desize)) lv_responses;
      lv_responses[0] = wr_nc_response;
      lv_responses[1] = wr_fb_response;
      lv_responses[2] = wr_ram_response;

      lv_response = select(lv_responses,unpack(onehot_hit));

      if(wr_ram_state == Hit && !wr_fault) begin
        `logLevel( dcache, 0, $format("[%2d]DCACHE: Response: Hit from SRAM",id))
        if(`drepl == 2) begin
          replacement.update_set(set_index, wr_ram_hitway);//wr_replace_line);
          wr_ram_hitset <= tagged Valid set_index;
        end
      end
      if(wr_fb_state == Hit && !wr_fault) begin
        `logLevel( dcache, 0, $format("[%2d]DCACHE: Response: Hit from Fillbuffer",id))
      `ifdef perfmonitors
        if(rg_handling_miss) begin
          if(req.access == 0)
            wr_total_read_fb_hits <= 1;
          if(req.access == 1)
            wr_total_write_fb_hits<= 1;
          `ifdef atomic
            if(req.access == 2)
              wr_total_atomic_fb_hits <= 1;
          `endif
        end
      `endif
      end
      if(wr_nc_state == Hit && !wr_fault) begin
        `logLevel( dcache, 0, $format("[%2d]DCACHE: Response: Hit from NC",id))
      end

      lv_response.word = (storemask & storedata) | (~storemask & lv_response.word);
      // capture the sign bit of the response to the core
      Bit#(1) lv_sign =case(req.size[1:0])
          'b00: lv_response.word[7];
          'b01: lv_response.word[15];
          default: lv_response.word[31];
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

      if(!_faulty)begin
      ff_core_request.deq;
    `ifdef supervisor
        ff_from_tlb.deq;
      if(pa_response.tlbmiss)
        ff_hold_request.enq(ff_core_request.first());
      else if(req.ptwalk_req && !pa_response.tlbmiss)
        ff_ptw_response.enq(lv_response);
      else
    `endif
      ff_core_response.enq(lv_response);
      rg_handling_miss <= False;
      end

      // -- allocate store-buffer for stores/atomic ops
      Bit#(TLog#(`dfbsize)) _fbindex = ?;
      if( (req.access != 0 || _faulty )
                      && wr_ram_state == Hit && !wr_fault) begin
        _fbindex <- m_fillbuffer.mav_allocate_line(True, wr_ram_hitline, phyaddr,
                                                       v_reg_dirty[set_index][wr_ram_hitway]);

        // invalidate the entries in the RAM since they not reside inside the FB
        v_reg_valid[set_index][wr_ram_hitway] <= 1'b0;
        v_reg_dirty[set_index][wr_ram_hitway] <= 1'b0;
      `ifdef dcache_ecc
        if (_faulty) begin
          rg_perform_sec <= True;
          rg_sec_fbindex <= _fbindex;
          rg_sec_address <= phyaddr;
        end
      `endif
      end
    `ifdef supervisor
      if(!pa_response.tlbmiss)
    `endif
        if(!_faulty)
          `logLevel( dcache, 0, $format("[%2d]DCACHE: Responding to Core:",id, fshow(lv_response)))

      if(req.access!=0 && !_faulty && !lv_response.trap 
                                            `ifdef supervisor && !pa_response.tlbmiss `endif )begin
        wr_store_in_progress <= True;
        Bit#(TLog#(`dfbsize)) fbindex = (wr_fb_state == Hit && !wr_fault)? wr_fb_hitindex:_fbindex;
        m_storebuffer.ma_allocate_entry(phyaddr,req.data, req.epochs, fbindex, truncate(req.size),
                                          isIO(phyaddr, wr_cache_enable)
                                `ifdef atomic ,req.access == 2,lv_response.word, req.atomic_op `endif );
        `logLevel( dcache, 0, $format("[%2d]DCACHE: Response: Allocating Store Buffer",id))
        wr_allocating_storebuffer <= True;
      end
    endrule
    
    /*doc:rule: This rule fires when the requested word is a miss in both the SRAMs and the
    Fill-buffer. This rule thereby forwards the requests to the network. IOs by default should
    be a miss in both the SRAMs and the FB and thus need to be checked only here */
    rule rl_send_memory_request(wr_ram_state == Miss && wr_fb_state == Miss && !fb_full &&
          !wr_fault && !rg_handling_miss && ! ff_core_request.first.fence && ff_pending_req.notFull 
          `ifdef dcache_ecc && !rg_perform_sec `endif );
      let req = ff_core_request.first;
    `ifdef supervisor
      let pa_response = ff_from_tlb.first;
      Bit#(`paddr) phyaddr = pa_response.address;
    `else
      Bit#(`paddr) phyaddr = truncate(req.address);
    `endif
      let lv_io_req = isIO(phyaddr, wr_cache_enable);
      let burst_len = lv_io_req?0:(v_blocksize/valueOf(TDiv#(`dbuswidth,`respwidth)))-1;
      Bit#(3) burst_size = lv_io_req?zeroExtend(req.size[1:0]):fromInteger(valueOf(TLog#(TDiv#(`dbuswidth,8))));
      let shift_amount = valueOf(TLog#(TDiv#(`dbuswidth,8)));
      Bit#(`paddr) blockmask = '1 << shift_amount;
      Bit#(`blockbits) lv_blocknum = phyaddr[v_blockbits+v_wordbits-1:v_wordbits];
      // allocate a pending req which points to the new fb entry that is allotted.
      // align the address to be line-address aligned
      phyaddr= lv_io_req?phyaddr:(phyaddr & blockmask);
      ff_read_mem_request.enq(DCache_mem_readreq{ address   : phyaddr,
                                                  burst_len  : fromInteger(burst_len),
                                                  burst_size : burst_size,
                                                  io: lv_io_req
                                              });
      rg_handling_miss <= True;
      Bit#(TLog#(`dfbsize)) lv_alotted_fb = ?;

      // -- allocate a new entry in the fillbuffer
      if(!lv_io_req) begin
        lv_alotted_fb <- m_fillbuffer.mav_allocate_line(False, ?, phyaddr, ?);
        `logLevel( dcache, 0, $format("[%2d]DCACHE: MemReq: Allocating Fbindex:%d",id, lv_alotted_fb))
      end
      let pend_req = Pending_req{init_bank: lv_blocknum,io_request: lv_io_req, 
                                fbindex: lv_alotted_fb};
      ff_pending_req.enq(pend_req);
      if(lv_io_req) begin
        `logLevel( dcache, 0, $format("[%2d]DCACHE: MemReq: Sending NC Request for Addr:%h",id,phyaddr))
      `ifdef perfmonitors
        wr_total_io_reads <= pack(req.access == 0);
        wr_total_io_writes <= pack(req.access == 1);
      `endif
      end
      else begin
  `ifdef perfmonitors
      wr_total_read_miss <= pack(req.access == 0);
      wr_total_write_miss <= pack(req.access == 1);
    `ifdef atomic
      wr_total_atomic_miss <= pack(req.access == 2);
    `endif
  `endif
        `logLevel( dcache, 0, $format("[%2d]DCACHE: MemReq: Sending Line Request for Addr:%h",id, phyaddr))
      end
    endrule
    /*doc:rule: this rule will fill up the FB with the response from the memory, Once the last word
    has been received the entire line and tag are written in to the BRAM and the fill buffer is
    released in the next cycle*/
    rule rl_fill_from_memory(ff_pending_req.notEmpty && !ff_pending_req.first.io_request);
      let pending_req = ff_pending_req.first;
      let response = ff_read_mem_response.first;
      ff_read_mem_response.deq;
      m_fillbuffer.ma_fill_from_memory(response, pending_req.fbindex, pending_req.init_bank);
      `logLevel( dcache, 0, $format("[%2d]DCACHE: FILL: Response from Memory:",id,fshow(response)))
      if(response.last)
        ff_pending_req.deq;
    endrule
    /*doc:rule: this rule is responsible for capturing the memory response for an IO request.*/
    rule rl_capture_io_response(ff_pending_req.notEmpty && ff_pending_req.first.io_request);
      let response = ff_read_mem_response.first;
      let req = ff_core_request.first;
      Bit#(`causesize) lv_cause = req.access == 0? `Load_access_fault: `Store_access_fault;
      Bit#(`wordbits) word_offset = truncate(req.address);
      let response_word = response.data >> {word_offset,3'b0};
      let lv_response = DMem_core_response{word:response_word, trap: response.err,
                                          cause: lv_cause, epochs: req.epochs};
      wr_nc_response <= lv_response;
      wr_nc_state <= Hit;
      ff_read_mem_response.deq;
      ff_pending_req.deq;
      `logLevel( dcache, 2, $format("[%2d]DCACHE: NC Response from Memory: ",id,fshow(response)))
    endrule
    rule rl_release_from_fillbuffer(sb_empty && !fb_empty && !wr_allocating_storebuffer  
                                                         && fb_headvalid );
      let addr = lv_release_addr;
      Bit#(`setbits) set_index = addr[v_setbits + v_blockbits + v_wordbits - 1 :
                                                                         v_blockbits + v_wordbits];

      let waynum <- replacement.line_replace(set_index, v_reg_valid[set_index],
                                                       v_reg_dirty[set_index]);
      `logLevel( dcache, 2, $format("[%2d]DCACHE: Release: set%d way:%d valid:%b dirty:%b",id,
                                    set_index, waynum,v_reg_valid[set_index][waynum] ,
                                    v_reg_dirty[set_index][waynum] ))
      let lv_release_info = m_fillbuffer.mv_release_info;
      if(lv_release_err == 0)begin
        // enter here if the fillbuffer entry is valid and has no errors
        if((v_reg_valid[set_index][waynum] & v_reg_dirty[set_index][waynum])==1 &&
                                                                        !rg_release_readphase)begin
          // enter here if the line to be replaced is valid and dirty. We thus need to first read it
          // out and then send to the next level
          m_tag.ma_request_p2(False, set_index, lv_release_addr, ?);
          m_data.ma_request_p2(False, set_index, lv_release_line, waynum, '1);
          rg_release_readphase <= True;
          `logLevel( dcache, 0, $format("[%2d]DCACHE: Release: Reading dirty set:%d way:%d",id,
                                      set_index,waynum))
        end
        else if((v_reg_valid[set_index][waynum] & v_reg_dirty[set_index][waynum]) !=1 ||
                                                                        rg_release_readphase)begin
          // enter here if either the entry being replaced is not dirty or if its dirty then it has
          // been read out of the ram in the previous cycle and is ready for eviction
          Bit#(TSub#(`paddr,TAdd#(`tagbits,`setbits))) zeros = 0;
          Bit#(`dways) _way = 0;
          _way[waynum] = 1;
          let lv_tag_resp = m_tag.mv_read_response_p2(waynum);
          let lv_data_resp = m_data.mv_read_response_p2(_way);
          Bit#(`tagbits) tag = truncateLSB(lv_tag_resp.address);
          Bit#(`linewidth) dataline = lv_data_resp.line;
          Bit#(`paddr) lv_evict_address = {tag,set_index,zeros};
        `ifdef dcache_ecc
          Bit#(TMul#(`dblocks,TAdd#(2,TLog#(`respwidth)))) stored_parity = lv_data_resp.stored_parity;
          Bit#(TMul#(`dblocks,TAdd#(2,TLog#(`respwidth)))) check_parity = lv_data_resp.check_parity;
          for (Integer i = 0; i< v_blocksize; i = i + 1) begin
            Bit#(ecc_size) _stparity = stored_parity[i*v_ecc_size+v_ecc_size-1:i*v_ecc_size];
            Bit#(ecc_size) _chparity = check_parity[i*v_ecc_size+v_ecc_size-1:i*v_ecc_size];
            Bit#(`respwidth) _data = dataline[i*v_respwidth+v_respwidth-1:i*v_respwidth];
            _data <- fn_ecc_correct_uw[i].func(_chparity, _stparity, _data);
            dataline[i*v_respwidth+v_respwidth-1:i*v_respwidth] = _data;
          end
          if(|lv_tag_resp.ded == 1)
            wr_ded_tag_log <= tagged Valid ECC_dcache_tag{address: lv_evict_address, 
                                                         way: lv_tag_resp.ded & v_reg_valid[set_index]};

          if (|lv_data_resp.line_ded == 1)
            wr_ded_data_log <= tagged Valid ECC_dcache_data{address: lv_evict_address, 
                                                           banks: lv_data_resp.line_ded,
                                                           way : _way};
        `endif
          if(rg_release_readphase ) begin

            `logLevel( dcache, 0, $format("[%2d]DCACHE: Evicting Addr:%h set_index:%d tag:%h\
 data:%h", id,lv_evict_address,set_index,tag,dataline))
            ff_write_mem_request.enq(DCache_mem_writereq{address:lv_evict_address,
                                                  burst_len:fromInteger(valueOf(`dblocks)-1),
                                                  burst_size:fromInteger(valueOf(TLog#(`dwords))),
                                                  data: truncateLSB(dataline),
                                                  io: False
                                              });
          `ifdef perfmonitors
            wr_total_evictions <= 1;
          `endif
          end
          // update the valid and dirty bits of the rams. Also release the fillbuffer entry
        `ifdef perfmonitors
          wr_total_fb_releases <= 1;
        `endif
          v_reg_valid[set_index][waynum]<=1;
          v_reg_dirty[set_index][waynum]<=lv_release_info.dirty;
          m_tag.ma_request_p2(True,set_index,lv_release_addr,waynum);
          m_data.ma_request_p2(True,set_index,lv_release_line,waynum,'1);
          m_fillbuffer.ma_perform_release;
          `logLevel( dcache, 0, $format("[%2d]DCACHE: Release: Upd Addr:%h set:%d way:%d dirty:%b data:%h", 
                id,lv_release_addr, set_index,waynum,lv_release_info.dirty, lv_release_info.dataline))
          // ------------------ replacement policy updates -------------------------------------//
          Bool alldirty =  (&v_reg_valid[set_index] == 1 && &v_reg_dirty[set_index] == 1);
          Bool nonedirty = (&v_reg_valid[set_index] == 1 && |v_reg_dirty[set_index] == 0);
          Bool update_req = alldirty || nonedirty;

          if(`drepl == 1) begin// RR
            if(update_req) 
              replacement.update_set(set_index, waynum);
          end
          else if(`drepl == 2) begin // PLRU
            if(wr_ram_hitset matches tagged Valid .i &&& i == set_index) begin
            end
            else
              replacement.update_set(set_index,waynum);
          end
          else if (`drepl == 0) // RANDOM
            replacement.update_set(set_index,waynum);
          // ---------------------------------------------------//
        end
      end
      else begin
        // enter here only if the fillbuffer entry has an error
        m_fillbuffer.ma_perform_release;
      end
    endrule

    interface put_core_req=interface Put
      method Action put(DCache_core_request#(`vaddr,`respwidth,`desize) req)
                        if( ff_core_response.notFull && !rg_fence_stall && !fb_full);
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
        if(wr_cache_enable) begin
          m_tag.ma_read_p1(set_index);
          m_data.ma_read_p1(set_index,'1);
        end
        `logLevel( dcache, 0, $format("[%2d]DCACHE: Receiving request: ",id,fshow(req)))
        `logLevel( dcache, 0, $format("[%2d]DCACHE: set:%d",id,set_index))
        wr_takingrequest <= True;
      endmethod
    endinterface;
    method Action ma_perform_store(Bit#(`desize) currepoch);
      let {sb_valid, sb_entry} <- m_storebuffer.mav_store_to_commit;
      `logLevel( dcache, 0, $format("[%2d]DCACHE: Commit Store entry:",id,fshow(sb_entry)))
      if(sb_entry.epoch == currepoch) begin
        if(sb_entry.io) begin
          `logLevel( dcache, 0, $format("[%2d]DCACHE: Store to NC Addr:%h",id,sb_entry.addr))
          ff_write_mem_request.enq(DCache_mem_writereq{address   : sb_entry.addr,
                                                      burst_len  : 0,
                                                      burst_size : zeroExtend(sb_entry.size),
                                                      data       : duplicate(sb_entry.data),
                                                      io         : True
                                                  });
        end
        else begin
          `logLevel( dcache, 0, $format("[%2d]DCACHE: Store to Available line",id))
          m_fillbuffer.ma_from_storebuffer(sb_entry.mask, sb_entry.data, sb_entry.fbindex,
                                          sb_entry.addr);
          rg_globaldirty <= True;
        end
      end
      else begin
        `logLevel( dcache, 0, $format("[%2d]DCACHE: Store is being dropped- epoch mismatch",id))
      end

    endmethod

    method Action ma_cache_enable(Bool c);
      wr_cache_enable <= c;
    endmethod
    method Action ma_curr_priv (Bit#(2) c);
      wr_priv <= c;
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
    method mv_storebuffer_empty = m_storebuffer.mv_sb_empty;
    method mv_cacheable_store = m_storebuffer.mv_cacheable_store;
    method mv_cache_available = ff_core_response.notFull && ff_core_request.notFull &&
        !rg_fence_stall && !fb_full && !sb_full && !m_storebuffer.mv_sb_busy
        `ifdef dcache_ecc && !rg_perform_sec && !rg_halt_ram_check `endif ;
    method mv_commit_store_ready = ff_write_mem_request.notFull && !m_storebuffer.mv_sb_busy;
  `ifdef dcache_ecc
    method mv_ded_data = wr_ded_data_log;
    method mv_sed_data = wr_sed_data_log;
    method mv_ded_tag = wr_ded_tag_log;
    method mv_sed_tag = wr_ded_tag_log;
    method Action ma_ram_request(DRamAccess access)if(!rg_fence_stall);
      Bit#(blocksize) _banks = 0;
      _banks[access.banks] = 1;
      if(!access.tag_data) begin // access tag;
        m_tag.ma_request_p2(access.read_write, access.index, truncate(access.data), access.way);
      end
      else begin
        m_data.ma_request_p2(access.read_write, access.index, duplicate(access.data) , access.way,
        _banks);
      end
      rg_access_req <= tagged Valid access;
    endmethod
    method Bit#(`respwidth) mv_ram_response if(!rg_fence_stall 
                                              &&& rg_access_req matches tagged Valid .access);
      Bit#(`respwidth) tag_response = zeroExtend(m_tag.mv_sideband_read(access.way));
      Bit#(`respwidth) data_response = m_data.mv_sideband_read(access.way,
                                        access.banks);
      if(!access.tag_data) // access tag
        return tag_response;
      else
        return data_response;
    endmethod
  `endif
  endmodule

endpackage

