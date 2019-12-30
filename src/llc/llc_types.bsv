package llc_types;

`include "llc.defines"

typedef struct {
	Bit#(addr) addr;
	Bit#(data_width) data;
	Bool dirty;
	} Line_metadata#(numeric type addr, numeric type data_width) deriving (Bits, Eq);

typedef union tagged {
	Bit#(TLog#(sets)) Set;
	void Fence; 
	} Fence_type#(numeric type sets) deriving (Bits, Eq);

endpackage
