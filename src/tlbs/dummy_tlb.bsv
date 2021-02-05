package dummy_tlb;
	import nb_dcache_types::*;          // for local cache types
	interface Ifc_tlb#(numeric type vaddr, numeric type paddr);
		method ActionValue#(Resp_from_tlb#(paddr)) translate(Bit#(vaddr) req_va, Bool is_store);
	endinterface

	module mktlb(Ifc_tlb#(vaddr, paddr))
	provisos(Add#(a__, paddr, vaddr));
		Wire#(Bit#(paddr)) wr_paddr <- mkWire;
		method ActionValue#(Resp_from_tlb#(paddr)) translate(Bit#(vaddr) req_va, Bool is_store);
			return Resp_from_tlb{	is_hit: True,
														is_fault: False,
														paddr: truncate(req_va),
														is_io: False };
		endmethod
	endmodule
endpackage
