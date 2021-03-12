/* 
see LICENSE.iitm

Author: Arjun Menon, Nitya Ranganathan
Email id: c.arjunmenon@gmail.com, nitya.ranganathan@gmail.com
Details:

--------------------------------------------------------------------------------------------------
*/
package nb_dcache_types;
	import DefaultValue :: *;

        typedef enum {IntegerRF, FPRF} DestType deriving(Bits, Eq, FShow); // destination register type

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
		Bit#(3) access_size;
		Bit#(data) data;
		Origin origin;
		Bool ptwalk_trap;
		Bool sfence;
                Bit#(lsq_index) lsq_id;
		Bit#(rob_index) rob;
		Bit#(prf_index) prf_index;
		DestType dest_type;
    `ifdef atomic
    Bool is_atomic;
    Bit#(5) atomic_fn;
    `endif
	} Req_from_core#(numeric type addr, numeric type data, numeric type rob_index, numeric type prf_index, numeric type lsq_index) deriving (Bits, Eq, FShow);
	instance DefaultValue#(Req_from_core#(addr, data, rob_index, prf_index, lsq_index));
		defaultValue= Req_from_core {	addr: 'd0,
															access_size: 'd3,
															data: 'd0,
															origin: defaultValue,
															ptwalk_trap: False,
															sfence: False,
                                                                                                                        lsq_id: 'd0,
															rob: 'd0,
															prf_index: 'd0,
															dest_type: IntegerRF
                              `ifdef atomic
                              , is_atomic: False
                              , atomic_fn: 'd0
                              `endif
                            }; 
	endinstance
	
	typedef struct {
		Bit#(addr) addr;
		Bit#(3) access_size;
		Bit#(data) payload;
		Origin origin;
		Bit#(prf_index) prf_index;
		DestType dest_type;
		Bit#(rob_index) rob;
    `ifdef atomic
    Bool is_atomic;
    Bit#(5) atomic_fn;
    `endif
	} Cache_req#(numeric type addr, numeric type data, numeric type rob_index, numeric type prf_index) deriving (Bits, Eq, FShow);
	
	typedef enum {No_exception, Load_access_fault, Store_access_fault `ifdef supervisor , Load_page_fault, Store_page_fault `endif } DCache_exception deriving (Bits, Eq, FShow);	//TODO check if No_exception can be removed
	instance DefaultValue#(DCache_exception);
		defaultValue= No_exception;
	endinstance
	
	typedef struct {
		Bit#(data) data;
		Bit#(prf_index) prf_index;
		Bit#(rob_index) rob;
		DCache_exception exception;
`ifdef atomic
  `ifdef simulate `ifdef new_spike
		Bit#(data) atomic_result;
  `endif `endif
`endif
	} Resp_to_core#(numeric type data, numeric type prf_index, numeric type rob_index) deriving (Bits, Eq, FShow);
	instance DefaultValue#(Resp_to_core#(data, prf_index, rob_index));
		defaultValue= Resp_to_core {data: 0,
																prf_index: 0,
																rob: 0,
																exception: defaultValue
															`ifdef atomic
																`ifdef simulate `ifdef new_spike
																, atomic_result: 0
																`endif `endif
															`endif
																 };
	endinstance
	
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
		Bit#(3) access_size;
		Bit#(data) payload;
		Origin origin;
		Bit#(prf_index) prf_index;
		DestType dest_type;
    Bit#(rob_index) rob;
    `ifdef atomic
      Bool is_atomic;
      Bit#(5) atomic_fn;
    `endif
	} MSHR_Req#(numeric type addr, numeric type data, numeric type prf_index, numeric type rob_index) deriving (Bits, Eq, FShow);
	instance DefaultValue#(MSHR_Req#(addr, data, prf_index, rob_index));
		defaultValue= MSHR_Req {	addr: 'd0,
															access_size: 'd3,
															payload: 'd0,
															origin: defaultValue,
                              prf_index: 'd0,
                              dest_type: IntegerRF,
                              rob: 'd0
                              `ifdef atomic
                              , is_atomic: False
                              , atomic_fn: 'd0
                              `endif
                          };
	endinstance

  typedef enum {Allocated, Not_allocated, Busy `ifdef prefetch_throttle , Dropped `endif } MSHR_status_resp deriving(Bits, Eq, FShow);
	instance DefaultValue#(MSHR_status_resp);
		defaultValue= Not_allocated;
	endinstance

	typedef struct {
		Bit#(addr) addr;
		Bit#(3) access_size;
		DestType dest_type;
		Bit#(data) payload;
		Origin origin;
    `ifdef atomic
    Bool is_atomic;
    `endif
	} MSHR_FIFO#(numeric type addr, numeric type data) deriving (Bits, Eq, FShow);
	instance DefaultValue#(MSHR_FIFO#(addr, data));
		defaultValue= MSHR_FIFO {	addr: 'd0,
															access_size: 'd3,
															dest_type: IntegerRF,
															payload: 'd0,
															origin: defaultValue
                              `ifdef atomic
                              , is_atomic: False
                              `endif
                          };
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

//  typedef struct{
//    Bit#(addr)            pte;
//    Bit#(TLog#(level))    levels;
//    Bool                  trap;
//  }PTWalk_tlb_response#(numeric type addr, numeric type level) deriving(Bits, Eq, FShow);

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

//--------------------------------------------------------------------------------------------------

`ifdef atomic
  typedef struct{
    Bool valid;
    Bit#(addr) reserved_addr;
    Bit#(rob_size) rob_id;
  } Reserve_info#(numeric type addr, numeric type rob_size) deriving(Bits, Eq, FShow);

  instance DefaultValue#(Reserve_info#(addr, rob_size));
    defaultValue= Reserve_info { valid: False,
                                 reserved_addr: ?,
                                 rob_id: ? };
  endinstance
`endif

	typedef struct {
		Bit#(addr) addr;
		Bit#(3) size;
    Bool is_store;
    Bit#(data) data;
	} IO_Req#(numeric type addr, numeric type data) deriving (Bits, Eq, FShow);

  typedef struct {
    Bit#(data) data;
    DCache_exception exception;
  } IO_Resp#(numeric type data) deriving (Bits, Eq, FShow);

  `ifdef atomic
  function Bit#(datawidth) fn_atomic_op (Bit#(5) op, Bit#(datawidth) rs2, Bit#(datawidth) loaded)
  provisos(Add#(a__, 32, datawidth));
    Bit#(datawidth) op1 = loaded;
    Bit#(datawidth) op2 = rs2;
    `ifdef RV64
    if(op[4] == 0)begin
      op1 = signExtend(loaded[31 : 0]);
      op2 = signExtend(rs2[31 : 0]);
    end
    `endif
    Int#(datawidth) s_op1 = unpack(op1);
    Int#(datawidth) s_op2 = unpack(op2);
    
    case (op[3 : 0])
        'b0101 : return op1;
        'b0000 : return (op1 + op2);
        'b0010 : return (op1^op2);
        'b0110 : return (op1 & op2);
        'b0100 : return (op1|op2);
        'b1100 : return min(op1, op2);
        'b1110 : return max(op1, op2);
        'b1000 : return pack(min(s_op1, s_op2));
        'b1010 : return pack(max(s_op1, s_op2));
        default : return op2;
      endcase
  endfunction
  `endif

endpackage
