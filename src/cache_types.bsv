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

Author: Neel Gala
Email id: neelgala@gmail.com
Details:

--------------------------------------------------------------------------------------------------
*/
package cache_types;

  `ifdef itim
  typedef struct{
    Bit#(addr) address;
    Bit#(3) size;
    Bit#(2) access;
    Bit#(data) data;
  } ITIM_mem_req#(numeric type addr, numeric type data) deriving(Bits, Eq, FShow);

  typedef struct{
    Bit#(data) data;
    Bool err;
  } ITIM_mem_resp#(numeric type data) deriving(Bits, Eq, FShow);
  `endif

  // ---------------------- Instruction Cache types ---------------------------------------------//
  typedef struct{
    Bit#(addr)  address;
    Bit#(8)     burst_len;
    Bit#(3)     burst_size;
  } ICache_mem_request#( numeric type addr) deriving (Bits, Eq, FShow);

  typedef struct{
    Bit#(data)  data;
    Bool        last;
    Bool        err;
  } ICache_mem_response#( numeric type data) deriving (Bits, Eq, FShow);
// -------------------------------------------------------------------------------------------//

// ---------------------- Data Cache types ---------------------------------------------//
  typedef struct{
    Bit#(addr)    address;
    Bool          fence;
    Bit#(esize)   epochs;
    Bit#(2)       access;
    Bit#(3)       size;
    Bit#(data)    data;
  `ifdef atomic
    Bit#(5)       atomic_op;
  `endif
  `ifdef supervisor
    Bool          ptwalk_req;
  `endif
  } DCache_core_request#( numeric type addr,
                      numeric type data,
                      numeric type esize) deriving (Bits, Eq, FShow);
  typedef struct{
    Bit#(addr)    address;
    Bit#(8)       burst_len;
    Bit#(3)       burst_size;
  } DCache_mem_readreq#( numeric type addr) deriving(Bits, Eq, FShow);

  typedef struct{
    Bit#(data)    data;
    Bool          last;
    Bool          err;
  } DCache_mem_readresp#(numeric type data) deriving(Bits, Eq, FShow);

  typedef struct{
    Bit#(addr)      address;
    Bit#(data)      data;
    Bit#(8)         burst_len;
    Bit#(3)         burst_size;
  } DCache_mem_writereq#(numeric type addr, numeric type data) deriving(Bits, Eq, FShow);

  typedef Bool DCache_mem_writeresp;
// --------------------------------------------------------------------------------------------- //

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
// --------------------------------------------------------------------------------------------- //
// --------------------------------- Data TLB types ---------------------------------------------//
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

// --------------------------- Common Structs ---------------------------------------------------//
  typedef enum {Hit=1, Miss=0, None=2} RespState deriving(Eq,Bits,FShow);

  function String countName (Integer cntr);
    case (cntr)
      'd0: return "Total accesses";
      'd1: return "Total Hits in Cache";
      'd2: return "Total Hits in LB";
      'd3: return "Total IO requests";
      'd4: return "Misses which cause evictions";
      default: return "Null";
    endcase
  endfunction
// -------------------------------------------------------------------------------------------//
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
