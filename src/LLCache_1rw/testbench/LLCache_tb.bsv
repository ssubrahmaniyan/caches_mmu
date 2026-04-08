/*
Author: Sanjeev Subrahmaniyan
E-mail: subrahmaniyansanjeev@gmail.com
*/

package LLCache_tb;

  // BSV Library Imports
  import Vector   ::  *;
  `include "Logger.bsv"
  
  // Project Lib Imports 
  import LLCache  ::  *;

  (* synthesize *)
  module mkLLCTestbench(Empty);

    Reg#(Bit#(4)) rg_test_state <- mkReg(4'b0000);

    let test <- mkLLCache();

    rule start;
      $display("LLCache testing");
      $finish();
    endrule: start
    
  endmodule: mkLLCTestbench

endpackage: LLCache_tb
