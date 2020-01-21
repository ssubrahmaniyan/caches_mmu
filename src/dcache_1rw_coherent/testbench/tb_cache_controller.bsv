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
package tb_cache_controller;
  `include "Logger.bsv"
  `include "coherence.defines"
  import cache_controller:: * ;
  import coherence_types :: * ;
  import FIFO :: * ;
  import FIFOF :: * ;
  import SpecialFIFOs :: * ;
  import Vector :: * ;
  import Semi_FIFOF :: * ;
  import ShaktiLink_Types :: * ;
  import ShaktiLink_Fabric :: * ;
  import llc_bank :: * ;
  import BRAMCore :: * ;
  import Randomizable ::*;
  import globals :: * ;
  import DReg :: * ;
  
  import GetPut :: * ;
  import Connectable :: * ;

  typedef TMul#(`NrCaches,2) Num_Masters;
  typedef TAdd#(TMul#(`NrCaches,2),2) Num_Slaves;
  typedef TAdd#(TLog#(Num_Masters),1) Isize;
  typedef TAdd#(TLog#(Num_Slaves),1) Osize;
  typedef TMax#(Isize,Osize) FSize;

 
  function Bit#(TLog#(Num_Slaves)) fn_addr_map(Bit#(32) addr);
    if(addr >= 0 && addr < 'h2000)
      return 2;
    else if(addr >='h2000 && addr <= 'h4000)
      return 3;
    else
      return 4;
  endfunction

  (*synthesize*)
  module mktb_cache_controller(Empty);
    Ifc_cache_controller#(FSize,FSize) tile [`NrCaches];
    for (Integer i = 0; i<`NrCaches; i = i + 1) begin
      tile[i] <- mkcache_controller(i);
    end

    Ifc_llc_bank#(`paddr, TDiv#(`linesize,8), FSize, FSize, SizeOf#(MessageType), 
      TLog#(`NrCaches),1, `dwords, `dblocks, `dsets, TAdd#(1, TMul#(`dways,`NrCaches))) llc[`NrCaches];
    for (Integer i = 0; i<`NrCaches; i = i + 1) begin
      llc[i] <- mkllc_bank(fromInteger(i));
    end

    // memory instance
    Ifc_bram_slc#(`paddr, TDiv#(`linesize,8), FSize, FSize, SizeOf#(MessageType), 
                          TLog#(`NrCaches),1) bram <- mkbram_slc("DDR");
    // memory instance
    Ifc_bram_slc#(`paddr, TDiv#(`linesize,8), FSize, FSize, SizeOf#(MessageType), 
                          TLog#(`NrCaches),1) bram_io <- mkbram_slc("DDR-IO");
  
    Ifc_ShaktiLink_Fabric#(Num_Masters,Num_Slaves,`paddr, TDiv#(`linesize,8), 
                           FSize, FSize, SizeOf#(MessageType), TLog#(`NrCaches),1) 
      fabric <- mkShaktiLink_Fabric(fn_addr_map);

    for(Integer i=0;i<`NrCaches; i=i+1) begin
      mkConnection(fabric.v_from_masters[i],tile[i].master_side);
      mkConnection(fabric.v_to_slaves[i],tile[i].slave_side);
    end
    for(Integer i=`NrCaches;i<`NrCaches*2; i=i+1) begin
      mkConnection(fabric.v_from_masters[i],llc[i-`NrCaches].master_side);
      mkConnection(fabric.v_to_slaves[i],llc[i-`NrCaches].slave_side);
    end
    mkConnection(fabric.v_to_slaves[2*`NrCaches],bram.slave_side);
    mkConnection(fabric.v_to_slaves[2*`NrCaches+1],bram_io.slave_side);

    Reg#(Bool) rg_init <- mkReg(True);
    Reg#(Bool) rg_do_perform_store [`NrCaches];
    FIFOF#(Bit#(2)) ff_req [`NrCaches];
	  Randomize#(Bit#(`paddr)) rand_address[`NrCaches];
	  Randomize#(Bit#(`linesize)) rand_data[`NrCaches];
	  Randomize#(Bit#(1)) rand_access [`NrCaches];
  	Randomize#(Bit#(3)) rand_size [`NrCaches];
	  for (Integer i = 0; i<`NrCaches; i = i + 1) begin
      rg_do_perform_store[i] <- mkDReg(False);
      rand_address [i] <- mkConstrainedRandomizer(0,'h4000); 
      rand_data [i] <- mkConstrainedRandomizer(0,'1);
      rand_access[i]  <- mkConstrainedRandomizer(0,1);
      rand_size[i] <- mkConstrainedRandomizer(0,7);
      ff_req[i] <- mkSizedFIFOF(32);
	  end

    /*doc:rule: */
    rule rl_endline;
      `logLevel( tb, 0, $format(""))
    endrule

    /*doc:rule: */
    rule rl_init_randomizer(rg_init);
      for (Integer i = 0; i<`NrCaches; i = i + 1) begin
        rand_address[i].cntrl.init();
        rand_data[i].cntrl.init();
        rand_access[i].cntrl.init();
        rand_size[i].cntrl.init();
      end
      rg_init <= False;
    endrule
  

    for (Integer i = 0; i<`NrCaches; i = i + 1) begin
        rule enable_disable_cache;
          tile[i].cache_enable(True);
          tile[i].ma_criticality(0);
        endrule
        rule tlb_csr_info;
          tile[i].ma_satp_from_csr(0);
          tile[i].ma_curr_priv('d3);
          tile[i].ma_mstatus_from_csr('h0);
        endrule
        rule rl_send_core_req;
          let _addr <- rand_address[i].next();
          let _data <- rand_data[i].next();
          let _access <- rand_access[i].next();
          let _size <- rand_size[i].next();
          if(_size[1:0] == 'b01)
            _addr[0] = 0;
          else if(_size[1:0] == 'b10)
            _addr[1:0] = 0;
          else if(_size[1:0] == 'b11)
            _addr[2:0] = 0;
          DMem_request#(`vaddr,`vaddr,`desize) req = DMem_request{address:zeroExtend(_addr),
							      fence : False,
							      epochs: 0, 
							      access: zeroExtend(_access), 
							      size  : _size, 
							      writedata  : truncate(_data)
							      `ifdef atomic , atomic_op: 0 `endif 
                    `ifdef supervisor
							        , sfence: False,
    							      ptwalk_req: False,
    								    ptwalk_trap: False
							      `endif };
          tile[i].core_req.put(req);
          ff_req[i].enq(zeroExtend(_access));
          `logLevel( tb, 0, $format("TB: Sending Req[%2d]:",i,fshow(req)))
        endrule
        rule rl_get_resp_from_cache_to_core;
          let resp <- tile[i].core_resp.get();
          let access = ff_req[i].first;
          if(access==1)
            rg_do_perform_store[i]<=True;
          ff_req[i].deq;
          `logLevel( tb, 0, $format("TB: Core received Response: from CC[%2d]:",i,fshow(resp)))
        endrule

        rule rl_perform_store(rg_do_perform_store[i]);
          let complete<-tile[i].perform_store(0);
          `logLevel( tb, 0, $format("TB: Performing Store CC[%2d]",i))
        endrule
//
//      rule rl_get_req_from_cache_to_core;
//        let x <- cc[i].mv_req_to_core.get();
//        let _t = ENTRY_C1{state:C1_S, perm:?, cl:?, acksReceived:0, acksExpected:0, 
//                          id: tagged Caches fromInteger(i)};
//        let {new_entry, send_resp, enq_d1, enq_d2, send_defer}  = func_C1(x,_t);
//        cc[i].mv_resp_from_core.put(tuple4(send_resp,enq_d1,enq_d2, send_defer));
//        `logLevel( tb, 0, $format("TB: Got Req from Cache:",fshow(x)))
//      endrule
    end


  endmodule



  interface Ifc_bram_slc#(numeric type a, numeric type w, numeric type o, 
                          numeric type i, numeric type op, numeric type acks, numeric type u);
      interface Ifc_slc_slave#(a,w,o,i,op,acks,u) slave_side;
  endinterface
  module mkbram_slc#(parameter String modulename )(Ifc_bram_slc#(a,w,o,i,op,acks,u))
    provisos(
      Mul#(TDiv#(TMul#(w, 8), TDiv#(TMul#(w, 8), 8)), TDiv#(TMul#(w, 8), 8),TMul#(w, 8)),
      Add#(0, o, i),
      Add#(a__, 2, i),
      Add#(b__, 4, op)
    );
    UserInterface#(a, TMul#(w,8), 18) dut <- mkbram(0, "code.mem", modulename);
    Ifc_slc_slave_agent#(a,w,o,i, op,acks,u) slave <- mkslc_slave_agent;

		FIFOF#(Req_channel#(a,w,o,i,op,u)) ff_req <- mkFIFOF();
//
//
//    // If the request is single then simple send ERR. If it is a burst write request then change
//    // state to Burst and do not send response.
////    rule write_request_address_channel;
////      let aw <- pop_o (s_xactor.o_wr_addr);
////      let w  <- pop_o (s_xactor.o_wr_data);
////	    let b = AXI4_Lite_Wr_Resp {bresp: AXI4_LITE_OKAY, buser: aw.awuser};
////      dut.write_request(tuple3(aw.awaddr, w.wdata, w.wstrb));
////	  	s_xactor.i_wr_resp.enq (b);
////    endrule
//    // read first request and send it to the dut. If it is a burst request then change state to
//    // Burst. capture the request type and keep track of counter.
    rule read_request_first;
		  let req <- pop_o(slave.o_req_channel);
		  Message#(a,w) msg = fn_from_req_pkt(req);
		  if (msg.msgtype == GetS) begin
        dut.read_request(req.address);
        ff_req.enq(req);
        `logLevel( bram, 0, $format(modulename,": Initiating Read Req:",fshow(msg)))
      end
      else begin
        dut.write_request(tuple3(req.address, req.data,'1));
        `logLevel( bram, 0, $format(modulename,": Performing Write:",fshow(msg)))
      end
    endrule
//    // get data from the memory. shift,  truncate, duplicate based on the size and offset.
    rule read_response;
      let {err, data0}<-dut.read_response;
      let req = ff_req.first;
      ff_req.deq;
      Resp_channel#(a,w,o,i,op,acks,u) _r = Resp_channel{ opcode: req.opcode,
                          acksExpected:0,
                          last: True,
                          source: (req.dest), 
                          dest: (req.source), 
                          address:req.address, 
                          corrupt:0,
                          data:data0,
                          user: req.user}; 
			slave.i_resp_channel.enq(_r);
			`logLevel( tb, 0, $format(modulename,": Sending resposne:",fshow(_r)))
    endrule
    interface slave_side = slave.shaktilink_side;
  endmodule
  interface UserInterface#(numeric type addr_width,  numeric type data_width, numeric type index_size);
    method Action read_request (Bit#(addr_width) addr);
    method Action write_request (Tuple3#(Bit#(addr_width), Bit#(data_width),
                                                                  Bit#(TDiv#(data_width, 8))) req);
    method ActionValue#(Tuple2#(Bool, Bit#(data_width))) read_response;
    method ActionValue#(Bool) write_response;
  endinterface

  // to make is synthesizable replace addr_width with Physical Address width
  // data_width with data lane width
  module mkbram#(parameter Integer slave_base, parameter String readfile,
                                                parameter String modulename )
      (UserInterface#(addr_width, data_width, index_size))
      provisos(
        Mul#(TDiv#(data_width, TDiv#(data_width, 8)), TDiv#(data_width, 8),data_width)  );

    Integer byte_offset = valueOf(TLog#(TDiv#(data_width, 8)));
  	// we create 2 32-bit BRAMs since the xilinx tool is easily able to map them to BRAM32BE cells
  	// which makes it easy to use data2mem for updating the bit file.

    BRAM_DUAL_PORT_BE#(Bit#(TSub#(index_size, TLog#(TDiv#(data_width, 8)))), Bit#(data_width),
                                                                    TDiv#(data_width,8)) dmemMSB <-
          mkBRAMCore2BELoad(valueOf(TExp#(TSub#(index_size, TLog#(TDiv#(data_width, 8))))), False,
                            readfile, False);

    Reg#(Bool) read_request_sent[2] <-mkCRegA(2,False);

    // A write request to memory. Single cycle operation.
    // This model assumes that the master sends the data strb aligned for the data_width bytes.
    // Eg. : is size is HWord at address 0x2 then the wstrb for 64-bit data_width is: 'b00001100
    // And the data on the write channel is assumed to be duplicated.
    method Action write_request (Tuple3#(Bit#(addr_width), Bit#(data_width),
                                                                  Bit#(TDiv#(data_width, 8))) req);
      let {addr, data, strb}=req;
			Bit#(TSub#(index_size,TLog#(TDiv#(data_width, 8)))) index_address=
			                          (addr - fromInteger(slave_base))[valueOf(index_size)-1:byte_offset];
			dmemMSB.b.put(strb,index_address,truncateLSB(data));
      `logLevel( bram, 0, $format("",modulename,": Recieved Write Request for Address: %h Index: %h\
 Data: %h wrstrb: %h", addr, index_address, data, strb))
  	endmethod

    // The write response will always be an error.
    method ActionValue#(Bool) write_response;
      return False;
    endmethod

    // capture a read_request and latch the address on a BRAM.
    method Action read_request (Bit#(addr_width) addr);
			Bit#(TSub#(index_size,TLog#(TDiv#(data_width, 8)))) index_address=
			                          (addr - fromInteger(slave_base))[valueOf(index_size)-1:byte_offset];
      dmemMSB.a.put(0, index_address, ?);
      read_request_sent[1]<= True;
      `logLevel( bram, 0, $format("",modulename,": Recieved Read Request for Address: %h Index: %h",
                                                                            addr, index_address))
  	endmethod

    // respond with data from the BRAM.
    method ActionValue#(Tuple2#(Bool, Bit#(data_width))) read_response if(read_request_sent[0]);
      read_request_sent[0]<=False;
      return tuple2(False, dmemMSB.a.read());
    endmethod
  endmodule


endpackage

