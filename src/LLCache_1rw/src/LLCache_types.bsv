package LLCache_types;
  typedef enum {
    Read = 0,
    Write = 1
  } AccessType deriving (Bits, Eq);

  typedef struct {
    Bit#(addr_width)  address;
    AccessType        access ;
    Bit#(data_width)  data   ;
  } LLCache_ca_request
  #(numeric type addr_width,
    numeric type data_width) 
  deriving (Bits, Eq);

  typedef struct{
    Bit#(ways)  waymask;
  } TagResponse
  #(numeric type ways)
  deriving (Bits, Eq);

  typedef struct{
    Bit#(TMul#(lsize, 8)) data;
  } DataResponse
  #(numeric type lsize)
  deriving (Bits, Eq);
  
endpackage: LLCache_types
