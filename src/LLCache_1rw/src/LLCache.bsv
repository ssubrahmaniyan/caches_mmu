package LLCache;
  //Library imports
  import GetPut::*;

  // Project Imports
  import LLCache_types  ::*;
  import LLCache_tagram ::*;

  interface Ifc_LLCache;
    interface Put#(
      LLCache_ca_request
      #(`vaddr, TMul#(`dblocks, TMul#(`dwords, 8))))
      receive_ca_req;
  endinterface: Ifc_LLCache

  (*synthesize*)
  module mkLLCache(Ifc_LLCache);
    rule hello_world;
      $display("Hellow World");
      $finish;
    endrule: hello_world
  endmodule: mkLLCache

endpackage
