/*
see LICENSE.iitm
--------------------------------------------------------------------------------------------------
*/

// Parameters used for non-blocking I-Cache
`define numsets `isets                                    // number of sets
`define numways `iways                                    // number of ways
`define wordsize TMul#(`iwords, 8)                        // (Bits) chunk width
`define wordsperblock `iblocks                            // chunks per cache block
`define setbits TLog#(`isets)                             // (Bits) Log2(numsets)
`define blocksize TMul#(`wordsize, `iblocks)              // (Bits) wordsize * wordsperblock
`define wordoffset TLog#(`iblocks)                        // (Bits) Log2(wordsperblock)
`define byteoffset TLog#(`iwords)                         // (Bits) Log2(iwords)
`define offsetbits TAdd#(TLog#(`iblocks), TLog#(`iwords)) // (Bits) wordoffset + byteoffset
`define tagbits TSub#(`paddr, TAdd#(TAdd#(TLog#(`isets), TLog#(`iblocks)), TLog#(`iwords))) // (Bits) paddr - (setbits + wordoffset + byteoffset)

`define mhb_size `imhb_size
`define fb_depth TDiv#(TMul#(`wordsize, `iblocks), `ibuswidth) // number of sub-entries per LFB entry (blocksize / ibuswidth)

`define crq_size `ftq_size  // Core Response Queue should have the same number of entries as FTQ
`define crq_input_size 4    // "Stage 2 hit (MHB/Cache)", "Request served in MHB" , "I/O Response", "Stage1 (ITLB trap/Fences)"
`define reqid_width TLog#(`ftq_size)

`define v_wordsize valueOf(`wordsize)
`define v_setbits valueOf(`setbits)
`define v_blocksize valueOf(`blocksize)
`define v_wordoffset valueOf(`wordoffset)
`define v_byteoffset valueOf(`byteoffset)
`define v_offsetbits valueOf(`offsetbits)
`define v_tagbits valueOf(`tagbits)
`define v_fb_depth valueOf(`fb_depth)

// I-Class supports sv39
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

