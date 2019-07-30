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
											numeric type mshrfifo_depth);
		method ActionValue#(Maybe#(Bit#(TLog#(mshrsize)))) allocate (Req_from_core#(paddr, data) req);
		method ActionValue#(Maybe#(Req_from_core#(paddr, data))) req_to_fb(Maybe#(Bit#(TLog#(mshrsize))) v_req_rid);
		method Action ack_from_fb;
	endinterface

	module mkmshr (Ifc_mshr#(paddr, linewidthbits, data, mshrsize, mshrfifo_depth))
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

		Wire#(Bit#(TLog#(mshrsize))) wr_curr_req_mshr_id <- mkDWire(0);

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

		method ActionValue#(Maybe#(Bit#(TLog#(mshrsize)))) allocate (Req_from_core#(paddr, data) req) if(!one_mshr_fifo_full && !mshr_full);
			Bool mshr_allocated= False;
			Bit#(TLog#(mshrsize)) mshr_allocated_id= 0;
			Bit#(TLog#(mshrsize)) mshr_unallocated_id= 0;
			Bit#(addr_in_mshr) req_line_addr= req.addr[paddr_val-1:linewidthbits_val];
			`logLevel( dcache, 2, $format("MSHR : New req for line_addr: %h req_addr: %h", req_line_addr, req.addr))
			for(Integer i=0; i<mshrsize_val; i=i+1) begin
				`logLevel( dcache, 2, $format("MSHR[%d]: Valid: %b line_addr: %h", i, rg_mshr_valid[i], rg_mshr_line_addr[i]))
				if(rg_mshr_valid[i] && ( req_line_addr == rg_mshr_line_addr[i])) begin
					mshr_allocated= True;
					mshr_allocated_id= fromInteger(i);
				end
				else if(!rg_mshr_valid[i]) begin	//If an MSHR entry is not allocated
					mshr_unallocated_id= fromInteger(i);
				end
			end
			wr_curr_req_mshr_id<= mshr_allocated_id;

			if(!mshr_allocated) begin
				rg_mshr_line_addr[mshr_unallocated_id]<= req_line_addr;
				rg_mshr_valid[mshr_unallocated_id]<= True;
				ff_mshr[mshr_unallocated_id].enq(Req_from_core {addr: req.addr[linewidthbits_val-1:0],
																												access_size: req.access_size,
																												payload: req.payload,
																												origin: req.origin });
				`logLevel( dcache, 2, $format("MSHR : Allocated MSHR id: %d for addr: %h", mshr_unallocated_id, req.addr))
				return tagged Valid mshr_unallocated_id;
			end
			else begin
				ff_mshr[mshr_allocated_id].enq(Req_from_core {addr: req.addr[linewidthbits_val-1:0],
																											access_size: req.access_size,
																											payload: req.payload,
																											origin: req.origin });
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
				rg_curr_fb_id<= tagged Valid req_rid;
				if(rg_mshr_valid[req_rid] && ff_mshr[req_rid].notEmpty) begin
					let fifo_top= ff_mshr[req_rid].first;
					req= tagged Valid (Req_from_core {	addr: {rg_mshr_line_addr[req_rid], fifo_top.addr},
																							access_size: fifo_top.access_size,
																							payload: fifo_top.payload,
																							origin: fifo_top.origin });
					`logLevel( dcache, 2, $format("MSHR : Miss req to FB when rg_curr_fb_id is Invalid: ", fshow(req)))
				end
				//This condition should never happen as if the MSHR is not empty, and a response comes from
				//the memory, then there should be at least one request in the FIFO corresponding to MSHR[req_rid]
				else begin
					`ifdef ASSERT
						dynamicAssert(!isValid(v_req_rid),"Invalid memory response"); 
					`endif
				end
			end
			else if(rg_curr_fb_id matches tagged Valid .curr_rid) begin		//The current MSHR's (that is being serviced) id
				
				if(ff_mshr[curr_rid].notEmpty) begin
					let fifo_top= ff_mshr[curr_rid].first;
					req= tagged Valid (Req_from_core {	addr: {rg_mshr_line_addr[curr_rid], fifo_top.addr},
																							access_size: fifo_top.access_size,
																							payload: fifo_top.payload,
																							origin: fifo_top.origin });
					`logLevel( dcache, 2, $format("MSHR : Miss req from MSHR[%d] to FB: ", curr_rid, fshow(req)))
				end
				//curr_id is being serviced right now, but ff_mshr[curr_rid] is empty, then check if wr_curr_req_mshr_id
				//is to curr_id or not. If so, then rg_curr_fb_id should remain unchanged, else, Invalidate it
				//so that in the next cycle it will be assigned the value
				else if(wr_curr_req_mshr_id!=curr_rid) begin //implicit && !ff_mshr[curr_rid].notEmpty
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
		
	endmodule

  (*synthesize*)
	module mkmshr_instance (Ifc_mshr#(32, 9, 64, 3, 4));
    let ifc();
    mkmshr _temp(ifc);
    return (ifc);
  endmodule
endpackage
