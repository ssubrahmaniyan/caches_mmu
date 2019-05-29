typedef struct {
	Bit#(addr) addr,
	Request_type#(data, prf_index) req_type,
} Req_from_core#(numeric type addr, numeric type data, numeric type prf_index) deriving (Bits, Eq, FShow);

typedef enum {No_Exception, Bus_Error, Access_Fault} DCache_exception_type;

typedef struct {
	Bit#(data) data,
	Bit#(prf_index) prf_index,
	DCache_exception_type exception
} Resp_to_core#(numeric type data, numeric type prf_index) deriving (Bits, Eq, FShow);

typedef struct {
	Bit#(addr) addr,
	Bit#(id_width) id,
	Bool is_burst
} Read_req_to_mem#(numeric type addr, numeric type data) deriving (Bits, Eq, FShow);

typedef struct {
	Bit#(addr) addr,
	Bit#(data) data,
} Read_resp_from_mem#(numeric type addr, numeric type data) deriving (Bits, Eq, FShow);

typedef struct {
	Bit#(addr) addr,
	Bit#(data) data,
} Write_req_to_mem#(numeric type addr, numeric type data) deriving (Bits, Eq, FShow);
