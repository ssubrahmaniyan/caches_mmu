/*
Author: Sanjeev Subrahmaniyan
E-mail: subrahmaniyansanjeev@gmail.com
*/

package LLCache_dataram;
 
  // BSV Lib Imports
  import Vector           :: *;

  // Project Lib Imports
  import LLCache_types    :: *;
  import LLCache_lib      :: *;
  import mem_config       :: *;

  interface Ifc_dataram1rw
    #(numeric type lsize,   // size of a line
      numeric type nsets,
      numeric type nways,
      numeric type naddr    // number of bits to address the RAM 
    );

    /*
      doc: method: ma_data_request
      desc: When a request is enqueued into the LLC FIFO,
            it is also simultaneously inserted into the data ram.
    */
    // TODO: Make input composite Maybe
    method Action ma_data_request(
      AccessType access,
      Bit#(TLog#(nways)) wayid,
      Bit#(naddr) addr,
      Bit#(lsize) data
    );

    /*
      doc: method: mv_data_response
      desc: In the second cycle, the response method must be invoked
            with the waymask to read the data line.
            Returns a Maybe# to accomodate write responses also.
    */
    method DataResponse#(lsize) mv_data_response(
      TagResponse#(nways) waymask
    );

  endinterface: LLCache_dataram

  module mkLLCache_dataram
    (Ifc_dataram1rw#(
      lsize,
      nsets,
      nways, 
      naddr
    ))
    provisos(
     Log#(nsets, set_bits),
    );

    /*
    Local Vars
    */
    let v_sets = valueOf(nsets);
    let v_ways = valueOf(nways);
    let v_set_bits = valueOf(set_bits);
    
  endmodule: mkLLCAche_dataram
endpackage: LLCache_dataram