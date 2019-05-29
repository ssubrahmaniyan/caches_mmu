package nb_dcache;
	interface Ifc_nbdcache#(numeric type wordsize, 
													numeric type blocksize,  
													numeric type sets,
													numeric type ways,
													numeric type paddr,
													numeric type vaddr,
													numeric type prf_index);
		interface Put#(Req_from_core#(vaddr, TMul#(wordsize,8), prf_index) subifc_req_from_core;
		interface Get#(Resp_to_core#(TMul#(wordsize,8), prf_index))        subifc_resp_to_core;
		interface Get#(Bit#(vaddr))                                        subifc_req_to_ptw_from_tlb;
		interface Get#(Read_req_to_mem#(vaddr, id_width))                  subifc_read_req_to_mem;
		interface Put#(Read_resp_from_mem#(data, id_width))                subifc_read_resp_from_mem;
		interface Get#(Write_req_to_mem#(vaddr, data))                     subifc_write_req_to_mem;
		interface Put#(Bool)                                               subifc_write_resp_from_mem;
		
	endinterface

	module mk_dcache(Ifc_nbdcache#(wordsize, blocksize, sets, ways, paddr, vaddr, prf_index));
		
	endmodule
endpackage
