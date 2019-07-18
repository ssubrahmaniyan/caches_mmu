/* 
Copyright (c) 2018, IIT Madras All rights reserved.

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
package dm_writethrough_tb;
  import Vector::*;
  import FIFOF::*;
  import DReg::*;
  import SpecialFIFOs::*;
  import BRAMCore::*;
  import FIFO::*;
  import GetPut::*;
  //import dcache_nway::*;
  import dm_writethrough_dcache:: *;
  import test_caches::*;
  //import icache_dm::*;
  import mem_config::*;
  import BUtils ::*;
  import RegFile::*;
  import device_common::*;
  import Vector::*;
  `include "Logger.bsv"
  
  `define sets 64
  `define word_size 4
  `define block_size 8
  `define addr_width 32
  `define ways 1
  `define repl RROBIN

  (*synthesize*)
  module mktest(Ifc_test_caches#(`word_size , `block_size , `sets , `ways ,32,`addr_width));
    let ifc();
    mktest_caches _temp(ifc);
    return (ifc);
  endmodule

  function Bool isIO(Bit#(32) addr, Bool cacheable);
    if(!cacheable)
      return True;
    else if( addr < 4096)
      return True;
    else
      return False;    
  endfunction


  (*synthesize*)
  module mkdcache(Ifc_cache#(`addr_width, 32, `word_size, `block_size ,`sets));
    let ifc();
    mk_cache _temp(ifc);
    return (ifc);
  endmodule

  (*synthesize*)
  module mkdcache_tb(Empty);

  String tb= "";

  let dcache <- mkdcache();
  let testcache<- mktest();

  RegFile#(Bit#(10), Bit#(TAdd#(TAdd#(TMul#(`word_size, 8), 8), `addr_width ) )) stim <- 
                                                                      mkRegFileFullLoad("test.mem");
  RegFile#(Bit#(10), Bit#(1))  e_meta <- mkRegFileFullLoad("gold.mem");
  RegFile#(Bit#(19), Bit#(TMul#(`word_size, 8))) data <- mkRegFileFullLoad("data.mem");

  Reg#(Bit#(32)) index<- mkReg(0);
  Reg#(Bit#(32)) e_index<- mkReg(0);
  Reg#(Maybe#(Mem_Req#(`addr_width, TMul#(`word_size,8)))) mem_req<- mkReg(tagged Invalid);
  Reg#(Bit#(8)) rg_read_burst_count <- mkReg(0);
  Reg#(Bit#(8)) rg_write_burst_count <- mkReg(0);
  Reg#(Bit#(32)) rg_test_count <- mkReg(1);

  FIFOF#(Bit#(TAdd#(TAdd#(TMul#(`word_size, 8), 8), `addr_width ) )) ff_req <- mkSizedFIFOF(32);

    
  let verbosity=`VERBOSITY; 

//  `ifdef perf
//  Vector#(5,Reg#(Bit#(32))) rg_counters <- replicateM(mkReg(0));
//  rule performance_counters;
//    Bit#(5) incr = dcache.perf_counters;
//    for(Integer i=0;i<5;i=i+1)
//      rg_counters[i]<=rg_counters[i]+zeroExtend(incr[i]);
//  endrule
//  `endif

//  rule enable_disable_cache;
//    dcache.cache_enable(True);
//  endrule
  rule display_endline;
    `logLevel( tb, 0, $format(""))
  endrule

  rule core_req;
    let stime<-$stime;
    if(stime>=(20)) begin
      let req=stim.sub(truncate(index));
      // read/write : delay/nodelay : Fence/noFence : Null 
      Bit#(8) control = req[`addr_width + 7: `addr_width ];
      Bit#(2) readwrite=control[7:6];
      Bit#(3) size=control[5:3];
      Bit#(1) delay=control[2];
      Bit#(1) fence=control[1];
      Bit#(TAdd#(`addr_width ,  8)) request = truncate(req);
      Bit#(TMul#(`word_size, 8)) writedata=truncateLSB(req);

      if(request!=0) begin // // not end of simulation
        if(request!='1 && delay==0)
          dcache.ma_core_request(Core_Req{op: unpack(truncate(readwrite)), 
                                      data_addr: truncate(req),
                                      data_write: writedata,
                                      size: size,
                                      fence: unpack(fence),
                                      cache_enable: False}); 
        index<=index+1;
        `logLevel( tb, 0, $format("TB: Sending core request for addr: %h",req))
      end
      if((delay==0) || request=='1)begin // if not a fence instruction
        `logLevel( tb, 0, $format("TB: Enqueuing request: %h",req))
        ff_req.enq(req);
      end
    end
  endrule

  rule end_sim;
    Bit#(TAdd#(`addr_width ,  8)) request = truncate(ff_req.first());
    if(request==0)begin
    `ifdef perf
      for(Integer i=0;i<5;i=i+1)
        `logLevel( tb, 0, $format("TB: Counter-",countName(i),": %d",rg_counters[i]))
    `endif
      $display($time, "\tTB: All Tests PASSED. Total TestCount: %d", rg_test_count-1);
      $finish(0);
    end
  endrule

  rule checkout_request(ff_req.first[39:0]=='1);
    ff_req.deq;
    rg_test_count<=rg_test_count+1;
    `logLevel( tb, 0, $format("TB: ********** Test:%d PASSED****",rg_test_count))
  endrule


  rule core_resp(ff_req.first[39:0]!='1);
    let req = ff_req.first;
    ff_req.deq();
    Bit#(8) control = req[`addr_width + 7: `addr_width ];
    Bit#(2) readwrite=control[7:6];
    Bit#(3) size=control[5:3];
    Bit#(1) delay=control[2];
    Bit#(1) fence=control[1];
    Bit#(TMul#(`word_size, 8)) writedata=truncateLSB(req);

    if(fence==0)begin
      let resp <- dcache.mv_core_resp;
      let expected_data<-testcache.memory_operation(truncate(req),readwrite,size,writedata);
      Bool datafail=False;
  
      if(expected_data!=resp.data_read)begin
          `logLevel( tb, 0, $format("TB: Output from cache is wrong for Req: %h",req))
          `logLevel( tb, 0, $format("TB: Expected: %h, Received: %h",expected_data,resp.data_read))
          datafail=True;
      end

      if(datafail)begin
        `logLevel( tb, 0, $format("TB: Test: %d Failed",rg_test_count))
        $finish(0);
      end
      else
        `logLevel( tb, 0, $format("TB: Core received correct response: ",fshow(resp)," For req: %h",req))
    end
  endrule

  rule read_mem_request(mem_req matches tagged Invalid);
    let req<- dcache.mv_mem_req;
    if (req.op == Store)begin
      let v_wordbits = valueOf(TLog#(`word_size));
      Bit#(19) index = truncate(req.l_addr>>v_wordbits);
      let loaded_data= data.sub(index);
      Bit#(TMul#(`word_size, 8)) mask = req.burst_size[1:0]==0?'hFF:req.burst_size[1:0]==1?'hFFFF:req.burst_size[1:0]==2?'hFFFFFFFF:'1;
      Bit#(TAdd#(3,TLog#(`word_size))) shift_amt= {req.l_addr[v_wordbits-1:0],3'b0};
      mask= mask<<shift_amt;
      req.write_data = case (req.burst_size[1:0])
          'b00: duplicate(req.write_data[7:0]);
          'b01: duplicate(req.write_data[15:0]);
          'b10: duplicate(req.write_data[31:0]);
          default: req.write_data;
        endcase;
      `logLevel( tb, 0, $format("TB: Addr:%h LoadedData:%h WriteData:%h Mask:%h",req.l_addr,loaded_data,
      req.write_data, mask))
      Bit#(TMul#(`word_size,8)) write_word=~mask&loaded_data|mask&req.write_data;
      data.upd(index,write_word);
      if(req.burst_len == 0)
        dcache.ma_mem_resp(Mem_Resp{line_read: loaded_data, last: True, bus_err: False});
      `logLevel( tb, 0, $format("TB: Updating Memory index: %d with: %h burst: %d", 
        index,write_word,req.burst_len))
    end
    else begin
      mem_req<=tagged Valid req;
      `logLevel( tb, 0, $format("TB: Memory Read request",fshow(req)))
    end
  endrule

  rule read_mem_resp(mem_req matches tagged Valid .req);
    if(rg_read_burst_count == req.burst_len) begin
      rg_read_burst_count<=0;
      mem_req<=tagged Invalid;
    end
    else begin
      rg_read_burst_count<=rg_read_burst_count+1;
      mem_req <= tagged Valid Mem_Req{ op: req.op, 
                                       l_addr: axi4burst_addrgen(req.burst_len,req.burst_size,2,req.l_addr),
                                      burst_len: req.burst_len,
                                      burst_size: req.burst_size}; // parameterize
    end
    let v_wordbits = valueOf(TLog#(`word_size));
    Bit#(19) index = truncate(req.l_addr>>v_wordbits);
    let dat=data.sub(truncate(index));
    dcache.ma_mem_resp(Mem_Resp{line_read: dat, last: rg_read_burst_count==req.burst_len, bus_err: False});
    `logLevel( tb, 0, $format("TB: Memory Read index: %d responding with: %h ",index,dat))
  endrule
//  
//  rule write_mem_request(write_mem_req matches tagged Invalid);
//    let req<- dcache.write_mem_req.get;
//    write_mem_req<=tagged Valid req;
//    `logLevel( tb, 0, $format("TB: Memory Write request",fshow(req)))
//  endrule
//
//  rule write_mem_resp(write_mem_req matches tagged Valid .req);
//    let {addr, burst, size, writedata}=req;
//      write_mem_req<=tagged Invalid;
//      dcache.write_mem_resp.put(False);
//      `logLevel( tb, 0, $format("TB: Sending write response back"))
//    
//    let v_wordbits = valueOf(TLog#(`word_size));
//    Bit#(19) index = truncate(addr>>v_wordbits);
//    let loaded_data=data.sub(index);
//
//    Bit#(32) mask = size[1:0]==0?'hFF:size[1:0]==1?'hFFFF:size[1:0]==2?'hFFFFFFFF:'1;
//    Bit#(TLog#(`word_size)) shift_amt=addr[v_wordbits-1:0];
//    mask= mask<<shift_amt;
//
//    Bit#(32) write_word=~mask&loaded_data|mask&truncate(writedata);
//    data.upd(index,write_word);
//    `logLevel( tb, 0, $format("TB: Updating Memory index: %d with: %h burst: %d", 
//      index,write_word,burst);
//  endrule

endmodule

endpackage

