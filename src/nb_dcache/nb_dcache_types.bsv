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
	import DefaultValue :: *;

	typedef enum {Load_buffer, Store_buffer, PTW, Store_commit} Origin deriving (Bits, Eq, FShow);
	instance DefaultValue#(Origin);
		defaultValue= Store_buffer;
	endinstance

	typedef enum { Read_SRAMs, Write_SRAMs, Release_FB	} FB_state deriving (Bits, Eq, FShow);
	instance DefaultValue#(FB_state);
		defaultValue= Read_SRAMs;
	endinstance


	typedef struct {
		Bit#(addr) addr;
		Bit#(2) access_size;
		Bit#(data) data;
		Origin origin;
		Bool ptwalk_trap;
		Bool fence;
		Bit#(rob_index) rob;
		Bit#(prf_index) prf_index;
	} Req_from_core#(numeric type addr, numeric type data, numeric type rob_index, numeric type prf_index) deriving (Bits, Eq, FShow);
	instance DefaultValue#(Req_from_core#(addr, data, rob_index, prf_index));
		defaultValue= Req_from_core {	addr: 'd0,
															access_size: 'd3,
															data: 'd0,
															origin: defaultValue,
															rob: 'd0,
															prf_index: 'd0}; 
	endinstance
	
	typedef struct {
		Bit#(addr) addr;
		Bit#(2) access_size;
		Bit#(data) payload;
		Origin origin;
		Bit#(rob_index) rob;
	} Cache_req#(numeric type addr, numeric type data, numeric type rob_index) deriving (Bits, Eq, FShow);
	//instance DefaultValue#(Cache_req#(addr, data, rob_index));
	//	defaultValue= Cache_req {	addr: 'd0,
	//														access_size: 'd3,
	//														payload: 'd0,
	//														origin: defaultValue,
	//														rob: 'd0}; 
	//endinstance
	
	typedef enum {No_exception, Load_access_fault} DCache_exception deriving (Bits, Eq, FShow);
	
	typedef struct {
		Bit#(data) data;
		Bit#(prf_index) prf_index;
		DCache_exception exception;
	} Resp_to_core#(numeric type data, numeric type prf_index) deriving (Bits, Eq, FShow);
	
	typedef struct {
		Bit#(addr) addr;
		Bit#(id_bits) id;
		Bool is_burst;
	} Read_req_to_mem#(numeric type addr, numeric type id_bits) deriving (Bits, Eq, FShow);
	
	typedef struct {
		Bit#(data) data;
		Bit#(id_bits) id;
		Bool last;
	} Read_resp_from_mem#(numeric type data, numeric type id_bits) deriving (Bits, Eq, FShow);
	instance DefaultValue#(Read_resp_from_mem#(addr, data));
		defaultValue= Read_resp_from_mem { data: 'd0,
																			 id: '1,
																		 	 last: False};
	endinstance
	
	typedef struct {
		Bit#(addr) addr;
		Bit#(data) data;
		Bool is_burst;
	} Write_req_to_mem#(numeric type addr, numeric type data) deriving (Bits, Eq, FShow);

	//typedef struct {
	//	Bool is_hit;
	//	Bool is_fault;
	//	Bit#(addr) paddr;
	//	Bool is_io;
	//} Resp_from_tlb#(numeric type addr) deriving (Bits, Eq, FShow);

	typedef struct {
		Bool valid;
		Bit#(rob_index) head;
		Bit#(rob_index) flush_rob;
	} Flush_type#(numeric type rob_index) deriving (Bits, Eq, FShow);
	instance DefaultValue#(Flush_type#(rob_index));
		defaultValue= Flush_type {	valid: False,
																head: ?,
																flush_rob: ?};
	endinstance

	typedef struct {
		Bit#(addr) addr;
		Bit#(2) access_size;
		Bit#(data) payload;
		Origin origin;
	} MSHR_Req#(numeric type addr, numeric type data) deriving (Bits, Eq, FShow);
	instance DefaultValue#(MSHR_Req#(addr, data));
		defaultValue= MSHR_Req {	addr: 'd0,
															access_size: 'd3,
															payload: 'd0,
															origin: defaultValue }; 
	endinstance

	// -------------- TLB defines ------------------ //
  typedef struct{
    Bit#(addr)        address;
    Bit#(2)           access; //00: Load, 01: Store, 10: Atomic, 11: Instruction
    Bool              ptwalk_trap;
    Bool              ptwalk_req;
    Bool              sfence;
  } Cache_DTLB_request# (numeric type addr) deriving(Bits, Eq, FShow);

  typedef struct{
    Bit#(addr)        address;
    Bool              trap;
    DCache_exception  exception;
    Bool              tlbmiss;
  } DTLB_Cache_response# (numeric type addr) deriving(Bits, Eq, FShow);

  typedef struct{
    Bit#(addr)        address;
    Bit#(2)           access;
  }PTWalk_tlb_request#(numeric type addr) deriving(Bits, Eq, FShow);

  typedef struct{
    Bit#(addr)            pte;
    Bit#(TLog#(level))    levels;
    Bool                  trap;
  }PTWalk_tlb_response#(numeric type addr, numeric type level) deriving(Bits, Eq, FShow);

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

endpackage
