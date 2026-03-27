package LLCache_types;

  typedef struct {
    Bit#(addr)  address;
    Bit#(2)     access ;
    Bit#(data)  data   ;
  } LLCache_ca_request
  #(numeric type addr,
    numeric type data) 
  deriving (Bits, Eq);

endpackage: LLCache_types
