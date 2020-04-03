/* 
see LICENSE.incore
see LICENSE.iitm

Author: Neel Gala
Email id: neelgala@gmail.com
Details:

--------------------------------------------------------------------------------------------------
*/
package common_tlb_types;
  `include "Logger.bsv"
  import FIFO :: * ;
  import FIFOF :: * ;
  import SpecialFIFOs :: * ;
// --------------------------------- Instruction TLB types -----------------------------------//
  typedef struct{
    Bit#(addr)        address;
    Bool              sfence;
  }ITLB_core_request# (numeric type addr) deriving(Bits, Eq, FShow);

  typedef struct{
    Bit#(addr)        address;
    Bool              trap;
    Bit#(`causesize)  cause;
  } ITLB_core_response# (numeric type addr) deriving(Bits, Eq, FShow);
// --------------------------------------------------------------------------------------------//
// --------------------------------- Data TLB types ---------------------------------------------//
  typedef struct{
    Bit#(addr)        address;
    Bit#(2)           access;
    Bit#(`causesize)  cause;
    Bool              ptwalk_trap;
    Bool              ptwalk_req;
    Bool              sfence;
  }DTLB_core_request# (numeric type addr) deriving(Bits, Eq, FShow);

  typedef struct{
    Bit#(addr)        address;
    Bool              trap;
    Bit#(`causesize)  cause;
    Bool              tlbmiss;
  } DTLB_core_response# (numeric type addr) deriving(Bits, Eq, FShow);
// --------------------------------------------------------------------------------------------- //

// --------------------------------- PTwalk types -----------------------------------//
  typedef struct{
    Bit#(addr)        address;
    Bit#(2)           access;
  }PTWalk_tlb_request#(numeric type addr) deriving(Bits, Eq, FShow);

  typedef struct{
    Bit#(addr)            pte;
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

