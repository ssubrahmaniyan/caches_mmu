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
TODO
1. Optimize the first stage buffer where you do not send the virtual page number to the next stage.
   Instead, when you get the physical page number, concat that with the offset address and send it to 
	 the next stage.
*/
package nb_dcache;
	import cache_types::*;          // for local cache types

	interface Ifc_nbdcache#(numeric type wordsize, 
													numeric type linesize,
													numeric type setsize,
													numeric type ways,
													numeric type paddr,
													numeric type vaddr,
													numeric type dbanks,
													numeric type tbanks,
													numeric type prf_index,
													numeric type id_bits,
													numeric type mshrsize,
													numeric type buswidth);
		interface Put#(Req_from_core#(vaddr, TMul#(wordsize,8), prf_index)) subifc_req_from_core;
		interface Get#(Resp_to_core#(TMul#(wordsize,8), prf_index))         subifc_resp_to_core;
		interface Get#(Req_to_ptw#(vaddr))                                  subifc_req_to_ptw;
		interface Get#(Read_req_to_mem#(vaddr, id_bits))                    subifc_read_req_to_mem;
		interface Put#(Read_resp_from_mem#(buswidth, id_bits))              subifc_read_resp_from_mem;
		interface Get#(Write_req_to_mem#(vaddr, buswidth))                  subifc_write_req_to_mem;
		interface Put#(Bool)                                                subifc_write_resp_from_mem;
		
	endinterface

	module mk_dcache(Ifc_nbdcache#(wordsize, linesize, setsize, ways, paddr, vaddr, prf_index, id_bits, mshrsize)
		provisos(
			Mul#(wordsize, 8, datawidth),					// datawidth is the total bits in a word
			Mul#(linesize, datawidth, linewidth),	// linewidth is the total bits in a cache line
			Log#(linewidth, linewidthbits),			// linewidthbits is no. of bits to indicate byte offset within a line
			Log#(setsize, setbits),								// setbits is the no. of bits used as index in BRAMs
			Log#(mshrsize, mshrbits),							// mshrbits is the no. of bits used to index the MSHRs
			Add#(mshrsize, 2, temp1),
			Log#(temp1, temp1_bits),
			Add#(temp1_bits, a__, id_bits)				// id_bits should be greater than Log(mshrsize+2)
			Add#(linewidthbits, setbits, tagpos),	// tagpos total bits for index + offset, 
			Add#(tagbits, tagpos, paddr),					// tagbits = paddr - (linewidthbits + setbits)


		);

		let ways_val= valueOf(ways);
		let datawidth_val= valueOf(datawidth);
		let linewidthbits_val= valueOf(linewidthbits);
		let setbits_val= valueOf(setbits);
		let tagbits_val= valueOf(tagbits);
		let tagpos_val= valueOf(tagpos);


		Ifc_mem_config1r1w#(setsize, linewidth, dbanks) data_arr [ways_val]; 				// data array
		Ifc_mem_config1r1w#(setsize, TAdd#(tagbits, 2), tbanks) tag_arr [ways_val]; // extra valid and dirty bits

		for(Integer i = 0;i<v_ways;i = i+1)begin
			data_arr[i] <- mkmem_config1r1w(False, "single"); 
			tag_arr[i] <- mkmem_config1r1w(False, "single");
		end

		//These handle the interface signals
		FIFO#(Req_from_core#(vaddr, TMul#(wordsize,8), prf_index)) ff_req_from_core <- mkBypassFIFO;
		FIFO#(Resp_to_core#(TMul#(wordsize,8), prf_index)) ff_read_resp_to_core <- mkFIFO;
		FIFO#(Req_from_core#(vaddr, TMul#(wordsize,8), prf_index)) ff_req_to_ptw <- mkFIFO;
		FIFO#(Read_req_to_mem(vaddr, id_bits)) ff_read_req_to_mem <- mkFIFO;
		Wire#(Read_resp_from_mem(data, id_bits)) wr_read_resp_from_mem <- mkWire;
		Wire#(Write_req_to_mem(vaddr, data)) wr_write_req_to_mem <- mkWire;
		Wire#(Bool) wr_write_resp_from_mem <- mkWire;

		//Within the module
		FIFO#(Req_from_core#(vaddr, TMul#(wordsize,8), prf_index)) ff_first_stage <- mkFIFO;

		Reg#(Bool) rg_cache_busy <- mkCReg(2, False);	//TODO has to be reset depending upon when the leaf page is received
																									//		 or when PTW walk indicates so
		
		function Bit#(linewidth) generate_masked_data(Bit#(linewidth) sram_data, Bit#(datawidth) core_data, Bit#(linewidthbits) line_addr);
    	Bit#(datawidth) temp = size[1 : 0] == 0?'hFF : 
    	                       size[1 : 0] == 1?'hFFFF : 
    	                       size[1 : 0] == 2?'hFFFFFFFF : '1;

    	Bit#(linewidth) mask = zeroExtend(temp);
    	Bit#(datawidth) zeros = 0;
    	mask = mask<<{line_addr,3'd0};
			let writedata= (mask & duplicate(core_data)) |(~mask & sram_data);
		endfunction

		rule rl_handle_req_from_core;
			let req= ff_req_from_core.first;
			Bool is_actual_load= (req.origin == Load_buffer);
			Bit#(setbits) set_index = req.addr[setbits_val + linewidthbits_val - 1 : linewidthbits_val];
			for(Integer i = 0;i<v_ways;i = i+1) begin
				data_arr[i].request(0, set_index, ?);
				tag_arr[i].request(0, set_index, ?);
			end
			if(req.origin!=PTW)
				tlb.send_req(req.addr, is_actual_load);
		endrule

		rule rl_get_response_from_TLB;
			let req= ff_req_from_core.first;
			ff_req_from_core.deq;
			if(req.origin!=PTW) begin
				let resp_from_tlb= tlb.response;
				if(resp_from_tlb.is_hit) begin			//Hit in the TLB
					if(resp_from_tlb.is_fault) begin	//Access fault
						wr_resp_to_core<= Resp_to_core { data: ?,
																						 prf_index: req.prf_index,
																						 exception: Access_fault };
					end
					else begin	//Access is valid
						//The virtual address is not required here after. Hence, the addr in the req is replaced
						//with the physical address
						if(resp_from_tlb.is_io) begin
							//Enqueue into a separate FIFO that handles IO Requests
							ff_io_request.enq(req);
						req.addr= zeroExtend(resp_from_tlb.paddr);
						ff_first_stage.enq(req);
					end
				end
				else begin		//Miss in the TLB
					ff_req_to_ptw.enq(req);		//TODO PTW will store the req and send it again, once PTW is done.
					rg_cache_busy[0]<= True;
				end
			end
			else begin	//PTW request
				ff_first_stage.enq(req);
			end
		endrule

		rule rl_tag_and_data_array_read_response;
			let req= ff_first_stage.first;
			ff_first_stage.deq;
			Bit#(linewidth) dataline [v_ways];
			Bit#(tagbits) tag [v_ways];
			Bit#(TLog#(TAdd#(ways,1))) way_num='d-1;
			Bit#(tagbits) tag= req.addr[paddr_val-1: tagpos_val];

			for(Integer i = 0;i<v_ways;i = i+1)begin
				dataline[i] <- data_arr[i].read_response();
				tag[i] <- tag_arr[i].read_response();
				//If a tag in the SRAMs is valid and is equal to the tag of the request, it's a hit in the cache
				if(tag[i][tagbits_val]==1 && tag[i][tagbits_val-1:0]==tag) begin		
					way_num== fromInteger(i);	//Store the index of the tag match
				end
			end

			Bool send_resp= False;
			if(req.origin==Load_buffer || req.origin==PTW) begin
				send_resp= True;
			end

			if(way_num!='d-1) begin																			//It's a line hit
				let line= dataline[truncate(way_num)];
				if(send_resp) begin
					//Get the right offset data and return to core (Even PTW will take it from here)
					Bit#(data) data_to_core= fn_extract_data(line);	//TODO Make UniqueWrapper for this fn
					wr_resp_to_core<= Resp_to_core { data: data_to_core,
																					 prf_index: req.prf_index,
																					 exception: None };
				end
				else if(req.origin==Store_commit) begin								//Store instruction
					Bit#(setbits) set_index = req.addr[setbits_val + linewidthbits_val - 1 : linewidthbits_val];
    			Bit#(linewidthbits) line_addr= req.addr[lineoffsetbits_val-1:0];
					let write_data= generate_masked_data(dataline[i], req.data, line_addr);
      		data_arr[truncate(way_num)].request(1, set_index, write_data);
				end
			end
			else begin																							//Line miss
				let fb_addr= req.addr[paddr_val-1:linewidthbits_val];
				let fill_buffer_resp<- fill_buffer.request(req); 			//Send request to fill buffer
				//Fill buffer holds the data corresponding to the line (and the data is valid in the fill buffer) and
				//if a response needs to be sent (i.e. a load_buffer or a PTW request).
				//Here, fb_data is the complete fill buffer line
				if(fill_buffer_resp matches tagged Valid .fb_data) begin
					if(send_resp) begin
						Bit#(data) data_to_core= fn_extract_data(fb_data);	//TODO Make UniqueWrapper for this fn
						wr_resp_to_core<= Resp_to_core { data: data_to_core,
																						 prf_index: req.prf_index,
																						 exception: None };
					end
					//else do nothing
				end
				else begin																						//Fill buffer miss
					ff_second_stage.enq(req);														//Pass the req to the next stage
				end
			end
		endrule

		rule rl_access_MSHRs;
			let req= ff_second_stage.first;
			ff_second_stage.deq;
			let mshr_resp<- mshr.allocate(req);
			if(mshr_resp matches tagged Valid .read_req) begin
				ff_read_req_to_mem.enq(read_req);
			end
		endrule

		//This will fire only in those clock cycles when MSHR wants to send a R/W req to FB
		rule rl_MSHR_req_to_fill_buffer;
			let resp_from_mem= wr_read_resp_from_mem;
			let req_from_mshr= mshr.req_to_fb(resp_from_mem.rid);		//Receive the request from MSHR corresponding to the rid
			let fb_addr= req_from_mshr.addr;												//Compute the address to match in the MSHR

			//Send the req to fill buffer and check if it's a hit
			let fb_resp<- fill_buffer.request(req_from_mshr);

			if(fb_resp matches tagged Valid .fb_resp_data) begin		//If it's a hit in the fill buffer
				mshr.ack_from_fb;					//Send ack to mshr to dequeue the FIFO
				if(req_from_mshr.is_load) begin		//If it's a load request, send response to processor
					let data_to_core= fn_extract_data(fb_resp_data);
					wr_resp_to_core<= Resp_to_core { data: data_to_core,
																					 prf_index: req_from_mshr.prf_index,
																					 exception: None };
				end
			end
		endrule
		
		interface subifc_req_from_core= to_Put(ff_req_from_core);

		interface subifc_resp_to_core= to_Get(ff_read_resp_to_core);

		interface subifc_req_to_ptw= to_Get(ff_req_to_ptw);		

		interface subifc_read_req_to_mem= to_Get(ff_read_req_to_mem);

		interface Put#(Read_resp_from_mem#(data, id_bits)) subifc_read_resp_from_mem;
			method Action put(Read_resp_from_mem#(data, id_bits) resp);
				wr_read_resp_from_mem<= resp;
			endmethod
		endinterface

		interface Get#(Write_req_to_mem#(vaddr, data))                     subifc_write_req_to_mem;
			method ActionValue#(Write_req_to_mem) get;
				return wr_write_req_to_mem;
			endmethod
		endinterface

		interface Put#(Bool)                                               subifc_write_resp_from_mem;
			method Action#(Bool) put;
				return wr_write_resp_from_mem;
			endmethod
		endinterface

		method Bool mv_cache_bust;
			return rg_cache_busy[1];
		endmethod

	endmodule
endpackage
