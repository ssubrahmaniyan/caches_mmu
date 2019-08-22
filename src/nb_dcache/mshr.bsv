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
package mshr;
  import nb_dcache_types::*; 	         
	import DefaultValue :: *;
  `include "Logger.bsv"           // for logging
	import FIFO::*;
	import FIFOF::*;
	import ConfigReg::*;

	interface Ifc_mshr#(numeric type paddr,
											numeric type linewidthbits,
											numeric type data,
											numeric type mshrsize,
											numeric type mshrfifo_depth,
											numeric type rob_index);
		method ActionValue#(Maybe#(Bit#(TLog#(mshrsize)))) allocate (Req_from_core#(paddr, data) req);
		method ActionValue#(Maybe#(Req_from_core#(paddr, data))) req_to_fb(Maybe#(Bit#(TLog#(mshrsize))) v_req_rid);
		method Action ack_from_fb;
		method Action flush (Flush_type#(rob_index) bundle);
	endinterface

	module mkmshr (Ifc_mshr#(paddr, linewidthbits, data, mshrsize, mshrfifo_depth, rob_index))
				 provisos ( Add#(addr_in_mshr, linewidthbits, paddr)
										//Add#(a__, addr_in_mshr, linewidthbits)		
			 						 );
		let paddr_val= valueOf(paddr);
		let linewidthbits_val= valueOf(linewidthbits);
		let mshrsize_val= valueOf(mshrsize);
		let mshrfifo_depth_val= valueOf(mshrfifo_depth);

		Reg#(Bit#(addr_in_mshr)) rg_mshr_line_addr [mshrsize_val];
		Reg#(Bool) rg_mshr_valid [mshrsize_val];
		//TODO Does rg_curr_fb_id really need to be Maybe#. Is this correct?
		Reg#(Maybe#(Bit#(TLog#(mshrsize)))) rg_curr_fb_id <- mkConfigReg(tagged Invalid);

		FIFOF#(Req_from_core#(linewidthbits, data)) ff_mshr [mshrsize_val];

		Wire#(Maybe#(Bit#(TLog#(mshrsize)))) wr_curr_req_mshr_id <- mkDWire(tagged Invalid);
		Wire#(Maybe#(Bit#(TLog#(mshrsize)))) wr_allocate_id <- mkDWire(tagged Invalid);
		Wire#(Bool) wr_deq_ff_id <- mkWire();

		Ifc_SEMF_FIFO#(mshrfifo_depth, Bit#(rob_index)) cff_rob [mshrsize_val];

		//Create a structure with unguarded single enq, deq and first; and another initialize method which updates
		//all the entries. Can enqueue be stalled for a cycle? Will any deadlock happen if stalled? Will
		//any false response be sent to the processor? If it cannot be stalled, how to combine the data of
		//enq and initialize method?
		//Updating cff_valid at one shot would work as it would reset the valid bit to 0 if should_flush
		//function returns True, and otherwise leave the entry unchanged. Also, whenever any corresponding
		//ff_mshr is enqueued a 1 is enqueued inside, and when ff_mshr is dequeued, cff_valid is also dequeued.
		Ifc_SESFMI_FIFO#(mshrfifo_depth, Bit#(1)) cff_valid [mshrsize_val];
		for(Integer i=0; i< mshrsize_val; i=i+1) begin
			cff_rob[i] <- mkSEMF_FIFO();
			cff_valid[i] <- mkSESFMI_FIFO();
		end

		Bool one_mshr_fifo_full= False;
		Bool mshr_full= True;
		Bool mshr_not_empty= False;
		for(Integer i=0; i<mshrsize_val; i=i+1) begin
			rg_mshr_line_addr[i] <- mkConfigReg(0);
			rg_mshr_valid[i] <- mkConfigReg(False);
			ff_mshr[i] <- mkGSizedFIFOF(True, True, mshrfifo_depth_val);	//TODO check if both enq and deq should be unguarded
			one_mshr_fifo_full= one_mshr_fifo_full || !ff_mshr[i].notFull;
			mshr_full= mshr_full && rg_mshr_valid[i];
			mshr_not_empty= mshr_not_empty || rg_mshr_valid[i];
		end

		rule rl_update_mshr_valid;
			if(wr_allocate_id matches tagged Valid .allocate_id) begin
				rg_mshr_valid[allocate_id]<= True;
			end

			if(rg_curr_fb_id matches tagged Valid .curr_fb_id &&&  !ff_mshr[curr_fb_id].notEmpty) begin
				if(wr_allocate_id matches tagged Valid .allocate_id &&& allocate_id== curr_fb_id) begin
					`logLevel( dcache, 2, $format("MSHR: ff_mshr[%d] is empty, but new allocation to the same MSHR in this cycle ", curr_fb_id))
				end
				else begin	//An MSHR should be invalidated only after the FB has been released
					`logLevel( dcache, 2, $format("MSHR: rg_mshr_valid[%d] is assigned False", curr_fb_id))
					rg_mshr_valid[curr_fb_id]<= False;
				end
			end
		endrule

		rule rl_deq_ff;
			let id= wr_deq_ff_id;
			ff_mshr[id].deq;
			cff_rob[id].deq;
			cff_valid[id].deq;
		endrule

		method ActionValue#(Maybe#(Bit#(TLog#(mshrsize)))) allocate (Req_from_core#(paddr, data) req)
												if(!one_mshr_fifo_full && !mshr_full && !rg_flush[1].valid);
			Bool mshr_allocated= False;
			Bit#(TLog#(mshrsize)) mshr_allocated_id= 0;
			Bit#(TLog#(mshrsize)) mshr_unallocated_id= 0;
			Bit#(addr_in_mshr) req_line_addr= req.addr[paddr_val-1:linewidthbits_val];
			`logLevel( dcache, 2, $format("MSHR : New req for line_addr: %h req_addr: %h", req_line_addr, req.addr))
			for(Integer i=0; i<mshrsize_val; i=i+1) begin
				`logLevel( dcache, 2, $format("MSHR[%d]: Valid: %b line_addr: %h", i, rg_mshr_valid[i], rg_mshr_line_addr[i]))
				if(rg_mshr_valid[i] && (req_line_addr == rg_mshr_line_addr[i])) begin
					mshr_allocated= True;
					mshr_allocated_id= fromInteger(i);
				end
				else if(!rg_mshr_valid[i]) begin	//If an MSHR entry is not allocated
					mshr_unallocated_id= fromInteger(i);
				end
			end
			if(mshr_allocated)
				wr_curr_req_mshr_id<= tagged Valid mshr_allocated_id;

			if(!mshr_allocated) begin
				rg_mshr_line_addr[mshr_unallocated_id]<= req_line_addr;
				wr_allocate_id<= tagged Valid mshr_unallocated_id;
				ff_mshr[mshr_unallocated_id].enq(Req_from_core {addr: req.addr[linewidthbits_val-1:0],
																												access_size: req.access_size,
																												payload: req.payload,
																												origin: req.origin });
				cff_rob[mshr_unallocated_id].enq(req.rob);
				cff_valid[mshr_unallocated_id].enq(1'b1);
				`logLevel( dcache, 2, $format("MSHR : Allocated MSHR id: %d for addr: %h", mshr_unallocated_id, req.addr))
				return tagged Valid mshr_unallocated_id;
			end
			else if(mshr_allocated) begin
				ff_mshr[mshr_allocated_id].enq(Req_from_core {addr: req.addr[linewidthbits_val-1:0],
																											access_size: req.access_size,
																											payload: req.payload,
																											origin: req.origin });
				cff_rob[mshr_unallocated_id].enq(req.rob);
				cff_valid[mshr_unallocated_id].enq(1'b1);
				return tagged Invalid;
			end
			else begin
				return tagged Invalid;
			end
		endmethod

		//TODO make the FIFO guarded and put explicit conditions wherever requried
		//Check if the condition for the method to fire should be mshr_not_empty or that 
		//For whatever MSHR the response has come, that FIFO is not empty.
		method ActionValue#(Maybe#(Req_from_core#(paddr, data))) req_to_fb(Maybe#(Bit#(TLog#(mshrsize))) v_req_rid);
			Maybe#(Req_from_core#(paddr, data)) req= tagged Invalid;
			`logLevel( dcache, 2, $format("MSHR : rg_curr_fb_id: ", fshow(rg_curr_fb_id)))
			`logLevel( dcache, 2, $format("MSHR : v_req_rid: ", fshow(v_req_rid)))
			if(rg_curr_fb_id matches tagged Invalid &&& v_req_rid matches tagged Valid .req_rid) begin
				if(rg_mshr_valid[req_rid]) begin
					rg_curr_fb_id<= tagged Valid req_rid;
					let fifo_top= ff_mshr[req_rid].first;
					let cfifo_valid= cff_valid[req_rid].first;

					if(cfifo_valid==1'b1) begin
						req= tagged Valid (Req_from_core {	addr: {rg_mshr_line_addr[req_rid], fifo_top.addr},
																								access_size: fifo_top.access_size,
																								payload: fifo_top.payload,
																								origin: fifo_top.origin });
						`logLevel( dcache, 2, $format("MSHR : Miss req to FB when rg_curr_fb_id is Invalid: ", fshow(req)))
					end
					else begin
						wr_deq_ff_id<= req_rid;
					end
				end
				//Else no pending req of current MSHR are pending, hence wait for the fill buffer to get filled
				else begin
					`logLevel( dcache, 2, $format("MSHR : Waiting for fill buffer to get filled for id: ", fshow(v_req_rid)))
				end
			end
			else if(rg_curr_fb_id matches tagged Valid .curr_rid) begin		//The current MSHR's (that is being serviced) id
				
				if(ff_mshr[curr_rid].notEmpty) begin
					let fifo_top= ff_mshr[curr_rid].first;
					let cfifo_valid= cff_valid[curr_rid].first;

					if(cfifo_valid==1'b1) begin
						req= tagged Valid (Req_from_core {	addr: {rg_mshr_line_addr[curr_rid], fifo_top.addr},
																								access_size: fifo_top.access_size,
																								payload: fifo_top.payload,
																								origin: fifo_top.origin });
						`logLevel( dcache, 2, $format("MSHR : Miss req from MSHR[%d] to FB: ", curr_rid, fshow(req)))
					end
					else begin
						wr_deq_ff_id<= curr_rid;
					end
				end
				//curr_id is being serviced right now, but ff_mshr[curr_rid] is empty, then check if wr_curr_req_mshr_id
				//is to curr_id or not. If so, then rg_curr_fb_id should remain unchanged, else, Invalidate it
				//so that in the next cycle it will be assigned the value
				else if(wr_curr_req_mshr_id matches tagged Valid .curr_req_rid &&& curr_req_rid==curr_rid) begin //implicit && !ff_mshr[curr_rid].notEmpty
					`logLevel( dcache, 2, $format("MSHR : New req from ff_second_stage to existing MSHR of id: %d", curr_rid))
				end
				else begin
					rg_curr_fb_id<= tagged Invalid;
					`logLevel( dcache, 2, $format("MSHR : No more pending requests of id: %d", curr_rid))
				end

			end
			return req;
		endmethod

		method Action ack_from_fb if(mshr_not_empty);
			if(rg_curr_fb_id matches tagged Valid .fb_id &&& ff_mshr[fb_id].notEmpty) begin
      	`logLevel( nb_dcache, 1, $format("MSHR : ack from fb for id: %d", fb_id))
				ff_mshr[fb_id].deq;
			end
			else begin
      `ifdef ASSERT
        dynamicAssert(True,"MSHR : Ack from fb called when ff_mshr empty");
      `endif
			end
		endmethod
		
		method Action flush (Flush_type#(rob_index) bundle);
			rg_flush[0]<= bundle;
		endmethod
	endmodule

  (*synthesize*)
	module mkmshr_instance (Ifc_mshr#(32, 9, 64, 3, 4, 7));
    let ifc();
    mkmshr _temp(ifc);
    return (ifc);
  endmodule
endpackage
