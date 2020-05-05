/* 
see LICENSE.incore
see LICENSE.iitm

Author: Neel Gala
Email id: neelgala@gmail.com
Details:
*/
/*doc:overview:

Working Principle
-----------------

A request from the core is enqueued into a request fifo (``ff_core_request``). On a hit within the 
cache, the required word is enqueued into the response fifo (``ff_core_response``) which is read by 
the core. On a miss, a read request for the line is sent to the fabric via the 
``ff_read_mem_request`` and simultaneously an entry in the fill-buffer is allotted to capture the 
fabric response. The responses from the fabric are enqueued in the ``ff_read_mem_response`` fifo. 

Serving core requests
^^^^^^^^^^^^^^^^^^^^^

A core request can only be enqueued in ``ff_core_request`` fifo if the following conditions are true :- 

1. Fill-buffer is not full.
2. Core is ready to receive a response or deq the previous response
3. Fence operation is not in progress.
4. A replay of SRAM tag and data request (for a previous request) is not happening 
   (its necessity is discussed in later sections).

The reason for point 1 and 2 being, once either of the two structures are full, a hit or a miss 
cannot be processed further. In this situation, if there is one outstanding request already 
present in ``ff_core_request``, enqueuing one more request would overwrite the SRAM tag and data 
values of the previous one. When tag matching resumes, incorrect tag would be used leading to 
incorrect behaviour.

Once a request is enqueued into the ``ff_core_request`` fifo, a tag and data read request is sent to 
the SRAMs simultaneously. In the next cycle, if there isn't a pending request and fill-buffer & 
ff_core_response are not full, the tag field of the request is compared with the tags stored in 
the SRAMs (tag field of all the ways for particular set) and the fill-buffer 
(tag field of all the entries). 

A hit occurs in following scenarios :- 1. Tag matches in SRAM 2. Tag matches in fill-buffer and 
also the requested word is present. There might be a case where tag matches in fill-buffer but the 
word is not present as the line is still getting filled by the fabric. In that case we keep 
polling on the fill-buffer until there's a **word-hit**. Please note, that a tag-hit can occur 
either in the SRAM or the fill-buffer and never both. Assertions to check this have been put in 
place. A miss occurs when tag match fails in both the SRAM and the fill-buffer. Now following 
scenarios can occur :-

1. If it's a hit, the requested word is enqueued in ``ff_core_response`` 
   fifo in the same cycle as the tag-match. 

2. If it's a miss, the address (after making it word aligned) is 
   enqueued into the ``ff_read_mem_request`` fifo to be sent to fabric. Simultaneously, a 
   fill-buffer entry is assigned to capture the line requested from the fabric. The register
   rg_performing_replay is also set to true to ensure that the next request from the core, which
   might have been latched is not served until the miss request has been served. Thus, while a miss
   is being served only the fill-buffer polling is active and RAM look-ups are blocked.
   Once the requested word is captured in the fill-buffer (while rest of the line is still getting filled), 
   it is enqueued into the ``ff_core_response`` to be sent to core and the entry in ``ff_core_request`` 
   is dequeued. We are now ready to service the subsequent request in the next cycle.

Release from fill-buffer
^^^^^^^^^^^^^^^^^^^^^^^^

The necessary condition for a release of a line from fill-buffer and its updation into SRAM is 
that the line itself is valid and all the words in the line are present 
Given this is true, following conditions would initiate a release :- 

1. **Fill-buffer is full**. A release is necessary in this case since no more requests can be 
   taken and it can stall the pipe. While the release happens, suppose there is an entry already 
   present in the request fifo which is to the line being released. The tag and data for that 
   entry have already been read and would be used to check hit/miss. The SRAM tag matching would 
   take place with a stale value and would result in a miss. It would also be a miss in fill-buffer 
   since the line would already have been released. To prevent this incorrect behaviour, we need to 
   replay the SRAM tag and data requests (now it would be a hit in SRAM).

2. **Opportunistic fill**: if the fill-buffer is not full but there is no request being enqueued 
   in a particular cycle (this does not mean ``ff_core_request`` is empty). Given this, if there is 
   an entry in ``ff_core_request`` to the line being released, we prevent the release for not 
   wanting to replay the SRAM read request (described in point 1).


Once a release is done from the fill-buffer, that particular entry in the fill-buffer is 
invalidated and thus is available for new allocation on a miss.

The fill-buffer is implemented as a circular-buffer with head and tail pointer-registers.

Replaying Requests
^^^^^^^^^^^^^^^^^^

This register indicates that the bram inputs are being re-driven by those provided
from the core in the most recent request. This happens because as the release from the
fillbuffer happens it is possible that a dirty ways needs to be read out. This will change the
output of the brams as compared to what the core requested. Thus the core request needs to be
replayed on these again.

Fence operation
^^^^^^^^^^^^^^^

A cache-flush operation is initiated when the core presents a fence instruction. A fence operation 
can only start if following conditions are met:

  1. the entire fill-buffer is empty (i.e. all lines are updated in the SRAM).

The fence operation is a single cycle operation where all the lines are invalidated 
*/
/*doc:macros: 

Boolean macros
^^^^^^^^^^^^^^
  - **supervisor**: when set at compile time will implement supervisor support
  - **perfmonitors**: when set at compile time will enable performance monitors
  - **icache_ecc**: when set at compile time will enable ECC support

Value Based macros
^^^^^^^^^^^^^^^^^^
  - **vaddr**  : size of virtual address
  - **paddr**  : size of the physical address
  - **iesize** : size of instruction epoch
  - **ifbsize**: size of the fill-buffer
  - **ibuswidth**: size of data on the fabric bus
  - **iwords** : number of bytes per word/response to core
  - **iways**  : number of ways in the cache
  - **iblocks**: number of words within a block/cache line
  - **isets**  : number of sets in the cache
  - **irepl**  : replacement policy choice
*/
package icache;
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

  `include "icache.defines"
  import icache_types :: * ;
  import icache_lib :: * ;
  import replacement_icache :: * ;
  import mem_config :: * ;
`ifdef supervisor
  import common_tlb_types:: * ;
