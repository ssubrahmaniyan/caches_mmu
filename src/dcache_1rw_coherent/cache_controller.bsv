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
package cache_controller;
  `include "Logger.bsv"
  `include "coherence.defines"
  import coherence_types :: * ;
  import FIFO :: * ;
  import FIFOF :: * ;
  import SpecialFIFOs :: * ;
  import GetPut :: * ;
  import Vector :: * ;
  import Semi_FIFOF :: * ;
  import ShaktiLink_Types :: * ;
  import dmem :: *;
  import cache_types :: * ;
  import common_tlb_types :: * ;
  import globals :: * ;

//  `define O TAdd#(TLog#(`NrCaches),1)
//  `define I TAdd#(TLog#(`NrCaches),1)

  interface Ifc_cache_controller#(numeric type o, numeric type i);
    interface Ifc_slc_master#(`paddr, TMul#(`dwords,`dblocks),o,i,SizeOf#(MessageType),
                            TLog#(`NrCaches), 1) master_side;
    interface Ifc_slc_slave#(`paddr, TMul#(`dwords,`dblocks),o,i,SizeOf#(MessageType),
                            TLog#(`NrCaches), 1) slave_side;

    interface Put#(DMem_request#(`vaddr, TMul#( `dwords, 8),`desize )) core_req;
    interface Get#(DMem_core_response#(TMul#(`dwords, 8), `desize )) core_resp;
    method Bool storebuffer_empty;
    method Action perform_store(Bit#(`desize ) currepoch);
    method Action cache_enable(Bool c);
    method Bool cacheable_store;
    method Bool cache_available;
    method Bool mv_commit_store_ready;
    (*always_ready,always_enabled*)
    method Action ma_criticality(Bit#(1) c);
      // ---------------------------------------------------------//
      // - ---------------- TLB interfaces ---------------------- //
  `ifdef supervisor
    interface Get#(DMem_core_response#(TMul#(`dwords, 8), `desize)) ptw_resp;
    interface Get#(PTWalk_tlb_request#(`vaddr)) req_to_ptw;
    interface Put#(PTWalk_tlb_response#(`ifdef RV64 54, 3 `else 32, 2 `endif )) resp_from_ptw;
    /*doc:method: method to receive the current satp csr from the core*/
    method Action ma_satp_from_csr (Bit#(`vaddr) s);

    /*doc:method: method to recieve the current privilege mode of operation*/
    method Action ma_curr_priv (Bit#(2) c);

    /*doc:method: method to receive the current values of the mstatus register*/
    method Action ma_mstatus_from_csr (Bit#(`vaddr) m);
    `ifdef pmp
      /*doc:method: */
      method Action ma_pmp_cfg ( Vector#(`PMPSIZE, Bit#(8)) pmpcfg) ;
      /*doc:method: */
      method Action ma_pmp_addr ( Vector#(`PMPSIZE, Bit#(`paddr)) pmpaddr);
    `endif
    interface Get#(DCache_core_request#(`vaddr, TMul#(`dwords, 8), `desize)) hold_req;
  `endif

`ifdef perfmonitors
  `ifdef dcache
    method Bit#(9) mv_dcache_perf_counters;
  `endif
  `ifdef supervisor
    method Bit#(1) mv_dtlb_perf_counters ;
  `endif
`endif
  endinterface

  function Req_channel#(a,w,o,i,op,u) fn_gen_req_pkt(Message#(a,w) m, Bit#(o) id, Bit#(u) user)
    provisos(Add#(a__, 2, i),Add#(b__, 4, op));
    let _r = Req_channel{ opcode: zeroExtend(pack(m.msgtype)),
                          len: 0,
                          size: 3,		                       
                          mode:0,
                          source: zeroExtend(pack(id)), 
                          dest: signExtend(pack(m.dst)), 
                          address:m.address, 
                          mask:'1,
                          data:m.cl,
                          user: user}; 
    return _r;
  endfunction
  
  function Fwd_channel#(a,w,o,i,op,u) fn_gen_fwd_pkt(Message#(a,w) m, Bit#(u) user)
    provisos(Add#(a__, 2, i),Add#(b__, 2, o),Add#(c__, 4, op));
    let _r = Fwd_channel{ opcode: zeroExtend(pack(m.msgtype)),
                          source: zeroExtend(pack(m.src)), 
                          dest:signExtend(pack(m.dst)), 
                          address:m.address, 
                          mask:'1,
                          data:m.cl,
                          user: user}; 
    return _r;
  endfunction
  
  function Resp_channel#(a,w,o,i,op,acks,u) fn_gen_resp_pkt(Message#(a,w) m, Bit#(u) user)
    provisos(Add#(a__, 2, i),Add#(c__, 4, op),Add#(d__, 2, o),Add#(e__, 1, acks));
    let _r = Resp_channel{ opcode: zeroExtend(pack(m.msgtype)),
                          acksExpected:zeroExtend(m.acksExpected),
                          last: True,
                          source: zeroExtend(pack(m.src)), 
                          dest: signExtend(pack(m.dst)), 
                          address:m.address, 
                          corrupt:0,
                          data:m.cl,
                          user: user}; 
    return _r;
  endfunction
  
  function Message#(a,w) fn_from_resp_pkt(Resp_channel#(a,w,o,i,op,acks,u) r)
    provisos(Add#(a__, 2, i),Add#(c__, 4, op),Add#(d__, 2, o),Add#(e__, 1, acks));
    let m = Message {address: r.address,
                        msgtype: unpack(truncate(r.opcode)),
                        src : unpack(truncate(r.source)),
                        dst : unpack(truncate(r.dest)),
                        acksExpected : truncate(r.acksExpected),
                        cl : r.data};
    return m;
  endfunction
  
  function Message#(a,w) fn_from_fwd_pkt(Fwd_channel#(a,w,o,i,op,u) r)
    provisos(Add#(a__, 2, i), Add#(b__, 2, o), Add#(c__, 4, op)); 
    let m = Message {address: r.address,
                        msgtype: unpack(truncate(r.opcode)),
                        src : unpack(truncate(r.source)),
                        dst : unpack(truncate(r.dest)),
                        acksExpected : 0,
                        cl : r.data};
    return m;
  endfunction
  
  
  /*doc:module: */
  (*preempts="rl_resp_message_from_fabric,rl_fwd_message_from_fabric"*)
  (*preempts="rl_send_resp2_to_fabric,rl_send_resp_to_fabric"*)
  (*preempts="rl_send_io_req_to_fabric,rl_send_resp_to_fabric"*)
  module mkcache_controller#(parameter Integer id)(Ifc_cache_controller#(o,i))
    provisos(
      Add#(a__, 2, i),
      Add#(b__, 2, o));
      Ifc_dmem dmem <- mkdmem(fromInteger(id));

    // This agent is responsible for sending out requests to the Directory
    // Since we are having the number of banks equal to the number of caches the source and
    // destinations ids are simply 2x number of caches
    Ifc_slc_master_agent#(`paddr, TMul#(`dwords,`dblocks),o,i,SizeOf#(MessageType),
                            TLog#(`NrCaches), 1) master <- mkslc_master_agent;

    // This agent is responsible to communication to other caches.
    // Since we are having the number of banks equal to the number of caches the source and
    // destinations ids are simply 2x number of caches
    Ifc_slc_slave_agent#(`paddr, TMul#(`dwords,`dblocks),o,i,SizeOf#(MessageType),
                            TLog#(`NrCaches), 1) slave <- mkslc_slave_agent;
  
    /*doc:wire: */
    Wire#(Bit#(1)) wr_criticality <- mkWire();
    /*doc:rule: */
    rule rl_send_req_to_fabric;
      let req <- dmem.mv_request_to_fabric.get;
      `logLevel( cc, 0, $format("CC[%2d]: Sending Request to Fabric:", id, fshow(req)))
      master.i_req_channel.enq(fn_gen_req_pkt(req,fromInteger(id), wr_criticality));
    endrule

    rule rl_send_io_req_to_fabric;
      let req <- dmem.mv_io_request_to_fabric.get;
      let _r = Req_channel{ opcode: req.read_write?zeroExtend(pack(PutM)):zeroExtend(pack(GetS)),
                          len: 0,
                          size: zeroExtend(req.size),		                       
                          mode:0,
                          source: fromInteger(id), 
                          dest: 5, 
                          address:req.addr, 
                          mask:'1,
                          data:zeroExtend(req.data),
                          user: wr_criticality}; 
      master.i_req_channel.enq(_r);
      `logLevel( cc, 0, $format("CC[%2d]: Sending IO Request to Fabric: Addr:%h", id,req.addr))
    endrule

    rule rl_send_resp_to_fabric;
      let resp <- dmem.mv_response_to_fabric.get;
      `logLevel( cc, 0, $format("CC[%2d]: Sending Response:",id,fshow(resp)))
      slave.i_resp_channel.enq(fn_gen_resp_pkt(resp, wr_criticality));
    endrule
    rule rl_send_resp2_to_fabric;
      let resp <- dmem.mv_response2_to_fabric.get;
      `logLevel( cc, 0, $format("CC[%2d]: Sending Response:",id,fshow(resp)))
      slave.i_resp_channel.enq(fn_gen_resp_pkt(resp, wr_criticality));
    endrule

    /*doc:rule: */
    rule rl_resp_message_from_fabric;
      let x <- pop_o(master.o_resp_channel);
      `logLevel( cc, 0, $format("CC[%2d]: Received Response:",id,fshow(fn_from_resp_pkt(x))))
      dmem.mv_response_from_fabric.put(fn_from_resp_pkt(x));
    endrule

    /*doc:rule: */
    rule rl_fwd_message_from_fabric;
      let x <- pop_o(master.o_fwd_channel);
      `logLevel( cc, 0, $format("CC[%2d]: Received Fwd:",id,fshow(fn_from_fwd_pkt(x))))
      dmem.mv_response_from_fabric.put(fn_from_fwd_pkt(x));
    endrule

    interface master_side = master.shaktilink_side;
    interface slave_side = slave.shaktilink_side;
      // -------------------- Cache related interfaces ------------//
    interface core_req = dmem.core_req;
    interface core_resp = dmem.core_resp;
    method storebuffer_empty = dmem.storebuffer_empty;
    method perform_store = dmem.perform_store;
    method cache_enable = dmem.cache_enable;
    method cacheable_store = dmem.cacheable_store;
    method cache_available = dmem.cache_available;
    method mv_commit_store_ready = dmem.mv_commit_store_ready;
    method Action ma_criticality(Bit#(1) c);
      wr_criticality <= c;
    endmethod
      // ---------------------------------------------------------//
      // - ---------------- TLB interfaces ---------------------- //
  `ifdef supervisor
    interface ptw_resp = dmem.ptw_resp;
    interface req_to_ptw = dmem.req_to_ptw;
    interface resp_from_ptw = dmem.resp_from_ptw;
    /*doc:method: method to receive the current satp csr from the core*/
    method ma_satp_from_csr = dmem.ma_satp_from_csr;

    /*doc:method: method to recieve the current privilege mode of operation*/
    method ma_curr_priv = dmem.ma_curr_priv;

    /*doc:method: method to receive the current values of the mstatus register*/
    method ma_mstatus_from_csr = dmem.ma_mstatus_from_csr;
    `ifdef pmp
      method ma_pmp_cfg = dmem.ma_pmp_cfg;
      method ma_pmp_addr = dmem.ma_pmp_addr;
    `endif
    interface hold_req = dmem.hold_req;
  `endif
`ifdef perfmonitors
  `ifdef dcache
    method mv_dcache_perf_counters = dmem.mv_dcache_perf_counters;
  `endif
  `ifdef supervisor
    method mv_dtlb_perf_counters = dmem.mv_dtlb_perf_counters;
  `endif
`endif
  `ifdef dtim
    /*doc:method: */
    method ma_dtim_memory_map = dmem.ma_dtim_memory_map;
  `endif
  endmodule

//  (*synthesize*)
//  module mkcc_inst#(parameter Integer id)(Ifc_cache_controller#(`paddr, TDiv#(`linesize,8), TAdd#(TLog#(`NrCaches),1), 
//                          TAdd#(TLog#(`NrCaches),1),
//                      SizeOf#(MessageType),TLog#(`NrCaches),0));
//	  let  ifc();
//  	mk_cache_controller#(id) _temp(ifc);
//	  return (ifc);
//  endmodule
endpackage

