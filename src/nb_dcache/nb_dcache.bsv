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
2. Change appropriate interface parameters to module parameters
3. Add flush logic
4. Add a mux for IO request? Currently the io requests are captured in ff_io_request. They can either
	 be directly given through a separate master, or can be muxed with the existing master.
5. Integrate TLB
*/
package nb_dcache;
	import nb_dcache_types::*;          // for local cache types
	import DefaultValue :: *;
  `include "Logger.bsv"           // for logging
	import FIFO::*;
	import DefaultValue :: *;
	import GetPut::*;
  import mem_config::*;
	import SpecialFIFOs ::*;
  import BUtils::*;
	import mshr::*;
	import fill_buffer::*;
	import tlb::*;
	import replacement_dcache::*;
	`include "parameters.txt"

  String dcache=""; // defined for Logger
	 
	interface Ifc_nbdcache#(numeric type wordsize,	//size of data in bytes 
													numeric type linesize,	//number of words in a cache line
													numeric type setsize,		//number of sets
													numeric type ways,			//number of ways
													numeric type paddr,			//physical address width in bits
													numeric type vaddr,			//virtual address width in bits
													numeric type dsram,			//no. of bits in a row of SRAM cells for the data array
													numeric type tsram,			//no. of bits in a row of SRAM cells for the tag array
													numeric type prf_index,	//no. of bits to index the prf
													numeric type id_bits,		//no. of bits of the bus transaction id
													numeric type mshrsize,	//no. of fully associative entries in the mshr
													numeric type mshrfifo_depth,	//depth of FIFO corresponding to each MSHR
													numeric type buswidth);	//width of the bus in bits
		interface Put#(Req_from_core#(vaddr, TMul#(wordsize,8))) 		subifc_req_from_core;
		interface Get#(Resp_to_core#(TMul#(wordsize,8), prf_index))	subifc_resp_to_core;
		interface Get#((Req_from_core#(vaddr, TMul#(wordsize,8))))	subifc_req_to_ptw;
		interface Get#(Read_req_to_mem#(paddr, id_bits))            subifc_read_req_to_mem;
		interface Put#(Read_resp_from_mem#(buswidth, id_bits))      subifc_read_resp_from_mem;
		interface Get#(Write_req_to_mem#(paddr, buswidth))          subifc_write_req_to_mem;
		interface Put#(Bool)                                        subifc_write_resp_from_mem;
		method Bool cache_busy;
	endinterface

