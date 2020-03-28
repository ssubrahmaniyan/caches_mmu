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
package icache_types;

// ---------------------- Data Cache types ---------------------------------------------//
  typedef struct{
    Bit#(addr)    address;
    Bool          fence;
    Bit#(esize)   epochs;
  } ICache_core_request#( numeric type addr,
                      numeric type esize) deriving (Bits, Eq, FShow);
  typedef struct{
    Bit#(addr)    address;
    Bit#(8)       burst_len;
    Bit#(3)       burst_size;
    Bool          io;
  } ICache_mem_readreq#( numeric type addr) deriving(Bits, Eq, FShow);

  typedef struct{
    Bit#(data)    data;
    Bool          last;
    Bool          err;
  } ICache_mem_readresp#(numeric type data) deriving(Bits, Eq, FShow);

  typedef struct{
    Bit#(addr)    address;
    Bool          fence;
    Bit#(esize)   epochs;
  `ifdef supervisor
    Bool          sfence;
  `endif
  } IMem_core_request#( numeric type addr, numeric type esize) deriving (Bits, Eq, FShow);

  typedef struct{
    Bit#(data)        word;
    Bool              trap;
    Bit#(`causesize)  cause;
    Bit#(esize)       epochs;
  } IMem_core_response#( numeric type data, numeric type esize) deriving (Bits, Eq, FShow);
// --------------------------------------------------------------------------------------------- //

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
endpackage
