package LLCache_types;
  typedef enum {
    Read = 0,
    Write = 1
  } AccessType deriving (Bits, Eq);

  // TODO: Add identifier for requesting core
  typedef struct {
    Bit#(addr_width)  address;
    AccessType        access ;
    Bit#(data_width)  data   ;
  } LLCache_ca_request
  #(numeric type addr_width,
    numeric type data_width) 
  deriving (Bits, Eq);

  // TODO: Add identifier for core to respond to
  typedef struct{
    Bit#(data_width) data   ;
  } LLCache_ca_llc_response
  #(numeric type data_width)
  deriving (Bits, Eq);
  
  typedef struct{
    Bit#(nways)  waymask;
  } TagResponse
  #(numeric type nways)
  deriving (Bits, Eq);

  typedef struct{
    Bit#(TMul#(lsize, 8)) data;
  } DataResponse
  #(numeric type lsize)
  deriving (Bits, Eq);
  
endpackage: LLCache_types
