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
`ifdef coherency
  import coherence_types :: * ;
`endif

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
    Bool          io;
  `ifdef coherency
    Cacheline_state  curr_state;
  `endif
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
    Bool            io;
  `ifdef coherency
    Cacheline_state  curr_state;
  `endif
  } DCache_mem_writereq#(numeric type addr, numeric type data) deriving(Bits, Eq, FShow);

  typedef Bool DCache_mem_writeresp;

  typedef struct{
    Bit#(a) addr;
    Bit#(d) data;
    Bit#(2) size;
    Bool read_write;
  } NCAccess#(numeric type a, numeric type d) deriving (Bits, Eq, FShow);
// --------------------------------------------------------------------------------------------- //

endpackage
