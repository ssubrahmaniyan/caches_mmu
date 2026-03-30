/*
Author: Abhinav I S
Email ID : abhinavis2005@gmail.com
*/

package LLCache_tagram;
  // Library Imports
  import Vector         :: *;
  // Project Imports
  import LLCache_types  :: *;
  import LLCache_lib    :: *;
  
  interface Ifc_tagram1rw
    #(numeric type wordsize ,
      numeric type blocksize,
      numeric type ways     ,
      numeric type sets     ,
      numeric type paddr    
  );

    /* 
      doc: method: ma_request
      description: This method is used to send
      the request to the tag array for read and write operation. 
      A read is latched on all ways, Write is latched only on one way.
    */
    method Action ma_request(
      AccessType access,
      Bit#(TLog#(sets)) index,
      Bit#(paddr) address,
      Bit#(TLog#(ways)) way);

  endinterface: Ifc_tagram1rw

  module mkLLCache_tagram
    (Ifc_tagram1rw#(
      wordsize, 
      blocksize, 
      ways,
      sets,
      paddr));

    let v_ways = valueOf(ways);
    let v_sets = valueOf(sets);


  endmodule: mkLLCache_tagram

endpackage: LLCache_tagram