//	(*synthesize*)
//	module dataarr(Ifc_mem_config1r1w#(`Setsize, TMul#(`Linesize, TMul#(`Wordsize, 8)), `Dsram));
//		let ifc();
//		mkmem_config1r1w#(False) _temp(ifc);
//		return ifc;
//	endmodule
//
//	(*synthesize*)
//	module tagarr(Ifc_mem_config1r1w#(`Setsize, TAdd#(TSub#(`Paddr, TAdd#(TLog#(TMul#(`Linesize, TMul#(`Wordsize, 8))), TLog#(`Setsize))), 2), `Tsram));
//		let ifc();
//		mkmem_config1r1w#(False) _temp(ifc);
//		return ifc;
//	endmodule
//
//	(*synthesize*)
//	module fillbuffer(Ifc_fill_buffer#(`Paddr, TMul#(`Wordsize, 8), `Buswidth, TMul#(`Linesize, TMul#(`Wordsize, 8)), `Wordsize));
//		let ifc();
//		mkfill_buffer _temp(ifc);
//		return ifc;
//	endmodule
//
	//(*synthesize*)
	//module mshrmod(Ifc_mshr#(`Paddr, TMul#(`Linesize, TMul#(`Wordsize, 8)), TMul#(`Wordsize, 8), `Mshrsize, `Mshrfifo_depth));
	//	let ifc();
	//	mkmshr _temp(ifc);
	//	return ifc;
	//endmodule

	//(*synthesize*)
	//module replace(Ifc_replace#(`Setsize, `Ways));
	//	let ifc();
	//	mkreplace#("PLRU") _temp(ifc);
	//	return ifc;
	//endmodule

	(*descending_urgency = "rl_MSHR_req_to_fill_buffer, rl_tag_and_data_array_read_response"*)
	(*preempts = "rl_release_fb_cycle1, rl_handle_req_from_core"*)
	(*conflict_free = "rl_release_fb_cycle2, rl_tag_and_data_array_read_response"*)
	module mknb_dcache#(parameter String alg)
		(Ifc_nbdcache#(wordsize, linesize, setsize, ways, paddr, vaddr, dsram, tsram, prf_index, id_bits, mshrsize, mshrfifo_depth, buswidth))
		provisos(
			Mul#(wordsize, 8, datawidth),					// datawidth is the total bits in a word
			Mul#(linesize, datawidth, linewidth),	// linewidth is the total bits in a cache line
			Log#(linewidth, linewidthbits),				// linewidthbits is no. of bits to indicate byte offset within a line
			Log#(setsize, setbits),								// setbits is the no. of bits used as index in BRAMs
			Log#(mshrsize, mshrbits),							// mshrbits is the no. of bits used to index the MSHRs
			//Add#(, a__, id_bits),								// id_bits should be greater than Log(mshrsize+2)
			Add#(linewidthbits, setbits, tagpos),	// tagpos total bits for index + offset, 
			Add#(tagbits, tagpos, paddr),					// tagbits = paddr - (linewidthbits + setbits)
			Log#(buswidth, buswidthbits),
			Mul#(TDiv#(buswidth, datawidth), linesize, evict_iter),	//evict_iter is the burst length while evicting a cache line
			Add#(b__, prf_index, datawidth),
			//Add#(c__, linewidthbits, TLog#(TAdd#(ways, 1))),	//check again
			Add#(d__, TLog#(ways), TLog#(TAdd#(ways, 1))),			//Bluespec cribs
			Add#(e__, TLog#(TAdd#(mshrsize, 1)), id_bits),
			Add#(f__, paddr, vaddr),
			Mul#(g__, buswidth, linewidth),
			Add#(h__, buswidthbits, linewidth),
			Add#(i__, datawidth, linewidth),
			Add#(j__, linewidthbits,  paddr),
			Add#(k__, TDiv#(TAdd#(tagbits, 2), tsram), TAdd#(tagbits, 2)),
			Add#(l__, TLog#(ways), 4)						//required by the mkreplace module
			//Mul#(TDiv#(TAdd#(tagbits, 2), tsram), tsram, TAdd#(tagbits, 2)),
			//Add#(l__, TDiv#(linewidth, dsram), linewidth),
			//Add#(m__, TSub#(TAdd#(tagbits, 2), TMul#(tsram, TDiv#(TAdd#(tagbits, 2),tsram))), tsram),
			//Add#(n__, tsram, TAdd#(tagbits, 2)),
			//Add#(o__, TSub#(linewidth, TMul#(dsram, TDiv#(linewidth, dsram))), dsram),
			//Add#(p__, dsram, linewidth)
			//Mul#(TDiv#(linewidth, dsram), dsram, linewidth)
		);

		let ways_val= valueOf(ways);
		let paddr_val= valueOf(paddr);
		let datawidth_val= valueOf(datawidth);
		let buswidth_val= valueOf(buswidth);
		let linewidthbits_val= valueOf(linewidthbits);
		let setbits_val= valueOf(setbits);
		let tagbits_val= valueOf(tagbits);
		let tagpos_val= valueOf(tagpos);
		let buswidthbits_val= valueOf(buswidthbits);
		let evict_iter_val= valueOf(evict_iter);


		Ifc_mem_config1r1w#(setsize, linewidth, dsram) data_arr [ways_val]; 				// data array
		//TODO Make sure that for now (tagbits+2)/tsram is an integer. Will have to edit mem_config.
		Ifc_mem_config1r1w#(setsize, TAdd#(tagbits, 2), tsram) tag_arr [ways_val]; // extra valid and dirty bits
		Ifc_tlb#(vaddr, paddr) tlb <-mktlb;
		Ifc_fill_buffer#(paddr, datawidth, buswidth, linewidth, wordsize) fill_buffer <-mkfill_buffer;
		Ifc_mshr#(paddr, linewidthbits, datawidth, mshrsize, mshrfifo_depth) mshr <- mkmshr;
    Ifc_replace#(setsize, ways) repl <- mkreplace(alg);

		for(Integer i = 0;i<ways_val;i = i+1)begin
			data_arr[i] <- mkmem_config1r1w(False, fromInteger(i)+'habc0);
			tag_arr[i] <- mkmem_config1r1w(False, 'h30000);
		end

		//Ifc_mem_config1r1w#(`Setsize, TMul#(`Linesize, TMul#(`Wordsize, 8)), `Dsram) data_arr [ways_val]; 				// data array
		//Ifc_mem_config1r1w#(`Setsize, TAdd#(TSub#(`Paddr, TAdd#(TLog#(TMul#(`Linesize, TMul#(`Wordsize, 8))), TLog#(`Setsize))), 2), `Tsram) tag_arr [ways_val]; // extra valid and dirty bits
		//Ifc_tlb#(vaddr, paddr) tlb <-mktlb;
		//let fill_buffer <-fillbuffer;
		//let mshr <-mshrmod;
		//let repl <-replace;

		//for(Integer i = 0;i<ways_val;i = i+1)begin
		//	data_arr[i] <-dataarr;
		//	tag_arr[i] <- tagarr;
		//end

		////////////////////////////// Interface signals ///////////////////////////////////////////////
		//These handle the interface signals
		FIFO#(Req_from_core#(vaddr, datawidth)) ff_req_from_core <- mkBypassFIFO;
		Wire#(Resp_to_core#(datawidth, prf_index)) wr_resp_to_core <- mkWire;
		
		//If a req is a miss in the TLB, that request would be sent to the PTW module. PTW module will
		//store this req and also start performing the PTW. Once PTW is done, it again sends this req
		//to the cache. Now, this request will be a hit in the TLB. This FIFO is used to send the req to
		//the PTW module
		Wire#(Req_from_core#(vaddr, datawidth)) wr_req_to_ptw <- mkWire;
		FIFO#(Read_req_to_mem#(paddr, id_bits)) ff_read_req_to_mem <- mkFIFO;
		Wire#(Read_resp_from_mem#(buswidth, id_bits)) wr_read_resp_from_mem <- mkDWire(defaultValue);
		Wire#(Write_req_to_mem#(paddr, buswidth)) wr_write_req_to_mem <- mkWire;
		Wire#(Bool) wr_write_resp_from_mem <- mkWire;


		///////////////////////////// Module signals ///////////////////////////////////////////////////
		FIFO#(Req_from_core#(paddr, datawidth)) ff_first_stage <- mkFIFO;
		FIFO#(Req_from_core#(paddr, datawidth)) ff_second_stage <- mkFIFO;
		FIFO#(Req_from_core#(paddr, datawidth)) ff_io_request <- mkFIFO;

		Reg#(Bool) rg_cache_busy[2] <- mkCReg(2, False);	//TODO has to be reset depending upon when the leaf page is received
																									//		 or when PTW walk indicates so
		Reg#(Bit#(TLog#(evict_iter))) rg_evict_index <-mkReg(0);
		Reg#(FB_state) rg_fb_state <- mkReg(defaultValue);
		Reg#(Tuple2#(Bit#(TSub#(paddr,linewidthbits)) , Bit#(linewidth))) rg_eviction_buffer <-mkReg(tuple2(0,0)); 

		Wire#(Bool) wr_is_mshr_req_to_fb_valid <- mkDWire(False);
		
		function Bit#(linewidth) generate_masked_data(Bit#(linewidth) sram_data, Bit#(datawidth) core_data, Bit#(linewidthbits) line_addr, Bit#(2) size);
    	Bit#(datawidth) temp = size[1 : 0] == 0?'hFF : 
    	                       size[1 : 0] == 1?'hFFFF : 
    	                       size[1 : 0] == 2?'hFFFFFFFF : '1;

    	Bit#(linewidth) mask = zeroExtend(temp);
    	Bit#(datawidth) zeros = 0;
    	mask = mask<<{line_addr,3'd0};
			Bit#(linewidth) writedata= (mask & duplicate(core_data)) |(~mask & sram_data);
			return writedata;
		endfunction

		function Bit#(datawidth) fn_extract_data(Bit#(linewidth) line, Bit#(linewidthbits) line_addr, Bit#(2) size);
    	Bit#(datawidth) mask = size[1 : 0] == 0?'hFF : 
    	                       size[1 : 0] == 1?'hFFFF : 
    	                       size[1 : 0] == 2?'hFFFFFFFF : '1;

    	line = line>>{line_addr,3'd0};
			Bit#(datawidth) readdata= truncate(line) & mask;
			return readdata;
		endfunction

		rule rl_handle_req_from_core;
			let req= ff_req_from_core.first;
			Bool is_actual_store= (req.origin == Store_commit);
			Bit#(setbits) set_index = req.addr[setbits_val + linewidthbits_val - 1 : linewidthbits_val];
      `logLevel( dcache, 2, $format("DCACHE : Core_req: ", fshow(req)))
			
			for(Integer i = 0;i<ways_val;i = i+1) begin
				data_arr[i].read(set_index);
				tag_arr[i].read(set_index);
			end
			if(req.origin!=PTW)
				tlb.send_req(req.addr, is_actual_store);
		endrule

		rule rl_get_response_from_TLB;
			let orig_req= ff_req_from_core.first;

			Req_from_core#(paddr, datawidth) req= Req_from_core {	addr: orig_req.addr[paddr_val-1:0],
																														access_size: orig_req.access_size,
																														payload: orig_req.payload,
																														origin: orig_req.origin };
			ff_req_from_core.deq;
			if(req.origin!=PTW) begin
				let resp_from_tlb= tlb.response;
				if(resp_from_tlb.is_hit) begin			//Hit in the TLB

      		`logLevel( dcache, 2, $format("DCACHE : Hit in the TLB"))
					if(resp_from_tlb.is_fault) begin	//Access fault
						Bit#(prf_index) lv_prf_index= truncate(orig_req.payload);
						wr_resp_to_core<= Resp_to_core { data: ?,
																						 prf_index: lv_prf_index,
																						 exception: Access_fault };
					end
					else begin	//Access is valid
						//The virtual address is not required here after. Hence, the addr in the req is replaced
						//with the physical address
						req.addr= resp_from_tlb.paddr;
      			`logLevel( dcache, 2, $format("DCACHE : Physical addr from TLB: %h", req.addr))
						if(resp_from_tlb.is_io) begin
							//Enqueue into a separate FIFO that handles IO Requests
							ff_io_request.enq(req);
						end
						else begin	//Else it's a cacheable request and therefore enqueue in the first stage FIFO.
							ff_first_stage.enq(req);
						end
					end

				end
				else begin		//Miss in the TLB
      		`logLevel( dcache, 2, $format("DCACHE : Miss in the TLB"))
					wr_req_to_ptw<= orig_req;		//TODO PTW will store the req and send it again, once PTW is done.
					rg_cache_busy[0]<= True;
				end
			end
			else begin	//PTW request
      	`logLevel( dcache, 2, $format("DCACHE : Req from PTW: ", fshow(req)))
				ff_first_stage.enq(req);
				//ff_first_stage.enq(Req_from_core {addr: truncate(req.addr),
				//																	access_size: req.access_size,
				//																	payload: req.payload,
				//																	origin: req.origin });
			end
		endrule

		rule rl_tag_and_data_array_read_response;
			let req= ff_first_stage.first;
			ff_first_stage.deq;
			Bit#(linewidth) dataline [ways_val];
			Bit#(TAdd#(tagbits,2)) tag;
			Bit#(TLog#(TAdd#(ways,1))) way_num='d-1;
			Bit#(tagbits) req_tag= req.addr[paddr_val-1: tagpos_val];
			Bool send_resp= (req.origin==Load_buffer || req.origin==PTW);

			for(Integer i = 0; i<ways_val; i = i+1) begin
				dataline[i] = data_arr[i].read_response();
				tag = tag_arr[i].read_response();
				//If a tag in the SRAMs is valid and is equal to the tag of the request, it's a hit in the cache
				if(tag[tagbits_val]==1 && tag[tagbits_val-1:0]== req_tag) begin		
					way_num= fromInteger(i);	//Store the index of the tag match
				end
			end

			if(way_num!='1) begin																		//It's a line hit
				Bit#(TLog#(ways)) hit_index= truncate(way_num);
				Bit#(setbits) set_index = req.addr[setbits_val + linewidthbits_val - 1 : linewidthbits_val];
				let line= dataline[hit_index];
      	`logLevel( dcache, 2, $format("DCACHE : Hit in the dcache", fshow(req)))
      	`logLevel( dcache, 2, $format("DCACHE : Hit at set_index: %d way_num: %d line: ", set_index, hit_index, line))

				if(send_resp) begin
					//Get the right offset data and return to core (Even PTW will take it from here)
					Bit#(datawidth) data_to_core= fn_extract_data(line, truncate(req.addr), req.access_size);	//TODO Make UniqueWrapper for this fn
      		`logLevel( dcache, 2, $format("DCACHE : Hit response to proc for load: %h", data_to_core))
					if(req.origin==Load_buffer || req.origin==PTW) begin	//TODO remove this
						wr_resp_to_core<= Resp_to_core { data: data_to_core,
																						 prf_index: truncate(req.payload),
																						 exception: No_exception };
					end
				end
				else if(req.origin==Store_commit) begin								//Store instruction
    			Bit#(linewidthbits) line_addr= req.addr[linewidthbits_val-1:0];
					let write_data= generate_masked_data(line, req.payload, line_addr, req.access_size);
					Bit#(TLog#(ways)) data_arr_index= truncate(way_num);
      		data_arr[data_arr_index].write(set_index, write_data);
      		`logLevel( dcache, 2, $format("DCACHE : Hit for store. Writing: %h", write_data))
				end
      	repl.update_set(set_index, hit_index);								//Update the replacement bits on a hit
			end
			else begin																							//Line miss; send req to fill buffer
				//let fb_addr= req.addr[paddr_val-1:linewidthbits_val];
				let fill_buffer_resp<- fill_buffer.request(req); 			//Req and resp to/from fill buffer
				//Fill buffer holds the data corresponding to the line (and the data is valid in the fill buffer) and
				//if a response needs to be sent (i.e. a load_buffer or a PTW request).
				//Here, fb_data is the complete fill buffer line
      	`logLevel( dcache, 2, $format("DCACHE : Miss in the dcache for req:", fshow(req)))
				if(fill_buffer_resp matches tagged Valid .fb_data) begin
					`logLevel( dcache, 2, $format("DCACHE : Fill buffer hit with data: %h",  fb_data))
					if(send_resp) begin
						Bit#(datawidth) data_to_core= fn_extract_data(fb_data, truncate(req.addr), req.access_size);
						wr_resp_to_core<= Resp_to_core { data: data_to_core,
																						 prf_index: truncate(req.payload),
																						 exception: No_exception };
					end
					//else do nothing
				end
				else begin
					`logLevel( dcache, 2, $format("DCACHE : Fill buffer miss"))
					ff_second_stage.enq(req);														//Pass the req to the next stage
				end
			end
		endrule

		rule rl_access_MSHRs;
			let req= ff_second_stage.first;
			ff_second_stage.deq;
			let mshr_resp<- mshr.allocate(req);
			if(mshr_resp matches tagged Valid .read_req_from_mshr) begin
				Bit#(TSub#(paddr, buswidthbits)) read_addr= tpl_1(read_req_from_mshr)[paddr_val-1:buswidthbits_val];
				let read_id= tpl_2(read_req_from_mshr);
				`logLevel( dcache, 2, $format("DCACHE : MSHR %d initiated a memory request for addr: %h",read_id, read_addr))
				ff_read_req_to_mem.enq(Read_req_to_mem {addr: zeroExtend(read_addr),
																								id: zeroExtend(read_id),
																								is_burst: True });
			end
		endrule

		//This will fire only in those clock cycles when MSHR wants to send a R/W req to FB
		//This rule polls the MSHR with the rid of memory response to know if any pending requests to that
		//rid exists in the MSHR FIFOs. Also, when there is no read response from memory, the MSHR sends
		//any requests that are pending corresponding to the current entry in the fill buffer.
		//These requests are then sent to the fill buffer to check if they were a hit (Note that there
		//can be a miss in the fill buffer if only the first chunk has arrived from the memory, but the
		//request is to data in the third chunk). If it's a hit, an ack is sent to the MSHR to dequeue
		//that FIFO entry, and send the next request. If it's a miss, no ack is sent, and in the subsequent
		//clock cycles, the same request is sent by the MSHR to the fill buffer.
		//Also, in the case of a hit, if it were a Load request or a PTW request, a response is sent.
		rule rl_MSHR_req_to_fill_buffer;
			let resp_from_mem= wr_read_resp_from_mem;
			`logLevel( dcache, 2, $format("DCACHE : Response from memory: ", fshow(resp_from_mem)))
			let maybe_req_from_mshr<- mshr.req_to_fb(truncate(resp_from_mem.id));		//Receive the request from MSHR corresponding to the rid

			//Send the req to fill buffer and check if it's a hit
			if(maybe_req_from_mshr matches tagged Valid .req_from_mshr) begin
				`logLevel( dcache, 2, $format("DCACHE : Request from MSHR to FB: ", fshow(req_from_mshr)))
				wr_is_mshr_req_to_fb_valid<= True;
				let fb_addr= req_from_mshr.addr[paddr_val-1:linewidthbits_val];
				let fill_buffer_resp<- fill_buffer.request(req_from_mshr); 			//Send request to fill buffer
				if(fill_buffer_resp matches tagged Valid .fb_data) begin
					`logLevel( dcache, 2, $format("DCACHE : Response data from FB to MSHR: %h", fb_data ))
					mshr.ack_from_fb;
					Bool send_resp= (req_from_mshr.origin==Load_buffer || req_from_mshr.origin==PTW);
					if(send_resp) begin
						Bit#(datawidth) data_to_core= fn_extract_data(fb_data, truncate(req_from_mshr.addr), req_from_mshr.access_size);
						wr_resp_to_core<= Resp_to_core { data: data_to_core,
																						 prf_index: truncate(req_from_mshr.payload),
																						 exception: No_exception };
					end
					//else do nothing
					else begin
						`logLevel( dcache, 2, $format("DCACHE : Data for MSHR req is not yet available in the FB" ))
					end
				end
			end
		endrule
		
		//Once the fill buffer indicates that it can be released(i.e. the complete line is available,
		//and no pending MSHR requests exist to the same line*), the data and tag SRAMs are issued a read
		//request to determine which way should be assigned for this line.
		//*Caveat: Though the FIFOs, corresponding to the MSHR entry (corresponding to the line address)
		//				 might be empty, there might be a request pending in the ff_second_stage. This is fine
		//				 as the fill buffer is invalidated only after 3 clock cycles.
		rule rl_release_fb_cycle1(fill_buffer.can_release && wr_is_mshr_req_to_fb_valid==False && rg_fb_state==defaultValue);
			Bit#(setbits) set_index= fill_buffer.line_addr[setbits_val-1:0];
			`logLevel( dcache, 2, $format("DCACHE : Initiating release of FB to line address: %h", fill_buffer.line_addr))
			for(Integer i = 0;i<ways_val;i = i+1) begin
				data_arr[i].read(set_index);
				tag_arr[i].read(set_index);
			end
			rg_fb_state<= Write_SRAMs;
		endrule

		//This rule performs actions for the second cycle of fill buffer release. In this cycle, the
		//line from the fill buffer is written onto one of the ways depending on the replacement policy.
		//Also, if the existing line was a dirty line, it is written onto the eviction buffer.
		//The tag bits along with the valid and replacement bits are also updated in this cycle.
		rule rl_release_fb_cycle2(rg_fb_state==Write_SRAMs);
			let line_addr= fill_buffer.line_addr;
			Bit#(setbits) set_index= line_addr[setbits_val-1:0];
			Bit#(linewidth) dataline [ways_val];
			Bit#(tagbits) tag [ways_val];
			Bit#(ways) valid;
			Bit#(ways) dirty;

			for(Integer i = 0; i<ways_val; i = i+1) begin
				dataline[i] = data_arr[i].read_response();
				let lv_tag_arr = tag_arr[i].read_response();
				tag[i]= truncate(lv_tag_arr);					//Lower bits hold the value of the tags
				valid[i]= lv_tag_arr[tagbits_val];		//Valid bits
				dirty[i]= lv_tag_arr[tagbits_val+1];	//Dirty bits
			end

			//waynum indicates the way number to which the fill buffer contents will be written to.
			//The replacement bits decide the value of way num depending on the replacement policy used.
      let waynum <- repl.line_replace(set_index, valid, dirty);
      repl.update_set(set_index, waynum);	//Update the replacement bits

			let {fb_dirty,fb_data}= fill_buffer.data;
			Bit#(tagbits) lv_tag= line_addr[tagbits_val+setbits_val-1:setbits_val];
			Bit#(TAdd#(tagbits,2)) lv_dirty_valid_tag= {fb_dirty, 1'b1, lv_tag};
			data_arr[waynum].write(set_index, fb_data);
			tag_arr[waynum].write(set_index, lv_dirty_valid_tag);
			`logLevel( dcache, 2, $format("DCACHE : Updating way_num: %d and set_index: %d with data: %h and tag: %h", waynum, set_index, fb_data, lv_dirty_valid_tag))

			//Eviction buffer should be written only when there is something to evict, else skip the eviction buffer cycle
			if(valid[waynum]==1 && dirty[waynum]==1) begin
				Bit#(TAdd#(tagbits, setbits)) evict_lineaddr= {set_index, tag[waynum]};
				rg_eviction_buffer<= tuple2(evict_lineaddr, dataline[waynum]);
				rg_fb_state<= Release_eviction_buffer;
				`logLevel( dcache, 2, $format("DCACHE : Eviction buffer being written with line_address: %h and data: %h", evict_lineaddr, dataline[waynum]))
			end
			else begin
				rg_fb_state<= defaultValue;
				`logLevel( dcache, 2, $format("DCACHE : Updated line is not dirty. Hence, no updation to eviction buffer"))
			end
		endrule

		//Releasing the fill buffer entry happens in a cycle after the tag and data arrays have been updated,
		//because in this cycle there might be a request that is pending in ff_first_stage. Therefore in the
		//cycle where this rule is getting executed, the request from ff_first_stage is serviced.
		//This rule executes for evict_iter number of cycles. This keeps sending buswidth bits of data in
		//a cycle untill the line is completely written onto the fabric.
		rule rl_release_eviction_buffer(rg_fb_state==Release_eviction_buffer);
			if(rg_evict_index==0) begin	//In the first cycle, release the fill buffer entry
				fill_buffer.release_fb;
				`logLevel( dcache, 2, $format("DCACHE : Freeing FB"))
			end

			if(rg_evict_index==fromInteger(evict_iter_val-1)) begin	//In the last cycle, reset the variables
				rg_fb_state<= defaultValue;
				rg_evict_index<= 0;
			end
			else begin		//Increment the index variable that is used to extract the appropriate bits of line
				rg_evict_index<= rg_evict_index+1;
			end

			let {line_addr, data}= rg_eviction_buffer;
			Bit#(linewidthbits) some_zeros= 0;
			//Send a write request to the memory
			Write_req_to_mem#(paddr, buswidth) lv_write_req= Write_req_to_mem { addr: {line_addr[paddr_val-linewidthbits_val-1:0], some_zeros},
																							 data: data[(rg_evict_index+1)<<buswidthbits_val: rg_evict_index<<buswidthbits_val]};
			wr_write_req_to_mem<= lv_write_req;
			`logLevel( dcache, 2, $format("DCACHE : Write request to mem from eviction buffer: ", fshow(lv_write_req)))
		endrule

		interface subifc_req_from_core= toPut(ff_req_from_core);

		interface subifc_resp_to_core= toGet(wr_resp_to_core);
		//interface Get#(Resp_to_core#(datawidth, prf_index)) subifc_resp_to_core;
		//	method ActionValue#(Resp_to_core#(datawidth, prf_index)) get;
		//		return wr_resp_to_core;
		//	endmethod
		//endinterface

		interface subifc_req_to_ptw= toGet(wr_req_to_ptw);
	//		method ActionValue#((Req_from_core#(vaddr, datawidth, prf_index))) get;
	//			return wr
		interface subifc_read_req_to_mem= toGet(ff_read_req_to_mem);

		interface subifc_read_resp_from_mem= interface Put
		//interface Put#(Read_resp_from_mem#(data, id_bits)) subifc_read_resp_from_mem;
			method Action put(Read_resp_from_mem#(buswidth, id_bits) resp);
				wr_read_resp_from_mem<= resp;
				fill_buffer.data_from_mem(resp.data, resp.last);
			endmethod
		endinterface;

		interface subifc_write_req_to_mem= toGet(wr_write_req_to_mem);
		//interface Get#(Write_req_to_mem#(vaddr, data)) subifc_write_req_to_mem;
		//	method ActionValue#(Write_req_to_mem) get;
		//		return wr_write_req_to_mem;
		//	endmethod
		//endinterface

		interface subifc_write_resp_from_mem= interface Put
			method Action put(Bool resp);
				 wr_write_resp_from_mem<= resp;
			endmethod
		endinterface;

		method Bool cache_busy;
			return rg_cache_busy[1];
		endmethod

	endmodule

  (*synthesize*)
  module mkdcache(Ifc_nbdcache#(`Wordsize, `Linesize, `Setsize, `Ways, `Paddr, `Vaddr, `Dsram, `Tsram, `Prf_index, `Id_bits, `Mshrsize, `Mshrfifo_depth, `Buswidth));
    let ifc();
    mknb_dcache#("PLRU") _temp(ifc);
    return (ifc);
  endmodule

	//(*synthesize*)
	//module mknb_dcache_instance(Ifc_nbdcache#(8, 8, 64, 4, 32, 49, 32, 32, 7, 4, 5, 7, 128));
  //  let ifc();
  //  mknb_dcache#("PLRU") _temp(ifc);
  //  return (ifc);
  //endmodule
endpackage
