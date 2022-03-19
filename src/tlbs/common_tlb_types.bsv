/* 
see LICENSE.iitm

Author: Neel Gala
Email id: neelgala@gmail.com
Details:

--------------------------------------------------------------------------------------------------
*/
package common_tlb_types;
  `include "Logger.bsv"
  `include "common_tlb.defines"
  import FIFO :: * ;
  import FIFOF :: * ;
  import SpecialFIFOs :: * ;

  function String access2str (Bit#(2) access);
    case(access)
      0: return "Load";
      1: return "Store";
      2: return "Atomic";
      default: return "UNKNOWN ACCESS";
    endcase
  endfunction

  function String cause2str (Bit#(`causesize) cause);
    case (cause)
      `Inst_addr_misaligned  : return "Instruction-Address-Misaligned-Trap";
      `Inst_access_fault     : return "Instruction-Access-Fault-Trap";
      `Load_addr_misaligned  : return "Load-Address-Misaligned-Trap";
      `Load_access_fault     : return "Load-Access-Fault-Trap";
      `Store_addr_misaligned : return "Store-Address-Misaligned-Trap";
      `Store_access_fault    : return "Store-Access-Fault-Trap";  
      `Inst_pagefault        : return "Instruction-Page-Fault-Trap";  
      `Load_pagefault        : return "Load-Page-Fault-Trap";  
      `Store_pagefault       : return "Store-Page-Fault-Trap";  
      default: return "UNKNOWN CAUSE VALUE";
    endcase
  endfunction
// --------------------------------- Instruction TLB types -----------------------------------//
  typedef struct{
    Bit#(addr)        address;
    Bool              sfence;
  `ifdef hypervisor
    Bool              hfence;
  `endif
  }ITLB_core_request# (numeric type addr) deriving(Bits, Eq, FShow);

  typedef struct{
    Bit#(addr)        address;
    Bool              trap;
    Bit#(`causesize)  cause;
  } ITLB_core_response# (numeric type addr) deriving(Bits, Eq);

  instance FShow#(ITLB_core_response#(addr));
    /*doc:func: */
    function Fmt fshow (ITLB_core_response#(addr) value);
      Fmt result = $format("{pa:%h",value.address);
      if (value.trap)
        result = result + $format(", caused ", cause2str(value.cause)) ;
      return result + $format("}");
    endfunction
  endinstance
// --------------------------------------------------------------------------------------------//
// --------------------------------- Data TLB types ---------------------------------------------//
  typedef struct{
    Bit#(addr)        address;
    Bit#(2)           access;
    Bit#(`causesize)  cause;
    Bool              ptwalk_trap;
    Bool              ptwalk_req;
    Bool              sfence;
    Bit#(2)           prv;
  `ifdef hypervisor
    Bool              hfence;
    Bit#(1)           virt;
    Bit#(1)           hlvx;
  `endif
  }DTLB_core_request# (numeric type addr) deriving(Bits, Eq, FShow);

  typedef struct{
    Bit#(addr)        address;
    Bool              trap;
    Bit#(`causesize)  cause;
    Bool              tlbmiss;
  } DTLB_core_response# (numeric type addr) deriving(Bits, Eq);

  instance FShow#(DTLB_core_response#(addr));
    /*doc:func: */
    function Fmt fshow (DTLB_core_response#(addr) value);
      Fmt result = $format("{pa:%h",value.address);
      if (value.trap)
        result = result + $format(", caused ", cause2str(value.cause)) ;
      if (value.tlbmiss)
        result = result + $format(", is a TLBMISS");
      return result + $format("}");
    endfunction
  endinstance
// --------------------------------------------------------------------------------------------- //

// --------------------------------- PTwalk types -----------------------------------//
  typedef struct{
    Bit#(addr)        address;
    Bit#(2)           access;
    Bit#(2)           prv;
  `ifdef hypervisor
    Bit#(1)           virt;
    Bit#(1)           hlvx;
  `endif
  }PTWalk_tlb_request#(numeric type addr) deriving(Bits, Eq, FShow);

  typedef struct{
  `ifdef hypervisor
    Bit#(1)               virt;
  `endif
    Bit#(addr)            pte;
    Bit#(addr)            s1_pte;
    Bit#(TLog#(level))    levels;
    Bool                  trap;
    Bit#(`causesize)      cause;
  }PTWalk_tlb_response#(numeric type addr, numeric type level) deriving(Bits, Eq, FShow);
  
  typedef struct{
    Bit#(addr)            address;
    Bit#(3)               size;
    Bit#(2)               access;
    Bool                  ptwalk_trap;
    Bool                  ptwalk_req;
    Bit#(`causesize)      cause;
  }PTwalk_mem_request# (numeric type addr) deriving(Bits, Eq, FShow);
// -------------------------- TLB Structs ----------------------------------------------------//
  typedef struct {
  	Bool v;					//valid
  	Bool r;					//allow reads
  	Bool w;					//allow writes
  	Bool x;					//allow execute(instruction read)
  	Bool u;					//allow supervisor
  	Bool g;					//global page
  	Bool a;					//accessed already
  	Bool d;					//dirty
  } TLB_permissions deriving(Eq, FShow);

  instance Bits#(TLB_permissions,8);
    /*doc:func: */
    function Bit#(8) pack (TLB_permissions p);
      return {pack(p.d), pack(p.a), pack(p.g), pack(p.u), 
              pack(p.x), pack(p.w), pack(p.r), pack(p.v)};
    endfunction
    /*doc:func: */
    function TLB_permissions unpack (Bit#(8) perms);
		  return TLB_permissions { v : unpack(perms[0]),
			  											 r : unpack(perms[1]),
				  										 w : unpack(perms[2]),
					  									 x : unpack(perms[3]),
						  								 u : unpack(perms[4]),
							  							 g : unpack(perms[5]),
								  						 a : unpack(perms[6]),
									  					 d : unpack(perms[7])};
     endfunction
  endinstance

  function TLB_permissions bits_to_permission(Bit#(8) perms);
		return TLB_permissions { v : unpack(perms[0]),
														 r : unpack(perms[1]),
														 w : unpack(perms[2]),
														 x : unpack(perms[3]),
														 u : unpack(perms[4]),
														 g : unpack(perms[5]),
														 a : unpack(perms[6]),
														 d : unpack(perms[7])};
	endfunction
// -------------------------------------------------------------------------------------------//
endpackage