`endif
  import ecc_hamming :: * ;
  import io_func :: * ;
`ifdef pmp
  import pmp_func :: *;
`endif
 
  typedef struct{
    Bit#(TLog#(blocks)) init_bank;
    Bit#(TLog#(fbsize)) fbindex;
    Bool io_request;
  } Pending_req#(numeric type fbsize, numeric type blocks)
                deriving(Bits, Eq, FShow);


  interface Ifc_icache;
    /*doc:subifc: A Put method to receive the core request. A request should be lateched into this
    port only if the interface mv_cache_available is set to True*/
    interface Put#(ICache_core_request#(`vaddr,`iesize)) put_core_req;
    /*doc:subifc: A Get method to respond to the core with the requested instruction or to respond
    with a trap*/
    interface Get#(IMem_core_response#(TMul#(`iwords,8),`iesize)) get_core_resp;
    /*doc:subifc: A Get method to send requests to the fabric on a miss in the cache or for an IO
    request.*/
    interface Get#(ICache_mem_readreq#(`paddr)) get_read_mem_req;
    /*doc:subifc: A Put method to receive response from the fabric for a pending miss or for an IO
    request*/
    interface Put#(ICache_mem_readresp#(`ibuswidth)) put_read_mem_resp;
  `ifdef supervisor
    /*doc:subifc: A Put method to receive the translated address from the TLB or a page fault
    exception from the TLB*/
    interface Put#(ITLB_core_response#(`paddr)) put_pa_from_tlb;
  `endif
  `ifdef perfmonitors
    /*doc:method: holds the performinor signals. Each bit corresponds to an event. A toggle from 1
    to 0 on these signals indicates that the particular event has occurred. Events are concatenated
    in the following order: {number of access, number of IO requests, number of misses, 
    number of fb releases, number of fbhits}*/
    method Bit#(5) mv_perf_counters();
  `endif
    /*doc:method: input signal indicating if the cache is enabled by the core or not. The SoC can
    choose to drive this signal from any resources (CSRs or memory mapped registers, etc) */
    method Action ma_cache_enable(Bool c);
    /*doc:method: input signal to hold the current privilege mode of the core*/
    method Action ma_curr_priv (Bit#(2) c);
    /*doc:method: output signal indicating if the cache is busy or ready to take new inputs from the
    core. The cache is available only under the following conditions: 
      - fill-buffer is no full
      - replay is not being performed
      - fence is not under operation
      - core has read all pending responses */
    method Bool mv_cache_available();
  `ifdef icache_ecc
    /*doc:method:output signal holding information of the latest double error detected in data RAMs*/
    method Maybe#(ECC_icache_data#(`paddr, `iways, `iblocks)) mv_ded_data();
    /*doc:method:output signal holding information of the latest single error detected in Data RAMs*/
    method Maybe#(ECC_icache_data#(`paddr, `iways, `iblocks)) mv_sed_data();
    /*doc:method: output signal holding information of the latest double error detected in the TAG
    RAMs*/
    method Maybe#(ECC_icache_tag#(`paddr, `iways)) mv_ded_tag();
    /*doc:method: output signal holdng information of the latest single error detected in the TAG
    RAMs*/
    method Maybe#(ECC_icache_tag#(`paddr, `iways)) mv_sed_tag();
    /*doc:method: input signals to access the Tag and Data rams externally. This interface should
    typically be used by software , through a memory mapped region to further probe and correct
    RAM errors*/
    method Action ma_ram_request(IRamAccess access);
    /*doc:method: output signal holding the response from the rams after an external access to the
    RAMs was performed.*/
    method Bit#(`respwidth) mv_ram_response();
  `endif
  endinterface : Ifc_icache
  // both update rg_handling_miss but can never fire together
  (*conflict_free="rl_send_memory_request, rl_response_to_core"*)
  (*conflict_free="rl_response_to_core,rl_ram_check"*)
  (*conflict_free="rl_send_memory_request,rl_release_from_fillbuffer"*)
  (*conflict_free="rl_fill_from_memory, rl_release_from_fillbuffer"*)
  // the following rules access the mv_read_response from of data and tag modules which is a
  // conflict. However, these two rules will never fire together
  (*mutually_exclusive="rl_release_from_fillbuffer, rl_ram_check"*)
  // both the following will update the replacement policy
  (*conflict_free="rl_release_from_fillbuffer, rl_response_to_core"*)
`ifdef icache_ecc
  (*preempts="ma_ram_request,rl_release_from_fillbuffer"*)
