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
Author: Neel Gala,Deepa N. Sarma
Email id: neelgala@gmail.com
Details:
--------------------------------------------------------------------------------------------------
*/
package imem_tb;

  `define sets 64
  `define word_size 4
  `define block_size 16
  `define addr_width 32
  `define ways 4
  `define repl RROBIN

  import imem::*;
  import cache_types::*;
  import mem_config::*;
  import GetPut::*;
  import FIFOF::*;
  import BUtils ::*;
  import FIFOF ::*;
  import DReg::*;
  import RegFile::*;
  import device_common::*;
  import Vector::*;
  import Connectable::*;
  import test_caches::*;


  (*synthesize*)
  module mktest(Ifc_test_caches#(`iwords , `iblocks , `isets , `iways ,32,`paddr ));
    let ifc();
    mktest_caches _temp(ifc);
    return (ifc);
  endmodule
 
  (*synthesize*)
  module mkimem_tb(Empty);

  Ifc_imem imem <- mkimem;
  let testcache<- mktest();

  RegFile#(Bit#(10), Bit#(TAdd#(TAdd#(TMul#(`iwords, 8), 8), `paddr ) )) stim <- 
                                                                      mkRegFileFullLoad("test.mem");
  RegFile#(Bit#(10), Bit#(1))  e_meta <- mkRegFileFullLoad("gold.mem");
  RegFile#(Bit#(19), Bit#(TMul#(`iwords, 8))) data <- mkRegFileFullLoad("data.mem");

  Reg#(Bit#(32)) index<- mkReg(0);
  Reg#(Bit#(32)) e_index<- mkReg(0);
  Reg#(Maybe#(ICache_read_request#(`paddr))) read_mem_req<- mkReg(tagged Invalid);
  Reg#(Bit#(8)) rg_read_burst_count <- mkReg(0);
  Reg#(Bit#(32)) rg_test_count <- mkReg(1);

  FIFOF#(Bit#(TAdd#(TAdd#(TMul#(`iwords, 8), 8), `paddr ) )) ff_req <- mkSizedFIFOF(32);
  `ifdef pysimulate
    FIFOF#(Bit#(1)) ff_meta <- mkSizedFIFOF(32);
  `endif

    
  let verbosity=`VERBOSITY;

  rule extra_line;
    $display("\n",$time);
  endrule
  `ifdef perf
  Vector#(5,Reg#(Bit#(32))) rg_counters <- replicateM(mkReg(0));
  
  rule performance_counters;
    Bit#(5) incr = icache.perf_counters;
    for(Integer i=0;i<5;i=i+1)
      rg_counters[i]<=rg_counters[i]+zeroExtend(incr[i]);
  endrule
  `endif

  rule enable_disable_cache;
    imem.cache_enable(True);
  endrule

  rule tlb_csr_info;
    imem.satp_from_csr.put(0);
    imem.curr_priv.put('d3);
  endrule

  rule core_req;
    let stime<-$stime;
    if(stime>=(20)) begin
      let req=stim.sub(truncate(index));
      // read/write : delay/nodelay : Fence/noFence : Null 
      Bit#(8) control = req[`paddr + 7: `paddr ];
      Bit#(2) readwrite=control[7:6];
      Bit#(3) size=control[5:3];
      Bit#(1) delay=control[2];
      Bit#(1) fence=control[1];
      Bit#(TAdd#(`paddr ,  8)) request = truncate(req);
      Bit#(TMul#(`iwords, 8)) writedata=truncateLSB(req);

      if(request!=0) begin // // not end of simulation
        if(request!='1 && delay==0) begin
          imem.core_req.put(tuple4(zeroExtend(req[31:0]),unpack(fence),False,0));
        end
        index<=index+1;
        $display($time,"\tTB: Sending core request for addr: %h",req);
      end
      if((delay==0 && fence!=1) || request=='1)begin // if not a fence instruction
        $display($time,"\tTB: Enquiing request: %h",req);
        ff_req.enq(req);
        `ifdef pysimulate
          ff_meta.enq(e_meta.sub(truncate(index)));
        `endif
      end
    end
  endrule

  rule end_sim;
    Bit#(TAdd#(`paddr ,  8)) request = truncate(ff_req.first());
    if(request==0)begin
    `ifdef perf
      for(Integer i=0;i<5;i=i+1)
        $display($time,"\tTB: Counter-",countName(i),": %d",rg_counters[i]);
    `endif
      $display($time, "\tTB: All Tests PASSED. Total TestCount: %d", rg_test_count-1);
      $finish(0);
    end
  endrule

  rule checkout_request(ff_req.first[39:0]=='1);
    ff_req.deq;
    `ifdef pysimulate
      ff_meta.deq;
    `endif
    rg_test_count<=rg_test_count+1;
    $display($time,"\tTB: ********** Test:%d PASSED****",rg_test_count);
  endrule


  rule core_resp(ff_req.first[39:0]!='1);
    let resp <- imem.core_resp.get();
    let req = ff_req.first;
    ff_req.deq();
    Bit#(8) control = req[`paddr + 7: `paddr ];
    Bit#(2) readwrite=control[7:6];
    Bit#(3) size=control[5:3];
    Bit#(1) delay=control[2];
    Bit#(1) fence=control[1];
    Bit#(TMul#(`iwords, 8)) writedata=truncateLSB(req);

    if(fence==0)begin
      let expected_data<-testcache.memory_operation(truncate(req),readwrite,size,writedata);
      Bool metafail=False;
      Bool datafail=False;
  
      `ifdef pysimulate
       if(expected_meta!=meta)begin
         $display($time,"\tTB: Meta does not match for Req: %h",req);
         $display($time,"\tTB: Expected Meta: %b Received Meta:%b", expected_meta,meta);
         metafail=True;
       end
      `endif
      if(expected_data!=tpl_1(resp))begin
          $display($time,"\tTB: Output from cache is wrong for Req: %h",req);
          $display($time,"\tTB: Expected: %h, Received: %h",expected_data,tpl_1(resp));
          datafail=True;
      end

      if(metafail||datafail)begin
        $display($time,"\tTB: Test: %d Failed",rg_test_count);
        $finish(0);
      end
      else
        $display($time,"\tTB: Core received correct response: ",fshow(resp)," For req: %h",req);
    end
    else begin
      $display($time,"\tTB: Response from Cache:",fshow(resp));
    end
  endrule

  rule read_mem_request(read_mem_req matches tagged Invalid);
    let req<- imem.read_mem_req.get;
    read_mem_req<=tagged Valid req;
    $display($time,"\tTB: Memory Read request",fshow(req));
  endrule

  rule read_mem_resp(read_mem_req matches tagged Valid .req);
    let {addr, burst, size}=req;
    if(rg_read_burst_count == burst) begin
      rg_read_burst_count<=0;
      read_mem_req<=tagged Invalid;
    end
    else begin
      rg_read_burst_count<=rg_read_burst_count+1;
      read_mem_req <= tagged Valid tuple3(axi4burst_addrgen(burst,size,2,addr),burst,size); // parameterize
    end
    let v_wordbits = valueOf(TLog#(`iwords));
    Bit#(19) index = truncate(addr>>v_wordbits);
    let dat=data.sub(truncate(index));
    imem.read_mem_resp.put(tuple3(dat,rg_read_burst_count==burst,False));
    $display($time,"\tTB: Memory Read index: %d responding with: %h ",index,dat);
  endrule

endmodule

endpackage
