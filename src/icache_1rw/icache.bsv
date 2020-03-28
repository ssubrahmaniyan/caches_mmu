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

Working Principle
-----------------

A request from the core is enqueued into a request fifo (``ff_core_request``). On a hit within the 
cache, the required word is enqueued into the response fifo (``ff_core_response``) which is read by 
the core. On a miss, a read request for the line is sent to the fabric via the 
``ff_read_mem_request`` and simultaneously an entry in the fill-buffer is allotted to capture the 
fabric response. The responses from the fabric are enqueued in the ``ff_read_mem_response`` fifo. 
When a dirty line needs to be evicted, a write request for that line is enqueued into 
``ff_write_mem_request`` fifo and the response of this write is captured in ``ff_write_mem_response`` 
fifo.

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

1. **For a Load request**: if it's a hit, the requested word is enqueued in ``ff_core_response`` 
   fifo in the same cycle as the tag-match. When it's a hit in the FB, before enqueuing the response, 
   we check if there is a pending store to the same word, if so we enqueue the updated word 
   accordingly. Since, the SRAMs are not updated with stores immediately, the store-buffer is 
   looked up only in the case of a fill-buffer hit.

2. **For a Load request**: If it's a miss, the address (after making it word aligned) is 
   enqueued into the ``ff_read_mem_request`` fifo to be sent to fabric. Simultaneously, a 
   fill-buffer entry is assigned to capture the line requested from the fabric. Once the 
   requested word is captured in the fill-buffer (while rest of the line is still getting filled), 
   it is enqueued into the ``ff_core_response`` to be sent to core and the entry in ``ff_core_request`` 
   is dequeued. We are now ready to service the subsequent request in the next cycle.

3. **For a store request**: If it's a hit in the fill-buffer, a store buffer entry is allotted to 
   store the data to be written and response is enqueued in the ``ff_core_response`` fifo 
   (response being that it is store hit). If it's a hit in the SRAM, in addition to performing 
   actions that of a fill-buffer hit, the line is copied into the fill-buffer (since all stores 
   are performed here) while making it invalid in the SRAM.

4. **For a store request**: If it's a miss, request would be sent to fabric as was when 
   load miss occurred. Once the requested word is captured in the fill-buffer, the actions that 
   follow are similar to those of store hit in fill-buffer.

5. **For atomic requests**: The control is similar to that store-requests apart from the fact 
   that the updated word undergoes arithmetic op before being written in the store-buffer.

Release from fill-buffer
^^^^^^^^^^^^^^^^^^^^^^^^

The necessary condition for a release of a line from fill-buffer and its updation into SRAM is 
that the line itself is valid and all the words in the line are present and updated by store-buffer 
if necessary. If there is any pending store in the store buffer, the line won't be released. 
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

Now given the release can actually take place, following scenarios would arise :-

1. If the line in the SRAM being evicted is not dirty, then we can directly put a write request 
   (of the line being released) to the SRAM along with updation of the SRAM dirty and valid bits 
   accordingly.
2. If the line being replaced is dirty, we need to write it back to fabric. So first we put a read 
   request to SRAM for the dirty line, in the next cycle we enqueue this line in the 
   ``ff_write_mem_request`` for it to be written back in fabric while also putting a SRAM write 
   request for line being released.

Once a release is done from the fill-buffer, that particular entry in the fill-buffer is 
invalidated and thus is available for new allocation on a miss or a store-hit.

The fill-buffer is implemented as a circular-buffer with head and tail pointer-registers.

Fence operation
^^^^^^^^^^^^^^^

A cache-flush operation is initiated when the core presents a fence instruction. A fence operation 
can only start if following conditions are met:

1. the entire fill-buffer is empty (i.e. all lines are updated in the SRAM).
2. there are not pending write-backs to fabric 
3. the store-buffer is empty.

In case of the D-Cache, the fence operation is a single cycle operation if the global-dirty bit 
is clear, where all the lines are invalidated and the dirty bits of each line are cleared as well. 
If the global-dirty bit is set, the fence operation in the D-Cache traverses through each set and 
identifies which lines need to the written back to the fabric. Traversing a set, requires 
traversing each of the way and checking if a write-back is required. A set is ignored 
if there are no valid dirty lines in the set. At the end of each set traversal, the valid and 
dirty bits of the entire set are cleared. The fence operation in the D-Cache is only over when the 
last set has been completely traversed. Until this point, not new requests are entertained from the 
core-side.

