package LLCache;
  //Library imports
  import GetPut::*;

  // Project Imports
  import LLCache_types::*;

  interface Ifc_LLCache;
    interface Put#(
      LLCache_ca_request
      #(`vaddr, TMul#(`dblocks, TMul#(`dwords, 8))))
      receive_ca_req;
  endinterface: Ifc_LLCache

  (*synthesize*)
  module mkLLCache(Ifc_LLCache);
  endmodule: mkLLCache

endpackage
