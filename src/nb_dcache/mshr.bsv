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

	interface Ifc_mshr#(numeric type paddr,
											numeric type data,
											numeric type id_bits);
		method ActionValue#(Maybe#(Read_req_to_mem)) allocate (Req_from_core#(paddr, data) req);
		method Req_from_core#(paddr, data) req_to_fb(Bit#(id_bits) rid, Bool rlast);
		method Action ack_from_fb;
	endinterface

	module mkmshr#(linewidthbits, mshrsize) (Ifc_mshr#(paddr, linewidthbits, data, id_bits, prfindex, mshrsize)
				 provisos (	Log#(mshrsize, mshrbits),
				 						Add#(paddr, linewidthbits, addr_in_mshr)
			 						 ));

		Reg#(Bit#(addr_in_mshr)) rg_mshr_line_addr [mshrsize];
		Reg#(Bool) rg_mshr_valid [mshrsize];
		Reg#(Bit#(id_bits)) rg_curr_fb_id <- mkReg(0);

		FIFO#(Req_from_core#(linewidthbits, data)) ff_mshr [mshrsize];

		Bool one_mshr_fifo_full= False;
		Bool mshr_full= rg_mshr_valid[0];
		for(Integer i=0; i<mshrsize; i=i+1) begin
			rg_line_addr[i] <- mkReg(0);
			ff_mshr[i] <- mkFIFOF(defaultValue);
			one_mshr_fifo_full= one_mshr_fifo_full || !ff_mshr.not_full[i];
			mshr_full= mshr_full && rg_mshr_valid[i];
		end
		
		method Action allocate (Req_from_core#(paddr, data, prfindex) req) if(!one_mshr_fifo_full && !mshr_full);
			Bool mshr_allocated= False;
			Bit#(mshrbits) mshr_allocated_id= 0;
			Bit#(addr_in_mshr) req_line_addr= req.addr[paddr-1:linewidthbits];
			for(Integer i=0; i<mshrsize; i=i+1) begin
				if(rg_mshr_valid && ( req_line_addr == rg_mshr_line_addr[i])) begin
					mshr_allocated= True;
					mshr_allocated_id= i;
				end
			end

			if(!mshr_allocated) begin
				rg_mshr_line_addr[mshr_allocated_id]<= req_line_addr;
				rg_mshr_valid[mshr_allocated_id]<= True;
			end
			ff_mshr[mshr_allocated_id].enq(Req_from_core {addr: req_line_addr,
																										access_size: req.access_size,
																										payload: req.payload,
																										origin: req.origin });
			
		endmethod

		//TODO remove tagged Invalid from rg_curr_fb_id. Save the mux on the input rid used for indexing.
		//One has to always index the MSHR that is pointed by the rid input.
		method Req_from_core#(paddr, data) req_to_fb(Bit#(id_bits) rid, Bool rlast);
			Req_from_core#(paddr, data) req= defaultValue;
			if(rg_curr_fb_id matches tagged Invalid) begin
				rg_curr_fb_id<= tagged Valid rid;
				req= (Req_from_core {	addr: {rg_mshr_line_addr[rid], ff_mshr[rid].addr},
															access_size: ff_mshr[rid].access_size,
															payload: ff_mshr[rid].payload,
															origin: ff_mshr[rid].origin });
			end
			else if(rlast) begin
				rg_curr_fb_id<= tagged Invalid;
			end

			return req;
		endmethod

		method Action ack_from_fb;
		endmethod
		
	endmodule

endpackage