--------------------------------------------------------------------------------------------------
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
  import common_tlb_types:: * ;
  import ecc_hamming :: * ;


  import io_func :: * ;
 
  `define respwidth TMul#(`iwords,8)
  `define linewidth TMul#(`iblocks, TMul#(`iwords,8))
  `define setbits TLog#(`isets)
  `define blockbits TLog#(`iblocks)
  `define wordbits TLog#(`iwords)
  `define tagbits TSub#(`paddr, TAdd#(TAdd#(`wordbits, `blockbits),`setbits))
  `define ieccsize TAdd#(2, TLog#(TMul#(`iwords,8)))

  typedef struct{
    Bit#(TLog#(blocks)) init_bank;
    Bit#(TLog#(fbsize)) fbindex;
    Bool io_request;
  } Pending_req#(numeric type fbsize, numeric type blocks)
                deriving(Bits, Eq, FShow);


  interface Ifc_icache;
    interface Put#(ICache_core_request#(`vaddr,`iesize)) put_core_req;
    interface Get#(IMem_core_response#(TMul#(`iwords,8),`iesize)) get_core_resp;
    interface Get#(ICache_mem_readreq#(`paddr)) get_read_mem_req;
    interface Put#(ICache_mem_readresp#(`ibuswidth)) put_read_mem_resp;
  `ifdef supervisor
    interface Get#(IMem_core_response#(TMul#(`iwords,8),`iesize)) get_ptw_resp;
    interface Put#(ITLB_core_response#(`paddr)) put_pa_from_tlb;
  `endif
  `ifdef perfmonitors
    method Bit#(5) mv_perf_counters;
  `endif
    method Action ma_cache_enable(Bool c);
    method Bool mv_cache_available;
  `ifdef icache_ecc
    method Maybe#(ECC_icache_data#(`paddr, `iways, `iblocks)) mv_ded_data;
    method Maybe#(ECC_icache_data#(`paddr, `iways, `iblocks)) mv_sed_data;
    method Maybe#(ECC_icache_tag#(`paddr, `iways)) mv_ded_tag;
    method Maybe#(ECC_icache_tag#(`paddr, `iways)) mv_sed_tag;
    method Action ma_ram_request(RamAccess access);
    method Bit#(`respwidth) mv_ram_response;
  `endif
  endinterface
  // both update rg_handling_miss but can never fire together
  (*conflict_free="rl_send_memory_request, rl_response_to_core"*)
  (*conflict_free="rl_response_to_core,rl_ram_check"*)
  (*conflict_free="rl_send_memory_request,rl_release_from_fillbuffer"*)
  (*conflict_free="rl_fill_from_memory, rl_release_from_fillbuffer"*)
  // the following rules access the mv_read_response from of data and tag modules which is a
  // conflict. However, these two rules will never fire together
  (*mutually_exclusive="rl_release_from_fillbuffer, rl_ram_check"*)
`ifdef icache_ecc
  (*preempts="ma_ram_request,rl_release_from_fillbuffer"*)
