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
`define ibus_width 128 // (Bits)
`define reqid_size 4
`define mhb_size 8
`define imshr_depth 4
`define fb_depth 4
`define irq_size 1
//i-class supports sv39