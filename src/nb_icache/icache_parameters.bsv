/*
see LICENSE.iitm
--------------------------------------------------------------------------------------------------
*/
`include "parameters.bsv"

// Parameters used for non-blocking I-cache
`define paddr 32
`define numsets 64      // (Integer)
`define numways 4       // (Integer)
`define blocksize 512   // (Bits)
`define wordsize 128    // (Bits) 
`define wordsperblock 4 // (Integer) blocksize/wordsize
`define setbits 6       // (Bits) Log2(numsets)
`define wordoffset 2     // (Bits) Log2(wordsperblock)  
`define byteoffset 4     // (Bits) log2(wordsize/8)
`define offsetbits 6    // (Bits) wordoffset+byteoffset
`define tagbits 20      // (Bits) `paddr(32) - (setbits+wordoffset+byteoffset)
//`define irepl_lru True
`define irepl_rrobin True
//`define irepl_plru True
`define ibuswidth 128 // (Bits)
`define fetch_width 128 // (Bits)
`define mhb_size 8
`define crq_size `ftq_size
`define reqid_width TLog#(`ftq_size)
`define crq_input_size 4 // "Stage 2 hit (MHB/Cache)", "Request served in MHB" , "I/O Response", "Stage1 (ITLB trap/Fences)"
`define imshr_depth 4
`define fb_depth 4
`define irq_size 1
`define causesize 5
//i-class supports sv39
`ifdef sv32
  `define vpnsize 20
  `define ppnsize 22
  `define varpages 2
  `define subvpn 10
  `define lastppnsize 12
  `define maxvaddr 32
`elsif sv39
  `define vpnsize 27
  `define ppnsize 44
  `define varpages 3
  `define subvpn 9
  `define lastppnsize 26
  `define maxvaddr 39
`else
  `define vpnsize 36
  `define ppnsize 44
  `define varpages 4
  `define subvpn 9
  `define lastppnsize 17
  `define maxvaddr 48
`endif

`define Inst_addr_misaligned  0 
`define Inst_access_fault     1 
`define Illegal_inst          2 
`define Breakpoint            3 
`define Load_addr_misaligned  4 
`define Load_access_fault     5 
`define Store_addr_misaligned 6 
`define Store_access_fault    7 
`define Ecall_from_user       8 
`define Ecall_from_supervisor 9 
`define Ecall_from_machine    11
`define Inst_pagefault        12
`define Load_pagefault        13
`define Store_pagefault       15
