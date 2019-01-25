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

    // ----------------- Instruction Memory subsystem types ----------------------------------//
`ifdef mmu
                  // addr, Fence, SFence, epoch
  typedef Tuple4#(Bit#(addr), Bool, Bool, Bit#(esize)) IMem_request#(numeric type addr, 
                                                                          numeric type esize);
`else                                                                          
                  // addr, Fence, epoch
  typedef Tuple3#(Bit#(addr), Bool, Bit#(esize)) IMem_request#(numeric type addr, 
                                                                          numeric type esize);
`endif
  typedef Tuple4#(Bit#(data), Bool, Bit#(6), Bit#(esize)) IMem_response#(numeric type data, 
                                                                          numeric type esize);
// --------------------------------------------------------------------------------------------//

// ---------------------- Instruction Cache types ---------------------------------------------//
                  // addr, Fence, epoch
  typedef Tuple3#(Bit#(addr), Bool, Bit#(esize)) ICore_request#(numeric type addr, 
                                                                          numeric type esize);
                 // word , trap, cause , epoch
  typedef Tuple4#(Bit#(data), Bool, Bit#(6), Bit#(esize)) ICore_response#(numeric type data, 
                                                                          numeric type esize);
                // addr ,  burst len, burst_size 
  typedef Tuple3#(Bit#(addr),  Bit#(8), Bit#(3)) ICache_read_request#(numeric type addr);
                    // data,  last , err
  typedef Tuple3#(Bit#(data), Bool, Bool) ICache_read_response#(numeric type data);
// -------------------------------------------------------------------------------------------//


// ---------------------- Data Cache types ---------------------------------------------//
`ifdef atomic
                  // addr, Fence, epoch, access_type, access_size data,  atomic_op
  typedef Tuple7#(Bit#(addr), Bool, Bit#(esize), Bit#(2), Bit#(3), Bit#(data),  Bit#(5)) 
                    DCore_request#(numeric type addr, numeric type data, numeric type esize);
`else
                  // addr, Fence, epoch, access_type, access_size data,  atomic_op
  typedef Tuple6#(Bit#(addr), Bool, Bit#(esize), Bit#(1), Bit#(3), Bit#(data)) 
                    DCore_request#(numeric type addr, numeric type data, numeric type esize);
`endif
                 // word , err , epoch
  typedef Tuple4#(Bit#(data), Bool, Bit#(6), Bit#(esize)) DCore_response#(numeric type data, numeric type esize);
                // addr ,  burst len, burst_size 
  typedef Tuple3#(Bit#(addr),  Bit#(8), Bit#(3)) DCache_read_request#(numeric type addr);
                  // data , last, err
  typedef Tuple3#(Bit#(data), Bool, Bool) DCache_read_response#(numeric type data);
                
                // addr ,  burst len, burst_size, data
  typedef Tuple4#(Bit#(addr),  Bit#(8), Bit#(2), Bit#(linewidth)) DCache_write_request#(
                                    numeric type addr, numeric type linewidth);
  typedef Bool DCache_write_response;
// -------------------------------------------------------------------------------------------//
    // ----------------- Data Memory subsystem types ----------------------------------//
`ifdef mmu
  `ifdef atomic
                  // addr, Fence, sFence, epoch, access_type, access_size data,  atomic_op
    typedef Tuple8#(Bit#(addr), Bool, Bool, Bit#(esize), Bit#(2), Bit#(3), Bit#(data),  Bit#(5)) 
                    DMem_request#(numeric type addr, numeric type data, numeric type esize);
  `else
                  // addr, Fence, sFence epoch, access_type, access_size data,  atomic_op
    typedef Tuple7#(Bit#(addr), Bool, Bool, Bit#(esize), Bit#(1), Bit#(3), Bit#(data)) 
                    DMem_request#(numeric type addr, numeric type data, numeric type esize);
  `endif
`else                                                                          
  `ifdef atomic
                    // addr, Fence, epoch, access_type, access_size data,  atomic_op
    typedef Tuple7#(Bit#(addr), Bool, Bit#(esize), Bit#(2), Bit#(3), Bit#(data),  Bit#(5)) 
                      DMem_request#(numeric type addr, numeric type data, numeric type esize);
  `else
                    // addr, Fence, epoch, access_type, access_size data,  atomic_op
    typedef Tuple6#(Bit#(addr), Bool, Bit#(esize), Bit#(1), Bit#(3), Bit#(data)) 
                      DMem_request#(numeric type addr, numeric type data, numeric type esize);
  `endif
`endif
  typedef Tuple4#(Bit#(data), Bool, Bit#(6), Bit#(esize)) DMem_response#(numeric type data, 
                                                                          numeric type esize);
// --------------------------------------------------------------------------------------------//

// --------------------------- Common Structs ---------------------------------------------------//
  typedef enum {Hit, Miss, None} RespState deriving(Eq,Bits,FShow);
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
  } TLB_permissions deriving(Bits, Eq, FShow);
	
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
