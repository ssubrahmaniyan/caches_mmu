/*
Author: Sanjeev Subrahmaniyan
E-mail: subrahmaniyansanjeev@gmail.com
*/

// RAM organized in a manner identical to the tags
// Effectively serves as a wrapper around the physical memory module
// Can provide the data in a specific set provided the waymask
package LLCache_dataram;
  interface Ifc_dataram1rw
    #(numeric type nsets,
      numeric type nways,
      numeric type naddr    // number of bits to address the RAM 
    );

    method Action ma_data_request(
      ReqType typ, 
      Bit#(TLog#(nsets)) setid,
      Bit#(TLog#(nways)) wayid,
      Bit#(naddr) addr
    );

  endinterface: LLCache_dataram
    
endpackage: LLCache_dataram