`endif
  (*synthesize*)
  module mkicache#( parameter Bit#(32) id)(Ifc_icache);

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

    let m_data <- mkinst_data(id);
    let m_tag <- mkinst_tag(id);
    let m_fillbuffer <- mkinst_fb_v2(id);
    // ----------------------- FIFOs to interact with interface of the design -------------------//
    /*doc:fifo: This fifo stores the request from the core.*/
    FIFOF#(ICache_core_request#(`vaddr, `iesize)) ff_core_request <- mkSizedFIFOF(2);
    /*doc:fifo: This fifo stores the response that needs to be sent back to the core.*/
    FIFOF#(IMem_core_response#(`respwidth,`iesize))ff_core_response <- mkBypassFIFOF();
  `ifdef supervisor
    /*doc:fifo: This fifo stores the response that needs to be sent back to the ptw.*/
    FIFOF#(IMem_core_response#(`respwidth,`iesize))ff_ptw_response <- mkBypassFIFOF();
  `endif
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

    /*doc:reg: When tru indicates that a miss is being catered to*/
    Reg#(Bool) rg_handling_miss <- mkReg(False);

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

  `ifdef icache_ecc
    /*doc:reg: register to hold the access request performed by the external CCSU module*/
    Reg#(Maybe#(RamAccess)) rg_access_req <- mkDReg(tagged Invalid);
  `endif

    // -------------------- Wire declarations ----------------------------------------------//
    /*doc:wire: boolean wire indicating if the cache is enabled. This is controlled through a csr*/
    Wire#(Bool) wr_cache_enable<-mkWire();
    /*doc:wire: this wire indicates if there was a fault in the address or during translation*/
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
    /*doc:wire: wire to pulse on every eviction from the cache*/
    Wire#(Bit#(1)) wr_total_evictions <- mkDWire(0);
    /*doc:wire: wire to pulse on every release from fill-buffer to RAMS*/
    Wire#(Bit#(1)) wr_total_fb_releases <- mkDWire(0);
    /*doc:wire: wire to pulse on  hit in fill-buffer for read ops*/
    Wire#(Bit#(1)) wr_total_read_fb_hits <- mkDWire(0);
  `endif
    Wire#(Bool) wr_takingrequest <- mkDWire(False);

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
      3. Store-buffer is not being allocated in the current cycle
      4. The set being released to is not the most recent set accessed by the core.
    */
    Bool fill_oppurtunity = (!ff_core_request.notEmpty && !wr_takingrequest)  &&
         /*countOnes(fb_valid)>0 &&*/ (fillindex != rg_recent_req); 
    
    // --------------------------- Rule operations ------------------------------------- //

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

    /*doc:rule: This rule checks the tag rams for a hit*/
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
    fill-buffer or if there was an error in the request. Since we are re-using the
    ff_write_mem_response fifo to send out cacheable and MMIO ops, it is necessary that we make sure
    that this fifo is not Full before responding back to the core. If it is not empty then the core
    could initiate a commit-store which could get dropped since the method performing the cannot
    fire since the fifo is full and thus the store being dropped.*/
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
    be a miss in both the SRAMs and the FB and thus need to be checked only here */
    rule rl_send_memory_request(wr_ram_state == Miss && wr_fb_state == Miss && !fb_full &&
        !wr_fault && !rg_handling_miss && ! ff_core_request.first.fence && ff_pending_req.notFull);
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
      Bit#(3) burst_size = fromInteger(valueOf(TLog#(TDiv#(`ibuswidth,8))));
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
      let lv_response = IMem_core_response{word:truncate(response.data), trap: response.err,
                                          cause: lv_cause, epochs: req.epochs};
      wr_nc_response <= lv_response;
      wr_nc_state <= Hit;
      ff_read_mem_response.deq;
      ff_pending_req.deq;
      `logLevel( icache, 2, $format("[%2d]ICACHE: NC Response from Memory: ",id,fshow(response)))
    endrule
    rule rl_perform_replay(rg_performing_replay);
      m_tag.ma_request(False, rg_recent_req, lv_release_addr, ?);
      m_data.ma_request(False, rg_recent_req, lv_release_line, ?, '1);
      rg_performing_replay <= False;
      `logLevel( icache, 0, $format("[%2d]ICACHE: Replaying Req. Index:%d",id,rg_recent_req))
    endrule

    rule rl_release_from_fillbuffer((fb_full || rg_fence_stall || fill_oppurtunity) && 
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

    interface get_read_mem_req = toGet(ff_read_mem_request);
    interface put_read_mem_resp = toPut(ff_read_mem_response);
    interface get_core_resp = toGet(ff_core_response);
  `ifdef supervisor
    interface get_ptw_resp = toGet(ff_ptw_response);
    interface put_pa_from_tlb = toPut(ff_from_tlb);
  `endif
    `ifdef perfmonitors
      method mv_perf_counters = {wr_total_read_access, wr_total_io_reads ,wr_total_read_miss ,
                              wr_total_fb_releases, wr_total_evictions };
    `endif
    method mv_cache_available = ff_core_response.notFull && ff_core_request.notFull &&
        !rg_fence_stall && !fb_full && !rg_performing_replay ;
  `ifdef icache_ecc
    method mv_ded_data = wr_ded_data_log;
    method mv_sed_data = wr_sed_data_log;
    method mv_ded_tag = wr_ded_tag_log;
    method mv_sed_tag = wr_ded_tag_log;
    method Action ma_ram_request(RamAccess access)if(!rg_fence_stall && !rg_performing_replay);
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
  endmodule

endpackage

