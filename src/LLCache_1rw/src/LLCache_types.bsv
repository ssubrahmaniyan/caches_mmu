package LLCache_types;
  typedef enum {
    Read = 0,
    Write = 1
  } AccessType deriving (Bits, Eq);

  typedef struct {
    Bit#(addr)  address;
    Bit#(2)     access ;
    Bit#(data)  data   ;
  } LLCache_ca_request
  #(numeric type addr,
    numeric type data) 
  deriving (Bits, Eq);

endpackage: LLCache_types
