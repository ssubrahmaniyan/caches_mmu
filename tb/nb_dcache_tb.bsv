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

Author: Arjun Menon
Email id: c.arjunmenon@gmail.com
Details:

--------------------------------------------------------------------------------------------------
*/
package nb_dcache_tb;
  import Vector::*;
  import FIFOF::*;
  import DReg::*;
	import ConfigReg::*;
  import SpecialFIFOs::*;
  import BRAMCore::*;
  import FIFO::*;
  import GetPut::*;
	import DefaultValue::*;
  //import dcache_nway::*;
  import test_caches::*;
  //import icache_dm::*;
  import mem_config::*;
  import BUtils ::*;
  import RegFile::*;
  import Vector::*;
	import nb_dcache_types::*;
	import nb_dcache::*;
	import device_common::*;
	`include "parameters.txt"
  `include "Logger.bsv"           // for logging
	import CompletionBuffer::*;
  import fa_dtlb::*;  //for accessing ifc_meta of fa_dtlb
  
  `define sets 64
  `define word_size 4
  `define block_size 8
  `define addr_width 32
  `define ways 4
  `define repl RROBIN
	`define ReadDelay 10

  (*synthesize*)
  module mktest(Ifc_test_caches#(`Wordsize , `Linesize , `Setsize , `Ways , `Buswidth, `Paddr));
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


	(*descending_urgency="core_resp, core_req"*)
  (*synthesize*)
  module mknb_dcache_tb(Empty);

  let dcache <- mkdcache();
  let testcache<- mktest();

  RegFile#(Bit#(11), Bit#(TAdd#(TAdd#(TMul#(`Wordsize, 8), 8), `Paddr ) )) stim <- 
                                                                      mkRegFileFullLoad("test.mem");
  `ifdef pysimulate
  	RegFile#(Bit#(10), Bit#(1))  e_meta <- mkRegFileFullLoad("gold.mem");
	`endif
  RegFile#(Bit#(19), Bit#(`Buswidth)) data <- mkRegFileFullLoad("data.mem");

  Reg#(Bit#(32)) index<- mkReg(0);
  Reg#(Bit#(32)) e_index<- mkReg(0);
  Reg#(Maybe#(Read_req_to_mem#(`Paddr, `Id_bits))) read_mem_req<- mkReg(tagged Invalid);
  Reg#(Maybe#(Write_req_to_mem#(32,TMul#(`Linesize, TMul#(`Wordsize ,8))))) 
                                                            write_mem_req <- mkReg(tagged Invalid);
  Reg#(Bit#(8)) rg_read_burst_count <- mkReg(0);
  Reg#(Bit#(8)) rg_write_burst_count <- mkReg(0);
  Reg#(Bit#(32)) rg_test_count <- mkReg(1);
	Reg#(Bit#(32)) rg_read_delay <- mkConfigReg(0);

	CompletionBuffer#(TExp#(`Prf_index), Bit#(TMul#(`Wordsize,8))) cbuf<- mkCompletionBuffer;
	FIFO#(Bit#(TAdd#(TAdd#(TMul#(`Wordsize, 8), 8), `Paddr))) ff_req <-mkSizedFIFO(64);
  `ifdef pysimulate
    FIFOF#(Bit#(1)) ff_meta <- mkSizedFIFOF(32);
  `endif

  `ifdef perf
  Vector#(5,Reg#(Bit#(32))) rg_counters <- replicateM(mkReg(0));


  rule performance_counters;
    Bit#(5) incr = dcache.perf_counters;
    for(Integer i=0;i<5;i=i+1)
      rg_counters[i]<=rg_counters[i]+zeroExtend(incr[i]);
  endrule
  `endif

  //rule enable_disable_cache;
  //  dcache.cache_enable(True);
  //endrule

  rule core_req(!dcache.cache_busy);
    let stime<-$stime;
    if(stime>=(20)) begin
      let req=stim.sub(truncate(index));
     	index<=index+1;
      // read/write : delay/nodelay : Fence/noFence : Null

	    let ____t <- $time; 
    	// read/write : size: sign: delay/nodelay : Fence/noFence : Null : Addr
      Bit#(8) control = req[`Paddr + 7: `Paddr];
			Bit#(`Rob_index) rob= req[`Paddr+`Rob_index+7:`Paddr+8];
      Bit#(2) readwrite=control[7:6];
      Bit#(3) size=control[5:3];
      Bit#(1) delay=control[2];
      Bit#(1) fence=control[1];
      Bit#(TAdd#(`Paddr ,  8)) request = truncate(req);
      Bit#(TMul#(`Wordsize, 8)) writedata=truncateLSB(req);
			$display($format("[%10d", ____t) + $format("] "),"\tTB: Req from file: %h Rob:%d Delay:%h Request:%h", req, rob, delay, request);

			if(fence==1) begin
				Req_from_core#(`Vaddr, TMul#(`Wordsize, 8), `Rob_index, `Prf_index) temp_req= defaultValue;
				temp_req.sfence=True;
        dcache.subifc_req_from_core.put(temp_req);
			end
			else if(delay==0 && request!=0) begin // // not end of simulation
				ff_req.enq(req);
				let new_token<- cbuf.reserve.get;
				if(request!='1) begin		//not finish test 
					//CBToken#(TExp#(`Prf_index)) new_token= unpack(0);
					Origin req_origin= (readwrite=='d1)? Load_buffer: Store_commit;
					Bit#(`Paddr) p_addr= request[`Paddr-1:0];
					Bit#(`Vaddr) lv_addr= zeroExtend(p_addr);	//TODO change this to `Vaddr
					Req_from_core#(`Vaddr, TMul#(`Wordsize, 8), `Rob_index, `Prf_index) temp_req= Req_from_core{ addr: lv_addr,
																																									 access_size: truncate(size),
																																									 data: writedata,
																																									 origin: req_origin,
                                                                                   sfence: False,
                                                                                   ptwalk_trap: False,
																																									 rob: rob,
																																								 	 prf_index: pack(new_token)
                                                                                  `ifdef atomic
                                                                                   , is_atomic: False
                                                                                   , atomic_fn: 'b01000
                                                                                  `endif };
					$display($format("[%10d", ____t) + $format("] "),"\tTB: Sending Req to Core: ", fshow(temp_req));
        	dcache.subifc_req_from_core.put(temp_req);
				end
				else begin
					$display($format("[%10d", ____t) + $format("] "),"\tTB: Only enqueueing req: %h into ff_req",req);
				end
      end
			else if(request==0) begin
				$display($format("[%10d", ____t) + $format("] "),"\tTB: Only enqueueing req: %h into ff_req",req);
      	ff_req.enq(req);
			end
			else if(delay!=0) begin
				if(rob=='d10) begin
					$display($format("[%10d", ____t) + $format("] "),"\tTB: Flushing from flush_rob: %d head: 'd30",rob);
					dcache.flush('d30,rob);
				end
			end
    end
  endrule

  rule rl_pt_meta;
    dcache.subifc_ptw_meta.ma_satp_from_csr(0);     //transparent translation
    dcache.subifc_ptw_meta.ma_curr_priv (0);        //machine mode
    dcache.subifc_ptw_meta.ma_mstatus_from_csr(0);  //don't care for now since translating transparently
    //dcache.subifc_ptw_meta.ma_pmp_cfg ( Vector#(`PMPSIZE, Bit#(8)) pmpcfg) ;
  endrule

	rule rl_endsim;
	  let ____t <- $time; 
		Bit#(TAdd#(`Paddr ,  8)) req = truncate(ff_req.first());
		if(req==0) begin
    `ifdef perf
      for(Integer i=0;i<5;i=i+1)
        $display($format("[%10d", ____t) + $format("] "),"\tTB: Counter-",countName(i),": %d",rg_counters[i]);
    `endif
      $display($format("[%10d", ____t) + $format("] "), "\tTB: All Tests PASSED. Total TestCount: %d", rg_test_count-1);
      $finish(0);
		end
	endrule

	rule drain_req;
		let read_data<- cbuf.drain.get;
		let req= ff_req.first;
		ff_req.deq;
	  let ____t <- $time; 
    Bit#(8) control = req[`Paddr + 7: `Paddr ];
    Bit#(2) readwrite=control[7:6];
    Bit#(3) size=control[5:3];
    Bit#(1) delay=control[2];
    Bit#(1) fence=control[1];
    Bit#(TMul#(`Wordsize, 8)) writedata=truncateLSB(req);

    Bit#(`Buswidth) expected_data=0;
		if(fence==0)
			expected_data<-testcache.memory_operation(truncate(req),readwrite,size,zeroExtend(writedata));
    Bool datafail=False;
		$display("\n");
  
		if(readwrite!='d1 || fence==1) begin
			$display($format("[%10d", ____t) + $format("] "),"\tTB: Store/Fence request. No comparison being done.");
		end
    else if(truncate(expected_data)!=read_data)begin
        $display($format("[%10d", ____t) + $format("] "),"\tTB: Output from cache is wrong for Req: %h",req);
        $display($format("[%10d", ____t) + $format("] "),"\tTB: Expected: %h, Received: %h",expected_data,read_data);
        datafail=True;
    end

    if(datafail)begin
      $display($format("[%10d", ____t) + $format("] "),"\tTB: Test: %d Failed",rg_test_count);
      $finish(0);
    end
    else
      $display($format("[%10d", ____t) + $format("] "),"\tTB: Core received correct response: %h for req: %h", read_data, req);

		if(req=='1) begin
	    rg_test_count<=rg_test_count+1;
    	$display($format("[%10d", ____t) + $format("] "),"\tTB: ********** Test:%d PASSED****",rg_test_count);
		end
		else if(req==0) begin
    `ifdef perf
      for(Integer i=0;i<5;i=i+1)
        $display($format("[%10d", ____t) + $format("] "),"\tTB: Counter-",countName(i),": %d",rg_counters[i]);
    `endif
      $display($format("[%10d", ____t) + $format("] "), "\tTB: All Tests PASSED. Total TestCount: %d", rg_test_count-1);
      $finish(0);
		end

	endrule

  rule core_resp;
	  let ____t <- $time; 
    let resp <- dcache.subifc_resp_to_core.get();
		$display($format("[%10d", ____t) + $format("] "),"\tTB: Resp from core: ", fshow(resp));
		cbuf.complete.put(tuple2(unpack(resp.prf_index), resp.data));
  endrule

  rule read_mem_request(read_mem_req matches tagged Invalid &&& rg_read_delay==0);
	  let ____t <- $time; 
    let req<- dcache.subifc_read_req_to_mem.get;
    read_mem_req<=tagged Valid req;
    $display($format("[%10d", ____t) + $format("] "),"\tTB: Memory Read request",fshow(req));
  endrule

	rule rl_read_delay(isValid(read_mem_req));
		if(rg_read_delay==`ReadDelay+3)
			rg_read_delay<= 0;
		else
			rg_read_delay<= rg_read_delay +1;
	endrule
	rule rl_disp1;
	  let ____t <- $time; 
		$display("\n\n",$format("[%10d", ____t) + $format("] "),"\tTB: valid: %b read_Delay: %d", isValid(read_mem_req), rg_read_delay);
	endrule

  rule read_mem_resp(read_mem_req matches tagged Valid .req &&& rg_read_delay>=`ReadDelay);
	  let ____t <- $time; 
		let addr= req.addr;
		Bit#(3) size= fromInteger(valueOf(TLog#(`Buswidth)))-3;
		let burst= (req.is_burst?8'd3:8'd0);
    if(rg_read_burst_count == burst) begin
      rg_read_burst_count<=0;
      read_mem_req<=tagged Invalid;
    end
    else begin
      rg_read_burst_count<=rg_read_burst_count+1;
      read_mem_req <= tagged Valid Read_req_to_mem { addr: axi4burst_addrgen(burst,size,2,addr),
																										 id: req.id,
																										 is_burst: req.is_burst }; // parameterize
    end
    let v_wordbits = valueOf(TLog#(`Wordsize));
    Bit#(19) index = truncate(addr>>v_wordbits);
    let datLSB=data.sub(truncate(index));
  	let datMSB=data.sub(truncate(index+1));
		
		let lv_read_resp=	Read_resp_from_mem {data: {datMSB[63:0], datLSB[63:0]},
																					id: req.id,
																					last: (rg_read_burst_count==burst) };
		dcache.subifc_read_resp_from_mem.put(lv_read_resp);
    $display($format("[%10d", ____t) + $format("] "),"\tTB: Memory Read from index: %d for req: ", index, fshow(lv_read_resp));
  endrule
 
	//rule rl_write_mem_req;
  //  let req<- dcache.subifc_write_req_to_mem.get;
	//	Bit#(3) size= fromInteger(valueOf(TLog#(`Buswidth)))-3;
	//	let burst= (req.burst?8'd3:8'd0);
	//	if(req.is_burst) begin
	//		if(rg_write_burst_count == burst) begin
	//			rg_write_burst_count< 0;
	//		end
	//		else begin
	//			rg_write_burst_count<= rg_write_burst_count + 1;
	//		end
	//	end
  //  write_mem_req <= tagged Valid tuple4(axi4burst_addrgen(burst,zeroExtend(size),2,addr),burst,size,nextdata); // parameterize
	//endrule
  rule write_mem_request(write_mem_req matches tagged Invalid);
	  let ____t <- $time; 
    let req<- dcache.subifc_write_req_to_mem.get;
    write_mem_req<=tagged Valid req;
    $display($format("[%10d", ____t) + $format("] "),"\tTB: Memory Write request",fshow(req));
  endrule

  rule write_mem_resp(write_mem_req matches tagged Valid .req);
	  let ____t <- $time; 
    let addr= req.addr;
		let writedata= req.data;
		Bit#(3) size= fromInteger(valueOf(TLog#(`Buswidth)))-3;
		let burst= (req.is_burst?8'd3:8'd0);
    if(rg_write_burst_count == burst) begin
      rg_write_burst_count<=0;
      write_mem_req<=tagged Invalid;
      dcache.subifc_write_resp_from_mem.put(False);
      $display($format("[%10d", ____t) + $format("] "),"\tTB: Sending write response back");
    end
    else begin
      rg_write_burst_count<=rg_write_burst_count+1;
      let nextdata=writedata>>32;
      write_mem_req <= tagged Valid Write_req_to_mem {addr: axi4burst_addrgen(burst,zeroExtend(size),2,addr),
																											is_burst: req.is_burst,
																											data: nextdata };
    end
    
    let v_wordbits = valueOf(TLog#(`Wordsize));
    Bit#(19) index = truncate(addr>>v_wordbits);
    let loaded_data=data.sub(index);

    Bit#(`Buswidth) mask = size[2:0]==0?'hFF:size[2:0]==1?'hFFFF:size[2:0]==2?'hFFFFFFFF:size[2:0]==3?'hFFFFFFFF_FFFF_FFFF:'1;
    Bit#(TLog#(`Wordsize)) shift_amt=addr[v_wordbits-1:0];
    mask= mask<<shift_amt;

    Bit#(`Buswidth) write_word=~mask&loaded_data|mask&truncate(writedata);
    data.upd(index,write_word);
    $display($format("[%10d", ____t) + $format("] "),"\tTB: Updating Memory index: %d with: %h burst_count: %d burst: %d", 
      index,write_word,rg_write_burst_count,burst);
  endrule

endmodule

endpackage

