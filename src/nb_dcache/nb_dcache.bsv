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
package nb_dcache;
  import cache_types::*;          // for local cache types

	interface Ifc_nbdcache#(numeric type wordsize, 
													numeric type blocksize,  
													numeric type sets,
													numeric type ways,
													numeric type paddr,
													numeric type vaddr,
													numeric type dbanks,
													numeric type tbanks,
													numeric type prf_index,
													numeric type id_bits,
													numeric type mshr_size);
		interface Put#(Req_from_core#(vaddr, TMul#(wordsize,8), prf_index)) subifc_req_from_core;
		interface Get#(Resp_to_core#(TMul#(wordsize,8), prf_index))         subifc_resp_to_core;
		interface Get#(Req_to_ptw#(vaddr))                                  subifc_req_to_ptw;
		interface Get#(Read_req_to_mem#(vaddr, id_bits))                    subifc_read_req_to_mem;
		interface Put#(Read_resp_from_mem#(data, id_bits))                  subifc_read_resp_from_mem;
		interface Get#(Write_req_to_mem#(vaddr, data))                      subifc_write_req_to_mem;
		interface Put#(Bool)                                                subifc_write_resp_from_mem;
		
	endinterface

	module mk_dcache(Ifc_nbdcache#(wordsize, blocksize, sets, ways, paddr, vaddr, prf_index, id_bits, mshr_size)
		provisos(
    	Mul#(wordsize, 8, respwidth),         // respwidth is the total bits in a word
    	Mul#(blocksize, respwidth, linewidth),// linewidth is the total bits in a cache line
    	Log#(wordsize, wordbits),     // wordbits is no. of bits to index a byte in a word
    	Log#(blocksize, blockbits),   // blockbits is no. of bits to index a word in a block
    	Log#(sets, setbits),          // setbits is the no. of bits used as index in BRAMs
			Log#(mshr_size, mshr_bits),		// mshr_bits is the no. of bits used to index the MSHRs
			Add#(mshr_size, 2, temp1),
			Log#(temp1, temp1_bits),
			Add#(temp1_bits, a__, id_bits)		//id_bits should be greater than Log(mshr_size+2)
 			Add#(wordbits, blockbits, temp2), // temp2 total bits to index a byte in a cache line.
 			Add#(temp2, setbits, temp3),			// _b total bits for index + offset, 
 			Add#(tagbits, temp3, paddr),			// tagbits = 32 - (wordbits + blockbits + setbits)

		);

		let ways_val= valueOf(ways);
		let wordbits_val= valueOf(wordbits);
		let blockbits_val= valueOf(blockbits);
		let setbits_val= valueOf(setbits);


    Ifc_mem_config1r1w#(sets, linewidth, dbanks) data_arr [ways_val]; // data array
    Ifc_mem_config1r1w#(sets, tagbits, tbanks) tag_arr [ways_val];// one extra valid bit

		for(Integer i = 0;i<v_ways;i = i+1)begin
      data_arr[i] <- mkmem_config1r1w(False, "single"); 
      tag_arr[i] <- mkmem_config1r1w(False, "single");
    end

		//These handle the interface signals
		FIFO#(Req_from_core#(vaddr, TMul#(wordsize,8), prf_index)) ff_req_from_core <- mkBypassFIFO;
		Wire#(Resp_to_core#(TMul#(wordsize,8), prf_index)) wr_resp_to_core <- mkWire;
    FIFO#(Req_from_core#(vaddr, TMul#(wordsize,8), prf_index)) ff_req_to_ptw <- mkFIFO;
		FIFO#(Read_req_to_mem(vaddr, id_bits)) ff_read_req_to_mem <- mkFIFO;
		Wire#(Read_resp_from_mem(data, id_bits)) wr_read_resp_from_mem <- mkWire;
		Wire#(Write_req_to_mem(vaddr, data)) wr_write_req_to_mem <- mkWire;
		Wire#(Bool) wr_write_resp_from_mem <- mkWire;

		//Within the module
		FIFO#(Req_from_core#(vaddr, TMul#(wordsize,8), prf_index)) ff_first_stage <- mkFIFO;

		Reg#(Bool) rg_cache_busy <- mkReg(False);	//TODO has to be reset depending upon when the leaf page is received
		
		rule rl_handle_req_from_core;
			let req= ff_req_from_core.first;
			Bool is_actual_load= (req.origin == Load_buffer);
		  Bit#(setbits) set_index = req.addr[setbits_val + blockbits_val + wordbits_val - 1 :
                                         blockbits_val + wordbits_val];
      for(Integer i = 0;i<v_ways;i = i+1) begin
        data_arr[i].request(0, set_index, ?);
        tag_arr[i].request(0, set_index, ?);
      end
			if(req.origin != PTW)
				tlb.send_req(req.addr, is_actual_load);
		endrule

		rule rl_get_response_from_TLB;
			let resp_from_tlb= tlb.response;
			let req= ff_req_from_core.first;
			ff_req_from_core.deq;
			if(req.origin != PTW) begin
				if(resp_from_tlb.is_hit) begin			//Hit in the TLB
					if(resp_from_tlb.is_fault) begin	//Access fault
						wr_resp_to_core<= Resp_to_core { data: ?,
																						 prf_index: req.prf_index,
																						 exception: Access_fault };
					end
					else begin	//Access is valid
						ff_first_stage.enq(tuple2(req, resp_from_tlb.paddr));
					end
				end
				else begin		//Miss in the TLB
					ff_req_to_ptw.enq(req);		//TODO PTW will store the req and send it again, once PTW is done.
					rg_cache_busy<= True;
				end
			end
			else begin	//PTW request
				ff_first_stage.enq(tuple2(req, ?));
			end
		endrule

		rule rl_tag_and_data_array_read_response(ff_first_stage.first.origin != Store_commit);
			let {req,resp_from_tlb}= ff_first_stage.first;
			ff_first_stage.deq;
			Bit#(tagbits) tag;
      Bit#(linewidth) dataline [v_ways];
			Bit#(linewidth) hit_dataline= 0;
      Bit#(tagbits) tag [v_ways];
			Bit#(TLog#(TAdd#(ways,1))) hit='d-1;
			if(req.origin!=PTW)
				tag= resp_from_tlb.paddr[v_paddr - 1:v_paddr - v_tagbits];
			else
				tag= req.addr[v_paddr - 1:v_paddr - v_tagbits];

      for(Integer i = 0;i<v_ways;i = i+1)begin
        dataline[i] <- data_arr[i].read_response();
        tag[i] <- tag_arr[i].read_response();
				if(tag[i]==tag) begin		//If the tag's match, it's a hit in the cache
					hit== fromInteger(i);	//Store the index of the tag match
				end
      end

			if(hit!='d-1) begin	//It's a line hit
				hit_dataline= dataline[truncate(hit)];
				//Get the right offset data and return to core (Even PTW will take it from here)
			end
			else begin					//Line miss
				//check in fill buffer
					//if miss enqueue into next FIFO
			end
			
		endrule

		 
		interface subifc_req_from_core= to_Put(ff_req_from_core);

		interface Get#(Resp_to_core#(TMul#(wordsize,8), prf_index)) subifc_resp_to_core;
			method ActionValue#(Resp_to_core#(TMul#(wordsize,8), prf_index)) get;
				return wr_resp_to_core;
			endmethod
		endinterface

		interface subifc_req_to_ptw= to_Get(ff_req_to_ptw);		

		interface subifc_read_req_to_mem= to_Get(ff_read_req_to_mem);

		interface Put#(Read_resp_from_mem#(data, id_bits))                subifc_read_resp_from_mem;
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

	endmodule
endpackage
