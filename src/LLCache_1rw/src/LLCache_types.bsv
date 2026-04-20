package LLCache_types;
  typedef enum {
    Read = 0,
    Write = 1
  } AccessType_t deriving (Bits, Eq);

  typedef struct {
    Bit#(addr_width)    address;
    AccessType_t        access;
    Bit#(data_width)    data;
    Bit#(TLog#(ncores)) hart_id;
  } CA_LLCache_request_t
  #(numeric type addr_width,
    numeric type data_width,
    numeric type ncores) 
  deriving (Bits, Eq);

  typedef struct {
    Bit#(addr_width)    address;
    Bit#(data_width)    data;
    Bit#(TLog#(ncores)) hart_id;
  } CA_LLCache_response_t 
  #(numeric type addr_width,
    numeric type data_width,
    numeric type ncores)
  deriving (Bits, Eq);

  typedef struct{
    Bit#(data_width)    data;
    Bit#(addr_width)    address;
    Bit#(TLog#(ncores)) hart_id;
  } LLCache_CA_response_t
  #(numeric type data_width,
    numeric type addr_width,
    numeric type ncores)
  deriving (Bits, Eq);

  typedef struct{
    Bit#(addr_width)  address;
    AccessType_t      access;    
    Bit#(data_width)  data;
  } LLCache_CA_request_t
  #(numeric type addr_width,
    numeric type data_width)
  deriving (Bits, Eq);

  typedef struct{
    Bit#(nways)  waymask;
  } TagResponse_t
  #(numeric type nways)
  deriving (Bits, Eq);

  typedef struct{
    Bit#(TMul#(lsize, 8)) data;
  } DataResponse_t
  #(numeric type lsize)
  deriving (Bits, Eq);

  typedef struct{
    Bit#(paddr)         address ;
    Bit#(datawidth)     data    ;
    Bit#(ncores)        hart_id ;
    Bool                valid   ;
    Bool                filled  ;
  } LLCache_mhb_entry
  #(numeric type paddr,
    numeric type datawidth,
    numeric type ncores)
  deriving (Bits, Eq);

  typedef enum{
    AlreadyPending,
    NewlyAllocated
  } MHB_Lookup_Result_t
    deriving (Bits, Eq);
  
endpackage: LLCache_types