`endif
  (*synthesize*)
  module mkicache#( parameter Bit#(32) id
    `ifdef pmp ,
        Vector#(`pmpsize, Bit#(8)) pmp_cfg, 
        Vector#(`pmpsize, Bit#(TSub#(`paddr,`pmp_grainbits))) pmp_addr `endif
    )(Ifc_icache);

    String icache = "";
    let v_sets=valueOf(`isets);
    let v_setbits=valueOf(`setbits);
    let v_wordbits=valueOf(`wordbits);
    let v_blockbits=valueOf(`blockbits);
    let v_linewidth=valueOf(`linewidth);
    let v_paddr=valueOf(`paddr);
    let v_ways=valueOf(`iways);
    let v_wordsize=valueOf(`iwords);
    let v_blocksize=valueOf(`iblocks);
    let v_respwidth=valueOf(`respwidth);
    let v_fbsize = valueOf(`ifbsize);
    let v_dbanks = valueOf(`iblocks);
    let v_tagbits = valueOf(`tagbits);
    let v_ecc_size = valueOf(`ieccsize);

    let m_data <- mkicache_data(id);
    let m_tag <- mkicache_tag(id);
    let m_fillbuffer <- mkicache_fb_v2(id);
    // ----------------------- FIFOs to interact with interface of the design -------------------//
    /*doc:fifo: This fifo stores the in-coming request from the core.*/
    FIFOF#(ICache_core_request#(`vaddr, `iesize)) ff_core_request <- mkSizedFIFOF(2);
    /*doc:fifo: This fifo stores the response that needs to be sent back to the core.*/
    FIFOF#(IMem_core_response#(`respwidth,`iesize))ff_core_response <- mkBypassFIFOF();
    /*doc:fifo: this fifo stores the read request that needs to be sent to the next memory level.*/
    FIFOF#(ICache_mem_readreq#(`paddr)) ff_read_mem_request <- mkSizedFIFOF(2);
    /*doc:fifo: This fifo stores the response from the next level memory.*/
    FIFOF#(ICache_mem_readresp#(`ibuswidth)) ff_read_mem_response  <- mkBypassFIFOF();

  `ifdef supervisor
    /*doc:fifo: this fifo receives the physical address from the TLB */
    FIFOF#(ITLB_core_response#(`paddr)) ff_from_tlb <- mkBypassFIFOF();
  `endif

    // ------------------------ FIFOs for internal state-maintenance ---------------------------//
    /*doc:fifo: This fifo holds meta information of the miss/io request that was made by the core*/
    FIFOF#(Pending_req#(`ifbsize, `iblocks)) ff_pending_req <- mkUGSizedFIFOF(2);
    
    // -------------------- Register declarations ----------------------------------------------//

    /*doc:reg: register when True indicates a fence is in progress and thus will prevent taking any
     new requests from the core*/
    Reg#(Bool) rg_fence_stall <- mkReg(False);

    /*doc:reg: When true indicates that a miss is being catered to. Setting this register to true
    prevents the next request from being handled until this register has been set back to false -
    which happens when the requested word arrives from fabric*/
    Reg#(Bool) rg_handling_miss <- mkReg(False);

    /*doc:reg: This register indicates that the bram inputs are being re-driven by those provided
    from the core in the most recent request. This happens because as the release from the
    fillbuffer happens it is possible that a dirty ways needs to be read out. This will change the
    output of the brams as compared to what the core requested. Thus the core request needs to be
    replayed on these again */
    Reg#(Bool) rg_performing_replay <- mkReg(False);

    /*doc:reg: this register holds the index of the most recent request performed by the core. This
    register is used for performing a replay*/
    Reg#(Bit#(`setbits)) rg_recent_req <- mkReg(0);

    /*doc:reg: this register indicates that the line corresponding to the current request to the
    core is already persent however, the necessary is not present. This doesn't generate a miss
    and thus rg_miss_handling cannot be used here. Hence the need for this register*/
    Reg#(Bool) rg_polling_mode <- mkReg(False);

  `ifdef icache_ecc
    /*doc:reg: register to hold the access request performed by the external CCSU module*/
    Reg#(Maybe#(IRamAccess)) rg_access_req <- mkDReg(tagged Invalid);
  `endif

    // -------------------- Wire declarations ----------------------------------------------//
    /*doc:wire: boolean wire indicating if the cache is enabled. This is controlled through a csr or
    a memory mapped region*/
    Wire#(Bool) wr_cache_enable<-mkWire();
    /*doc:wire: this wire indicates if there was a fault in the address or during translation from
    the TLB*/
    Wire#(Bool) wr_fault <- mkDWire(False);
    /*doc:wire: this wire indicates if there was a hit or miss on SRAMs.*/
    Wire#(RespState) wr_ram_state <- mkDWire(None);
    /*doc:wire: this wire holds the response from the RAM in case of a hit in the RAMs*/
    Wire#(IMem_core_response#(`respwidth,`iesize)) wr_ram_response <- mkDWire(?);
    /*doc:wire: in case of a hit in the ram, this wire holds the information of which way was a hit.
    This is used for replacement purposes only.*/
    Wire#(Bit#(TLog#(`iways))) wr_ram_hitway <-mkDWire(0);
    /*doc:wire in case of a hit in the rams, the wire holds the holds the value of the set which
    caused a hit. This is necessary since an eviction from the same set should not affect the
    replacement policy if a hit to the same set has occurred in the same cycle */
    Wire#(Maybe#(Bit#(`setbits))) wr_ram_hitset <- mkDWire(tagged Invalid);

    /*doc:wire: this wire indicates if there was a hit or miss on Fllbuffer.*/
    Wire#(RespState) wr_fb_state <- mkDWire(None);

    /*doc:wire: this wire holds the response data structure in case of a hit from fill-buffers*/
    Wire#(IMem_core_response#(`respwidth,`iesize)) wr_fb_response <- mkDWire(?);

    /*doc:wire: this wire indicates if the current request is non-cacheable*/
    Wire#(RespState) wr_nc_state <- mkDWire(None);

    /*doc:wire: this wire holds the response data structure in case of a Non-cacheable access*/
    Wire#(IMem_core_response#(`respwidth,`iesize)) wr_nc_response <- mkDWire(?);
  `ifdef perfmonitors
    /*doc:wire: wire to pulse on every read access*/
    Wire#(Bit#(1)) wr_total_read_access <- mkDWire(0);
    /*doc:wire: wire to pulse on every io read access*/
    Wire#(Bit#(1)) wr_total_io_reads <- mkDWire(0);
    /*doc:wire: wire to pulse on every read miss within the cache*/
    Wire#(Bit#(1)) wr_total_read_miss <- mkDWire(0);
    /*doc:wire: wire to pulse on every release from fill-buffer to RAMS*/
    Wire#(Bit#(1)) wr_total_fb_releases <- mkDWire(0);
    /*doc:wire: wire to pulse on  hit in fill-buffer for read ops*/
    Wire#(Bit#(1)) wr_total_read_fb_hits <- mkDWire(0);
  `endif
    /*doc:wire: A Boolean wire indicating that a request if being taken from the core in the current
    cycle. This wire prevents any oppurtunistic releases from the fill-buffer to happen when set to
    True*/
    Wire#(Bool) wr_takingrequest <- mkDWire(False);
    /*doc:wire: wire holds the current privilege mode of the core*/
    Wire#(Bit#(2)) wr_priv <- mkWire();

  `ifdef icache_ecc
    /*doc:wire: */
    Wire#(Bool) wr_ecc_fault <- mkDWire(False);
    /*doc:wire: */
    Wire#(Bit#(`iways)) wr_err_ways <- mkDWire(0);
    /*doc:wire: */
    Wire#(Maybe#(ECC_icache_tag#(`paddr,`iways))) wr_sed_tag_log <- mkDWire(tagged Invalid);
    /*doc:wire: */
    Wire#(Maybe#(ECC_icache_tag#(`paddr,`iways))) wr_ded_tag_log <- mkDWire(tagged Invalid);
    /*doc:wire: */
    Wire#(Maybe#(ECC_icache_data#(`paddr,`iways, `iblocks))) wr_sed_data_log <- mkDWire(tagged Invalid);
    /*doc:wire: */
    Wire#(Maybe#(ECC_icache_data#(`paddr,`iways, `iblocks))) wr_ded_data_log <- mkDWire(tagged Invalid);
  `endif
    // ----------------------- Storage elements -------------------------------------------//
    /*doc:reg: This is an array of the valid bits. Each entry corresponds to a set and contains
    'way' number of bits in each entry*/
    Vector#(`isets, Reg#(Bit#(`iways))) v_reg_valid <- replicateM(mkReg(0));

    Ifc_replace#(`isets,`iways) replacement <- mkreplace(`irepl);
    // --------------------- Store buffer related structures ----------------------------------//

    // --------------------------- global variables ------------------------------------- //
    Bool fb_full = m_fillbuffer.mv_fbfull;
    Bool fb_empty = m_fillbuffer.mv_fbempty;
    Bool fb_headvalid = m_fillbuffer.mv_fbhead_valid;
    // --------- release information 
    let lv_release_line = m_fillbuffer.mv_release_info.dataline;
    let lv_release_addr = m_fillbuffer.mv_release_info.address;
    let lv_release_err  = m_fillbuffer.mv_release_info.err;

    Bit#(`setbits) fillindex = lv_release_addr[v_setbits + v_blockbits + v_wordbits - 1:
                                                                          v_blockbits + v_wordbits];
    /*doc:var: This variable indicates if there is an oppurtunity to perform a release from the
    fill-buffer to the RAMS. This takes advantage of the fact that the cache is idle is not being
    used by the core. The conditions under which an oppurtunity occurs is if all the following
    conditions are met:
      1. there is not core-request pending
      2. The core is not generating any request in the current cycle
      4. The set being released to is not the most recent set accessed by the core.
    */
    Bool lv_fill_oppurtunity = (!ff_core_request.notEmpty && !wr_takingrequest)  &&
         /*countOnes(fb_valid)>0 &&*/ (fillindex != rg_recent_req); 
    
    // --------------------------- Rule operations ------------------------------------- //

    /*doc:rule: This rule performs the fence operation. This is a single cycle op where all the
    valid registers are assigned 0. A fence operation can be triggered only if: the a fence
    operation is requested by the core, the fill-buffer is empty and no replay is being performed.*/
    rule rl_fence_operation(ff_core_request.first.fence && rg_fence_stall && fb_empty && 
                            !rg_performing_replay ) ;
      `logLevel( icache, 1, $format("[%2d]ICACHE : Fence operation in progress",id))
      for (Integer i = 0; i< fromInteger(v_sets); i = i + 1) begin
        v_reg_valid[i] <= 0 ;
      end
      rg_fence_stall <= False;
      ff_core_request.deq;
      replacement.reset_repl;
    endrule

    /*doc:rule: This rule checks the tag rams for a hit. Once a hit is detected, the selected way is
    used to capture the corresponding dataline and the requested word is extracted from the same
    line. This rule will also capture any exceptions received from the TLB when supervisor is
    enabled. Also a hit in the rams is only detected if the ``wr_cache_enable`` signal is asserted.*/
    rule rl_ram_check(!ff_core_request.first.fence && !rg_handling_miss && !rg_performing_replay
                      && !rg_polling_mode && !fb_full );
      let req = ff_core_request.first;
      // select the physical address and check for any faults
    `ifdef supervisor
      let pa_response = ff_from_tlb.first;
      Bit#(`paddr) phyaddr = pa_response.address;
      Bool lv_access_fault = pa_response.trap; 
      Bit#(`causesize) lv_cause = lv_access_fault? pa_response.cause:
                                  `Inst_access_fault;
      `logLevel( icache, 1, $format("[%2d]ICACHE: Response from PA:",id,fshow(pa_response)))
    `else
      Bit#(TSub#(`vaddr,`paddr)) upper_bits=truncateLSB(req.address);
      Bit#(`paddr) phyaddr = truncate(req.address);
      Bool lv_access_fault = unpack(|upper_bits);
      Bit#(`causesize) lv_cause = `Inst_access_fault;
    `endif
    `ifdef pmp
      let pmpreq = PMPReq{ address: truncateLSB(phyaddr), access_type:2};
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

      let lv_tag_resp = m_tag.mv_read_response(phyaddr, ?);
      `logLevel( icache, 0, $format("[%2d]ICACHE: lv_tag_resp:",id,fshow(lv_tag_resp)))
      Bit#(`iways) lv_hitmask = lv_tag_resp.waymask & v_reg_valid[set_index];
      let lv_data_resp = m_data.mv_read_response(lv_blocknum,lv_hitmask);
      `logLevel( icache, 0, $format("[%2d]ICACHE: lv_data_resp:",id,fshow(lv_data_resp)))
      let response_word = lv_data_resp.word >> {word_offset,3'b0};

    `ifdef icache_ecc

      Bool fault_detected = False;

      if(|( (lv_tag_resp.ded|lv_tag_resp.sed) & v_reg_valid[set_index]) == 1) begin
        fault_detected = True;
        wr_err_ways <= lv_tag_resp.ded | lv_tag_resp.sed;
      end
      else if(|lv_hitmask == 1 && |(lv_data_resp.line_ded|lv_data_resp.line_sed) == 1) begin
        fault_detected = True;
        wr_err_ways <= lv_hitmask;
      end

      wr_ecc_fault <= fault_detected;

      if(|lv_tag_resp.ded == 1)
        wr_ded_tag_log <= tagged Valid ECC_icache_tag{address: phyaddr, 
                                                     way: lv_tag_resp.ded & v_reg_valid[set_index]};

      if (|lv_data_resp.line_ded == 1 && |lv_hitmask == 1)
        wr_ded_data_log <= tagged Valid ECC_icache_data{address: phyaddr, 
                                                       banks: lv_data_resp.line_ded,
                                                       way : lv_hitmask};

      if (|(lv_tag_resp.sed & lv_hitmask) == 1)
        wr_sed_tag_log <= tagged Valid ECC_icache_tag{address: phyaddr,
                                                    way: lv_hitmask};

      if (|lv_data_resp.line_sed == 1 && |lv_hitmask == 1)
        wr_sed_data_log <= tagged Valid ECC_icache_data{address: phyaddr, 
                                                       banks: lv_data_resp.line_sed,
                                                       way : lv_hitmask};
    `endif
      let lv_response = IMem_core_response{word:response_word, trap: lv_access_fault,
                                          cause: lv_cause, epochs: req.epochs};

      wr_ram_response <= lv_response;
      wr_ram_hitway <= truncate(pack(countZerosLSB(lv_hitmask)));

      if(lv_access_fault) begin
        wr_fault <= True;
      end
      else if(|(lv_hitmask) == 1 && wr_cache_enable 
                        `ifdef icache_ecc && !fault_detected `endif ) begin
        wr_ram_state <= Hit;
      end
      else begin // in case of miss from cache
        wr_ram_state <= Miss;
      end

    `ifdef ASSERT
      dynamicAssert(countOnes(lv_hitmask) <= 1,"ICACHE: More than one way is a hit in the cache");
    `endif
      `logLevel( icache, 2, $format("[%2d]ICACHE: RAM Req:",id,fshow(req)))
      `logLevel( icache, 2, $format("[%2d]ICACHE: RAM Hit:%b ",id,lv_hitmask))
    endrule

    /*doc:rule: This rule performs a check on the fill-buffer for a given core-request. The address
     from the core is looked up in the fill-buffer in a fully-associative fashion. In case of a
     hit, the requested word is extracted from the hit line. This rule will also check if the
     request is an IO request.
    */
    rule rl_fillbuffer_check(!ff_core_request.first.fence);
      let req = ff_core_request.first;
      `logLevel( icache, 2, $format("[%2d]ICACHE: FB: Req:",id,fshow(req)))
    `ifdef supervisor
      Bit#(`paddr) phyaddr = ff_from_tlb.first.address;
    `else
      Bit#(`paddr) phyaddr = truncate(req.address);
    `endif
      Bit#(`wordbits) word_offset = truncate(phyaddr);
      Bit#(`causesize) lv_cause = `Inst_access_fault;

      let lv_polling_resp <- m_fillbuffer.mav_polling_response(phyaddr, ff_pending_req.notEmpty, 
                ff_pending_req.first.fbindex);
      `logLevel( icache, 0, $format("[%2d]ICACHE: FB: Polling Response:",id, 
                                    fshow(lv_polling_resp)))
      let lv_io_req = isIO(phyaddr, wr_cache_enable);

      let lv_response_word = lv_polling_resp.word ;
      let lv_hitmask = lv_polling_resp.waymask;
      let lv_linehit = lv_polling_resp.line_hit;
      let lv_wordhit = lv_polling_resp.word_hit;
      let lv_response_err = lv_polling_resp.err;

      let lv_response = IMem_core_response{word:lv_response_word, trap: unpack(lv_response_err),
                                          cause: lv_cause, epochs: req.epochs};
      if(lv_linehit)begin
        `logLevel( icache, 1, $format("[%2d]ICACHE: FB: Hit in Line:%b for Addr:%h",id, 
                                                                            lv_hitmask, phyaddr))
        if(lv_wordhit)begin
          wr_fb_state <= Hit;
          wr_fb_response <= lv_response;
          `logLevel( icache, 1, $format("[%2d]ICACHE: FB: Required Word found",id))
          rg_polling_mode <= False;
        end
        else begin
          wr_fb_state <= None;
          rg_polling_mode <= True;
          `logLevel( icache, 1, $format("[%2d]ICACHE: FB: Required word not available yet",id))
        end
      end
      else begin
        wr_fb_state <= Miss;
        rg_polling_mode <= False;
        `logLevel( icache, 1, $format("[%2d]ICACHE: FB: Miss",id))
      end
    endrule

    /*doc:rule: this rule fires when the requested word is either present in the SRAMs or the
    fill-buffer or an IO response is received. Only one of the three can be true at any point and
    thus do not require a priority anymore. Once the response has been enqueued into the
    ff_core_response fifo, the core request fifo (ff_core_request) is dequed and rg_miss_handling is
    de-asserted */
    rule rl_response_to_core(!ff_core_request.first.fence && 
                      ( wr_fault || wr_nc_state == Hit || wr_ram_state == Hit || wr_fb_state == Hit));

      let req = ff_core_request.first;
    `ifdef supervisor
      let pa_response = ff_from_tlb.first;
      Bit#(`paddr) phyaddr = pa_response.address;
    `else
      Bit#(`paddr) phyaddr = truncate(req.address);
    `endif
      Bit#(`setbits) set_index= phyaddr[v_setbits+v_blockbits+v_wordbits-1:v_blockbits+v_wordbits];
      Bit#(`wordbits) word_offset = truncate(phyaddr);
      IMem_core_response#(`respwidth,`iesize) lv_response;


      Bit#(3) onehot_hit = {pack(wr_ram_state==Hit || wr_fault), 
                            pack(wr_fb_state==Hit && !wr_fault), 
                            pack(wr_nc_state==Hit && !wr_fault)};
    `ifdef ASSERT
      if(!wr_fault)
        dynamicAssert(countOnes(onehot_hit) == 1, "More than one data structure shows a hit");
    `endif
      Vector#(3, IMem_core_response#(`respwidth,`iesize)) lv_responses;
      lv_responses[0] = wr_nc_response;
      lv_responses[1] = wr_fb_response;
      lv_responses[2] = wr_ram_response;

      lv_response = select(lv_responses,unpack(onehot_hit));

      if(wr_ram_state == Hit && !wr_fault) begin
        `logLevel( icache, 0, $format("[%2d]ICACHE: Response: Hit from SRAM",id))
        if(`irepl == 2) begin
          replacement.update_set(set_index, wr_ram_hitway);//wr_replace_line);
          wr_ram_hitset <= tagged Valid set_index;
        end
      end
      if(wr_fb_state == Hit && !wr_fault) begin
        `logLevel( icache, 0, $format("[%2d]ICACHE: Response: Hit from Fillbuffer: ",id,
                                      fshow(wr_fb_response)))
      `ifdef perfmonitors
        if(rg_handling_miss) begin
          wr_total_read_fb_hits <= 1;
        end
      `endif
      end
      if(wr_nc_state == Hit && !wr_fault) begin
        `logLevel( icache, 0, $format("[%2d]ICACHE: Response: Hit from NC",id))
      end
      
      lv_response.word = lv_response.trap?truncateLSB(req.address):lv_response.word;

      ff_core_request.deq;
    `ifdef supervisor
      ff_from_tlb.deq;
    `endif
      ff_core_response.enq(lv_response);
      rg_handling_miss <= False;

      Bit#(TLog#(`ifbsize)) _fbindex = ?;
      `logLevel( icache, 0, $format("[%2d]ICACHE: Responding to Core:",id, fshow(lv_response)))
    endrule
    
    /*doc:rule: This rule fires when the requested word is a miss in both the SRAMs and the
    Fill-buffer. This rule thereby forwards the requests to the network. IOs by default should
    be a miss in both the SRAMs and the FB and thus need to be checked only here. 
    This rule will set the rg_miss_handling to prevent further requests from the core being served*/
    rule rl_send_memory_request(wr_ram_state == Miss && wr_fb_state == Miss && !fb_full &&
        !wr_fault && ! ff_core_request.first.fence && ff_pending_req.notFull);
      let req = ff_core_request.first;
    `ifdef supervisor
      let pa_response = ff_from_tlb.first;
      Bit#(`paddr) phyaddr = pa_response.address;
    `else
      Bit#(`paddr) phyaddr = truncate(req.address);
    `endif
      Bit#(`setbits) set_index = phyaddr[v_setbits + v_blockbits + v_wordbits - 1 :
                                         v_blockbits + v_wordbits];
      let lv_io_req = isIO(phyaddr, wr_cache_enable);
      let burst_len = lv_io_req?0:(v_blocksize/valueOf(TDiv#(`ibuswidth,`respwidth)))-1;
      Bit#(3) burst_size = lv_io_req?2:fromInteger(valueOf(TLog#(TDiv#(`ibuswidth,8))));
      let shift_amount = valueOf(TLog#(TDiv#(`ibuswidth,8)));
      Bit#(`paddr) blockmask = '1 << shift_amount;
      // allocate a pending req which points to the new fb entry that is allotted.
      // align the address to be line-address aligned
      phyaddr= lv_io_req?phyaddr:(phyaddr & blockmask);
      Bit#(`blockbits) lv_blocknum = phyaddr[v_blockbits+v_wordbits-1:v_wordbits];
      ff_read_mem_request.enq(ICache_mem_readreq{ address   : phyaddr,
                                                  burst_len  : fromInteger(burst_len),
                                                  burst_size : burst_size,
                                                  io: lv_io_req
                                              });
      rg_handling_miss <= True;
      Bit#(TLog#(`ifbsize)) lv_alotted_fb = ?;

      // -- allocate a new entry in the fillbuffer
      if(!lv_io_req) begin
        lv_alotted_fb <- m_fillbuffer.mav_allocate_line(False, ?, phyaddr);
        `logLevel( icache, 0, $format("[%2d]ICACHE: MemReq: Allocating Fbindex:%d",id, lv_alotted_fb))
      end
      let pend_req = Pending_req{init_bank: lv_blocknum,io_request: lv_io_req, 
                                fbindex: lv_alotted_fb};
      ff_pending_req.enq(pend_req);
      if(lv_io_req) begin
        `logLevel( icache, 0, $format("[%2d]ICACHE: MemReq: Sending NC Request for Addr:%h",id,phyaddr))
      `ifdef perfmonitors
        wr_total_io_reads <= 1;
      `endif
      end
      else begin
    `ifdef perfmonitors
      wr_total_read_miss <= 1;
    `endif
        `logLevel( icache, 0, $format("[%2d]ICACHE: MemReq: Sending Line Request for Addr:%h",id, phyaddr))
      end
    `ifdef icache_ecc
      if(wr_ecc_fault) begin
        v_reg_valid[set_index] <= v_reg_valid[set_index] & ~wr_err_ways;
        `logLevel( icache, 0, $format("[%2d]ICACHE: Invalidating Faulty Ways: %b", id, wr_err_ways))
      end
    `endif
    endrule
    /*doc:rule: this rule will fill up the FB with the response from the memory, Once the last word
    has been received the entire line and tag are written in to the BRAM and the fill buffer is
    released in the next cycle*/
    rule rl_fill_from_memory(ff_pending_req.notEmpty && !ff_pending_req.first.io_request);
      let pending_req = ff_pending_req.first;
      let response = ff_read_mem_response.first;
      ff_read_mem_response.deq;
      m_fillbuffer.ma_fill_from_memory(response, pending_req.fbindex, pending_req.init_bank);
      `logLevel( icache, 0, $format("[%2d]ICACHE: FILL: Response from Memory:",id,fshow(response)))
      if(response.last)
        ff_pending_req.deq;
    endrule
    /*doc:rule: this rule is responsible for capturing the memory response for an IO request.*/
    rule rl_capture_io_response(ff_pending_req.notEmpty && ff_pending_req.first.io_request);
      let response = ff_read_mem_response.first;
      let req = ff_core_request.first;
      Bit#(`causesize) lv_cause = `Inst_access_fault ;
      Bit#(TLog#(TDiv#(`ibuswidth,8))) word_offset = truncate(req.address);
      let response_word = response.data >> {word_offset,3'b0};
      let lv_response = IMem_core_response{word:truncate(response_word), trap: response.err,
                                          cause: lv_cause, epochs: req.epochs};
      wr_nc_response <= lv_response;
      wr_nc_state <= Hit;
      ff_read_mem_response.deq;
      ff_pending_req.deq;
      `logLevel( icache, 2, $format("[%2d]ICACHE: NC Response from Memory: ",id,fshow(response)))
    endrule
    /*doc:rule: This rule fires when a replay of the last core-request is required because a release
     from the fill-buffer has updated the same set*/
    rule rl_perform_replay(rg_performing_replay);
      m_tag.ma_request(False, rg_recent_req, lv_release_addr, ?);
      m_data.ma_request(False, rg_recent_req, lv_release_line, ?, '1);
      rg_performing_replay <= False;
      `logLevel( icache, 0, $format("[%2d]ICACHE: Replaying Req. Index:%d",id,rg_recent_req))
    endrule

    /*doc:rule: This rule performs a release of a line from the fill-buffer into the SRAMs. A
    release is triggered under the following conditions: fill-buffer is full, fence operation is
    requested but not started, there is an idle cycle where the core is not requesting and thus
    the SRAMs can be accessed. Also the head of the fill-buffer should be valid and have all the
    words/bytes available to perform a release. To perform a release the replacement policy
    provides the way to be replaced which is then over-written with the address and data present
    in the fill-buffer*/
    rule rl_release_from_fillbuffer((fb_full || rg_fence_stall || lv_fill_oppurtunity) && 
                                    !fb_empty 
                                    && fb_headvalid && !rg_performing_replay);
      let addr = lv_release_addr;
      Bit#(`setbits) set_index = addr[v_setbits + v_blockbits + v_wordbits - 1 :
                                                                         v_blockbits + v_wordbits];

      let waynum <- replacement.line_replace(set_index,v_reg_valid[set_index]);
      `logLevel( icache, 2, $format("[%2d]ICACHE: Release: set%d way:%d valid:%b ",id,
                                    set_index, waynum,v_reg_valid[set_index][waynum] ))
      let lv_release_info = m_fillbuffer.mv_release_info;
      if(lv_release_err == 0)begin
      `ifdef perfmonitors
        wr_total_fb_releases <= 1;
      `endif
        v_reg_valid[set_index][waynum]<=1;
        m_tag.ma_request(True,set_index,lv_release_addr,waynum);
        m_data.ma_request(True,set_index,lv_release_line,waynum,'1);
        m_fillbuffer.ma_perform_release;
        `logLevel( icache, 0, $format("[%2d]ICACHE: Release: Upd Addr:%h set:%d way:%d data:%h", 
              id,lv_release_addr, set_index,waynum,lv_release_info.dataline))
        if(set_index == rg_recent_req )
          rg_performing_replay <= True;
        // ------------------ replacement policy updates -------------------------------------//

        if(`irepl == 1) begin// RR
          replacement.update_set(set_index, waynum);
        end
        else if(`irepl == 2) begin // PLRU
          if(wr_ram_hitset matches tagged Valid .i &&& i == set_index) begin
          end
          else
            replacement.update_set(set_index,waynum);
        end
        else if (`irepl == 0) // RANDOM
          replacement.update_set(set_index,waynum);
        // ---------------------------------------------------//
      end
      else begin
        // enter here only if the fillbuffer entry has an error
        m_fillbuffer.ma_perform_release;
      end
    endrule

    interface put_core_req=interface Put
      method Action put(ICache_core_request#(`vaddr,`iesize) req)
                        if( ff_core_response.notFull && !rg_fence_stall 
                                                     && !fb_full && !rg_performing_replay);
        `logLevel( icache, 0, $format("[%2d]ICACHE: Receiving request: ",id,fshow(req)))
      `ifdef perfmonitors
        wr_total_read_access <= 1;
      `endif
        Bit#(`paddr) phyaddr = truncate(req.address);
        Bit#(`setbits) set_index=req.fence?0:phyaddr[v_setbits+v_blockbits+v_wordbits-1:v_blockbits+v_wordbits];
        ff_core_request.enq(req);
        rg_fence_stall<=req.fence;
        rg_recent_req <= set_index;
        if(wr_cache_enable) begin
          m_tag.ma_request(False, set_index, lv_release_addr, ?);
          m_data.ma_request(False, set_index, lv_release_line, ?, '1);
        end
        `logLevel( icache, 0, $format("[%2d]ICACHE: set:%d",id,set_index))
        wr_takingrequest <= True;
      endmethod
    endinterface;
    method Action ma_cache_enable(Bool c);
      wr_cache_enable <= c;
    endmethod
    method Action ma_curr_priv (Bit#(2) c);
      wr_priv <= c;
    endmethod

    interface get_read_mem_req = toGet(ff_read_mem_request);
    interface put_read_mem_resp = toPut(ff_read_mem_response);
    interface get_core_resp = toGet(ff_core_response);
  `ifdef supervisor
    interface put_pa_from_tlb = toPut(ff_from_tlb);
  `endif
    `ifdef perfmonitors
      method mv_perf_counters = {wr_total_read_access, wr_total_io_reads ,wr_total_read_miss ,
                              wr_total_fb_releases, wr_total_read_fb_hits };
    `endif
    method mv_cache_available = ff_core_response.notFull && ff_core_request.notFull &&
        !rg_fence_stall && !fb_full && !rg_performing_replay ;
  `ifdef icache_ecc
    method mv_ded_data = wr_ded_data_log;
    method mv_sed_data = wr_sed_data_log;
    method mv_ded_tag = wr_ded_tag_log;
    method mv_sed_tag = wr_ded_tag_log;
    method Action ma_ram_request(IRamAccess access)if(!rg_fence_stall && !rg_performing_replay);
      Bit#(blocksize) _banks = 0;
      _banks[access.banks] = 1;
      if(!access.tag_data) begin // access tag;
        m_tag.ma_request(access.read_write, access.index, truncate(access.data), access.way);
      end
      else begin
        m_data.ma_request(access.read_write, access.index, duplicate(access.data) , access.way,
        _banks);
      end
      rg_access_req <= tagged Valid access;
    endmethod
    method Bit#(`respwidth) mv_ram_response if(!rg_fence_stall &&& !rg_performing_replay 
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
  endmodule: mkicache

endpackage: icache

