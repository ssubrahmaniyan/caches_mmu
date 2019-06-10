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
package nb_dcache_types;

	typedef enum {Load_buffer, Store_buffer, PTW, Store_commit} Origin deriving (Bits, Eq, FShow);
	instance DefaultValue#(Origin);
		defaultValue= Store_buffer;
	endinstance

	typedef struct {
		Bit#(addr) addr,
		Bit#(2) access_size,
		Bit#(data) payload,
		Origin origin
	} Req_from_core#(numeric type addr, numeric type data) deriving (Bits, Eq, FShow);
	instance DefaultValue#(Req_from_core#(addr, data));
		defaultValue= Req_from_core {	addr: 'd0,
																	access_size: 'd3,
																	payload: 'd0,
																	origin: defaultValue }; 
	endinstance
	
	typedef enum {No_exception, Bus_error, Access_fault} DCache_exception deriving (Bits, Eq, FShow);
	
	typedef struct {
		Bit#(data) data,
		Bit#(prf_index) prf_index,
		DCache_exception exception
	} Resp_to_core#(numeric type data, numeric type prf_index) deriving (Bits, Eq, FShow);
	
	typedef struct {
		Bit#(addr) addr,
		Bit#(id_bits) id,
		Bool is_burst
	} Read_req_to_mem#(numeric type addr, numeric type data, numeric type id_bits) deriving (Bits, Eq, FShow);
	
	typedef struct {
		Bit#(data) data,
		Bit#(id_bits) id
	} Read_resp_from_mem#(numeric type data, numeric type id_bits) deriving (Bits, Eq, FShow);
	instance DefaultValue#(Req_from_core#(addr, data));
		defaultValue= Req_from_core {	data: 'd0,
																	id: '1 };
	endinstance
	
	typedef struct {
		Bit#(addr) addr,
		Bit#(data) data,
	} Write_req_to_mem#(numeric type addr, numeric type data) deriving (Bits, Eq, FShow);

endpackage
