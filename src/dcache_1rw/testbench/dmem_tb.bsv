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
package dmem_tb;

  import dmem::*;
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
  import io_func :: * ;


  (*synthesize*)
  module mktest(Ifc_test_caches#(`dwords , `dblocks , `dsets , `dways, 
                                      TMul#(`dwords,8) ,`paddr, `dbuswidth ));
    let ifc();
    mktest_caches _temp(ifc);
    return (ifc);
  endmodule
 
  (*synthesize*)
 // (*preempts="write_mem_nc_resp,write_mem_resp"*)
  module mkdmem_tb(Empty);

  let dmem <- mkdmem();
  let testcache<- mktest();

  RegFile#(Bit#(18), Bit#(TAdd#(TAdd#(TMul#(`dwords, 8), 8), `paddr ))) stim <- mkRegFileFullLoad("test.mem");
  RegFile#(Bit#(19), Bit#(`dbuswidth)) data <- mkRegFileFullLoad("data.mem");

  Reg#(Bit#(32)) index<- mkReg(0);
  Reg#(Bit#(32)) e_index<- mkReg(0);
  Reg#(Maybe#(DCache_mem_readreq#(32))) read_mem_req<- mkReg(tagged Invalid);
  Reg#(Maybe#(DCache_mem_writereq#(32,TMul#(`dblocks, TMul#(`dwords ,8))))) 
                                                            write_mem_req <- mkReg(tagged Invalid);
  Reg#(Bit#(8)) rg_read_burst_count <- mkReg(0);
  Reg#(Bit#(8)) rg_write_burst_count <- mkReg(0);
  Reg#(Bit#(32)) rg_test_count <- mkReg(1);
  FIFOF#(Bool) ff_perform_store <- mkUGSizedFIFOF(2);

  FIFOF#(Bit#(TAdd#(TAdd#(TMul#(`dwords, 8), 8), `paddr ) )) ff_req <- mkSizedFIFOF(32);

  `ifdef perfmonitors
  Vector#(5,Reg#(Bit#(32))) rg_counters <- replicateM(mkReg(0));
  
  rule performance_counters;
    Bit#(9) incr = dmem.mv_dcache_perf_counters;
    for(Integer i=0;i<5;i=i+1)
      rg_counters[i]<=rg_counters[i]+zeroExtend(incr[i]);
  endrule
  `endif

  rule enable_disable_cache;
    dmem.cache_enable(True);
  endrule

`ifdef supervisor
  rule tlb_csr_info;
    dmem.ma_satp_from_csr(0);
    dmem.ma_curr_priv('d3);
    dmem.ma_mstatus_from_csr('h0);
  endrule
 `endif

  Wire#(Bool) wr_cache_avail <- mkWire();

  rule check_cache_avail;
    wr_cache_avail <= dmem.cache_available;
  endrule

  rule core_req(wr_cache_avail);
    let stime<-$stime;
    if(stime>=(20)) begin
      let req=stim.sub(truncate(index));
      // read/write : delay/nodelay : Fence/noFence : Null 
      Bit#(8) control = req[`paddr + 7: `paddr ];
      Bit#(2) readwrite=control[7:6];
      Bit#(3) size=control[5:3];
      Bit#(1) delay=control[2];
      Bit#(1) fence=control[1];
      Bit#(`paddr) address = truncate(req);
      Bit#(TAdd#(`paddr ,  8)) request = truncate(req);
      Bit#(TMul#(`dwords, 8)) writedata=truncateLSB(req);
      `logLevel( tb, 0, $format("TB: Req form Stim: ",fshow(req)))

      if(request!=0) begin // // not end of simulation
        if(request!='1 && delay==0) begin
          dmem.core_req.put(DMem_request{address:zeroExtend(address),
							      fence : unpack(fence),
							      epochs: 0, 
							      access: truncate(readwrite), 
							      size  : size, 
							      writedata  : writedata
							      `ifdef atomic , atomic_op: 0 `endif 
                                          `ifdef supervisor
							        , sfence: False,
    							      ptwalk_req: False,
    								    ptwalk_trap: False
                                          `endif });
        `logLevel( tb, 0, $format("TB: Sending core request for addr: %h",req))
        end
        index<=index+1;
      end
      if((delay==0) || request[35:0]=='1)begin // if not a fence instruction
        `logLevel( tb, 0, $format("TB: Enquiing request: %h",req))
        ff_req.enq(req);
      end
    end
  endrule

  rule end_sim;
    Bit#(TAdd#(`paddr ,  8)) request = truncate(ff_req.first());
    if(request==0)begin
      $display("TB: All Tests PASSED. Total TestCount: %d", rg_test_count-1);
      $finish(0);
    end
  endrule

  rule checkout_request(ff_req.first[35:0] =='1);
    ff_req.deq;
    rg_test_count<=rg_test_count+1;
    $display("TB: ********** Test:%d PASSED****",rg_test_count);
  endrule


  rule core_resp(ff_req.first[35:0]!='1);
    let resp <- dmem.core_resp.get();
    let req = ff_req.first;
    ff_req.deq();
    Bit#(8) control = req[`paddr + 7: `paddr ];
    Bit#(2) readwrite=control[7:6];
    Bit#(3) size=control[5:3];
    Bit#(1) delay=control[2];
    Bit#(1) fence=control[1];
    Bit#(TMul#(`dwords, 8)) writedata=truncateLSB(req);

    if(fence==0)begin
      if(readwrite!=0 && !ff_perform_store.notFull)begin
        `logLevel( tb, 0, $format("TB: Waiting for Store to be ready"))
      end
      else begin
        if (readwrite==2 || readwrite == 1)
          ff_perform_store.enq(True); 
        let expected_data<-testcache.memory_operation(truncate(req),readwrite,size,writedata);
        Bool metafail=False;
        Bool datafail=False;
        let lv_req_io = isIO(truncate(req),True);
  
        if(lv_req_io && readwrite !=0) begin
          `logLevel( tb, 0, $format("TB: Core received NC Write Response: ",fshow(resp)," For req:  %h",req))
        end
        else begin
          if(expected_data!=resp.word)begin
              `logLevel( tb, 0, $format("TB: Output from cache is wrong for Req: %h",req))
              `logLevel( tb, 0, $format("TB: Expected: %h, Received: %h",expected_data,resp.word))
              datafail=True;
          end

          if(metafail||datafail)begin
            $display("\tTB: Test: %d Failed",rg_test_count);
            $finish(0);
          end
          else
            `logLevel( tb, 0, $format("TB: Core received correct response: ",fshow(resp)," For req:  %h",req))
        end
      end
    end
    else begin
      `logLevel( tb, 0, $format("TB: Response from Cache: ",fshow(resp)))
    end
  endrule

  rule rl_perform_store(ff_perform_store.notEmpty && dmem.mv_commit_store_ready) ;
    ff_perform_store.deq;
    let complete<-dmem.perform_store(0);
    `logLevel( tb, 0, $format("TB: Performing STORE"))
  endrule

  rule read_mem_request(read_mem_req matches tagged Invalid);
    let req<- dmem.read_mem_req.get;
    read_mem_req<=tagged Valid req;
    `logLevel( tb, 0, $format("TB: Memory Read request: ",fshow(req)))
  endrule

  rule read_mem_resp(read_mem_req matches tagged Valid .req);
    let rd_req= req;
    if(rg_read_burst_count == rd_req.burst_len) begin
      rg_read_burst_count<=0;
      read_mem_req<=tagged Invalid;
    end
    else begin
      rg_read_burst_count<=rg_read_burst_count+1;
      read_mem_req <= tagged Valid (DCache_mem_readreq{address : (axi4burst_addrgen(rd_req.burst_len,rd_req.burst_size,2,rd_req.address)),
						       burst_len : rd_req.burst_len,
						       burst_size : rd_req.burst_size,
						       io: rd_req.io}); // parameterize
    end
    let v_wordbits = valueOf(TLog#(`dwords));
    Bit#(19) index = truncate(rd_req.address>>v_wordbits);
    let dat=data.sub(truncate(index));
    Bit#(TLog#(TDiv#(`dbuswidth,8))) zeros = 0;
    Bit#(TMul#(2,TLog#(TDiv#(`dbuswidth,8)))) shift={rd_req.address[v_wordbits-1:0],zeros};
    dat = dat >> shift;
    dmem.read_mem_resp.put(DCache_mem_readresp{data : dat,
						   last : (rg_read_burst_count==rd_req.burst_len),
                                                                                        err:False});
    `logLevel( tb, 0, $format("TB: Memory Read index: %d responding with: %h ",index,dat))
  endrule
  
  rule write_mem_request(write_mem_req matches tagged Invalid);
    let req = dmem.write_mem_req_rd;
    dmem.write_mem_req_deq;
    write_mem_req<=tagged Valid req;
    `logLevel( tb, 0, $format("TB: Memory Write request",fshow(req)))
  endrule

  rule write_mem_resp(write_mem_req matches tagged Valid .req);
    //let {addr, burst, size, writedata}=req;
    let wr_req=req;
    if(rg_write_burst_count == wr_req.burst_len) begin
      rg_write_burst_count<=0;
      write_mem_req<=tagged Invalid;
      dmem.write_mem_resp.put(False);
      `logLevel( tb, 0, $format("TB: Sending write response back"))
      `logLevel( tb, 0, $format("TB: write_mem_req is ",fshow(write_mem_req)))
    end
    else begin
      rg_write_burst_count<=rg_write_burst_count+1;
      //let nextdata=writedata>>32;
      let nextdata=wr_req.data>>`vaddr;
      write_mem_req <= tagged Valid (DCache_mem_writereq{address:(axi4burst_addrgen(wr_req.burst_len,zeroExtend(wr_req.burst_size),2,wr_req.address)),
							burst_len:wr_req.burst_len,
							burst_size:wr_req.burst_size,
							data:nextdata}); // parameterize
      `logLevel( tb, 0, $format("TB: write_mem_req is ",fshow(write_mem_req)))
    end
    
    let v_wordbits = valueOf(TLog#(`dwords));
    Bit#(19) index = truncate(wr_req.address>>v_wordbits);
    let loaded_data=data.sub(index);
    let size = wr_req.burst_size;

    Bit#(`vaddr) mask = size[1:0]==0?'hFF:size[1:0]==1?'hFFFF:size[1:0]==2?'hFFFFFFFF:'1;
    Bit#(TAdd#(3,TLog#(`dwords))) shift_amt={wr_req.address[v_wordbits-1:0],3'b0};
    mask= mask<<shift_amt;

    Bit#(`vaddr) write_word=~mask&loaded_data|mask&truncate(wr_req.data);
    data.upd(index,write_word);
    `logLevel( tb, 0, $format("TB: Updating Memory index: %d with: %h burst_count: %d burst: %d\
  mask:%h loaddata:%h", index,write_word,rg_write_burst_count,wr_req.burst_len, mask, loaded_data))
  endrule

endmodule

endpackage
