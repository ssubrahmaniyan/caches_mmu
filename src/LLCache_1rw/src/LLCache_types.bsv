package LLCache_types;
  typedef enum {
    Read = 0,
    Write = 1
  } AccessType_t deriving (Bits, Eq);

  // TODO: Add identifier for requesting core
  typedef struct {
    Bit#(addr_width)  address;
    AccessType_t      access ;
    Bit#(data_width)  data   ;
  } CA_LLCache_request_t
  #(numeric type addr_width,
    numeric type data_width) 
  deriving (Bits, Eq);

  // TODO: Add identifier for core to respond to
  typedef struct{
    Bit#(data_width) data   ;
  } LLCache_CA_response_t
  #(numeric type data_width)
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
    Bit#(TLog#(ncores)) coreid  ;
    Bool                valid   ;
  } LLCache_mhb_entry
  #(numeric type paddr,
    numeric type datawidth,
    numeric type ncores)
  deriving (Bits, Eq);
  
endpackage: LLCache_types
