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

	interface Ifc_mshr#(numeric type addr,
											numeric type data,
											numeric type id_bits);
		method ActionValue#(Maybe#(Read_req_to_mem)) allocate (Req_from_core#(addr, data) req);
		method Req_from_core#(addr, data) req_to_fb(Bit#(id_bits) rid, Bool rlast);
		method Action ack_from_fb;
	endinterface

	module mkmshr#(linewidthbits, mshrsize) (Ifc_mshr#(paddr, linewidthbits, data, id_bits, prfindex, mshrsize)
				 provisos (	Add#(paddr, lineaddrbits, linewidthbis),
				 						Log#(mshrsize, mshrbits)
			 						 ));

		Reg#(Bit#(lineaddrbits)) rg_line_addr [mshrsize];
		Reg#(Bit#(id_bits)) rg_curr_fb_id <- mkReg(0);

		for(Integer i=0; i<mshrsize; i=i+1)
			rg_line_addr[i] <- mkReg(0);

		
		method Action allocate (Req_from_core#(addr, data, prfindex) req);

		endmethod

		method Req_from_core#(addr, data) req_to_fb(Bit#(id_bits) rid, Bool rlast);
			if(rg_curr_fb_id matches tagged Invalid) begin
				rg_curr_fb_id<= tagged Valid rid;
			end
			else if(rlast) begin
				rg_curr_fb_id<= tagged Invalid;
			end

			return Req_from_core {addr: ,
														access_size,
														payload,
														origin};
		endmethod

		method Action ack_from_fb;
		endmethod
		
	endmodule

endpackage
