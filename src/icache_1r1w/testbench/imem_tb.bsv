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
  import test_icache::*;
  import globals :: * ;
  `include "Logger.bsv"


  (*synthesize*)
  module mktest(Ifc_test_caches#(`iwords , `iblocks , `isets , `iways ,32,`paddr, `ibuswidth ));
    let ifc();
    mktest_caches _temp(ifc);
    return (ifc);
  endmodule
 
  (*synthesize*)
  module mkimem_tb(Empty);

  Ifc_imem imem <- mkimem;
  let testcache<- mktest();

  RegFile#(Bit#(18), Bit#(TAdd#( 4, `paddr ))) stim <- mkRegFileFullLoad("test.mem");
  RegFile#(Bit#(19), Bit#(`ibuswidth)) data <- mkRegFileFullLoad("data.mem");

  Reg#(Bit#(32)) index<- mkReg(0);
  Reg#(Bit#(32)) e_index<- mkReg(0);
  Reg#(Maybe#(ICache_mem_request#(`paddr))) read_mem_req<- mkReg(tagged Invalid);
  Reg#(Bit#(8)) rg_read_burst_count <- mkReg(0);
  Reg#(Bit#(32)) rg_test_count <- mkReg(1);

  FIFOF#(Bit#(TAdd#(4, `paddr ) )) ff_req <- mkSizedFIFOF(32);

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

`ifdef supervisor
  rule tlb_csr_info;
    imem.ma_satp_from_csr(0);
    imem.ma_curr_priv('d3);
  endrule
 `endif

  rule core_req;
    let stime<-$stime;
    if(stime>=(20)) begin
      let req=stim.sub(truncate(index));
      // read/write : delay/nodelay : Fence/noFence : Null 
      Bit#(4) control = req[`paddr + 3: `paddr ];
      Bit#(1) readwrite=control[3];
      Bit#(1) delay=control[2];
      Bit#(1) fence=control[1];
      Bit#(TAdd#(`paddr ,  4)) request = truncate(req);

      if(request!=0) begin // // not end of simulation
        if(request!='1 && delay==0) begin
          imem.core_req.put(ICache_request{ address: zeroExtend(req[31:0]),
                                            epochs:0
                                          `ifdef ifence
                                            ,fence: unpack(fence) 
                                          `endif
                                          `ifdef supervisor
                                            ,sfence:False
                                          `endif });
        `logLevel( tb, 0, $format("TB: Sending core request for addr: %h",req))
        end
        index<=index+1;
      end
      if((delay==0 && fence!=1) || request=='1)begin // if not a fence instruction
        `logLevel( tb, 0, $format("TB: Enquiing request: %h",req))
        ff_req.enq(req);
      end
    end
  endrule

  rule end_sim;
    Bit#(TAdd#(`paddr ,  4)) request = truncate(ff_req.first());
    if(request==0)begin
      $display("TB: All Tests PASSED. Total TestCount: %d", rg_test_count-1);
      $finish(0);
    end
  endrule

  rule checkout_request(ff_req.first =='1);
    ff_req.deq;
    rg_test_count<=rg_test_count+1;
    $display("TB: ********** Test:%d PASSED****",rg_test_count);
  endrule


  rule core_resp(ff_req.first[35:0]!='1);
    let resp <- imem.core_resp.get();
    let req = ff_req.first;
    ff_req.deq();
    Bit#(4) control = req[`paddr + 3: `paddr ];
    Bit#(1) readwrite=control[3];
    Bit#(1) delay=control[2];
    Bit#(1) fence=control[1];

    if(fence==0)begin
      let expected_data<-testcache.memory_operation(truncate(req),0,2,?);
      Bool metafail=False;
      Bool datafail=False;
  
      if(expected_data!=resp.instr)begin
          `logLevel( tb, 0, $format("TB: Output from cache is wrong for Req: %h",req))
          `logLevel( tb, 0, $format("TB: Expected: %h, Received: %h",expected_data,resp.instr))
          datafail=True;
      end

      if(metafail||datafail)begin
        $display("\tTB: Test: %d Failed",rg_test_count);
        $finish(0);
      end
      else
        `logLevel( tb, 0, $format("TB: Core received correct response: ",fshow(resp)," For req:  %h",req))
    end
    else begin
      `logLevel( tb, 0, $format("TB: Response from Cache: ",fshow(resp)))
    end
  endrule

  rule read_mem_request(read_mem_req matches tagged Invalid);
    let req<- imem.read_mem_req.get;
    read_mem_req<=tagged Valid req;
    `logLevel( tb, 0, $format("TB: Memory Read request: ",fshow(req)))
  endrule

  rule read_mem_resp(read_mem_req matches tagged Valid .req);
    if(rg_read_burst_count == req.burst_len) begin
      rg_read_burst_count<=0;
      read_mem_req<=tagged Invalid;
    end
    else begin
      rg_read_burst_count<=rg_read_burst_count+1;
      read_mem_req <= tagged Valid (ICache_mem_request{address: axi4burst_addrgen(req.burst_len,req.burst_size,2,req.address),
                                        burst_len: req.burst_len,
                                    burst_size: req.burst_size}); // parameterize
    end
    let v_wordbits = valueOf(TLog#(TDiv#(`ibuswidth,8)));
    Bit#(19) index = truncate(req.address>>v_wordbits);
    let dat=data.sub(truncate(index));
    Bit#(TLog#(TDiv#(`ibuswidth,8))) zeros = 0;
    Bit#(TMul#(2,TLog#(TDiv#(`ibuswidth,8)))) shift={req.address[v_wordbits-1:0],zeros};
    dat = dat >> shift;
    imem.read_mem_resp.put(ICache_mem_response{data:dat, last: rg_read_burst_count==req.burst_len,
                                                                                        err:False});
    `logLevel( tb, 0, $format("TB: Memory Read index: %d responding with: %h ",index,dat))
  endrule

endmodule

endpackage
