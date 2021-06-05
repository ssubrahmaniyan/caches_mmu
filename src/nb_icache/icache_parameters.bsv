// Parameters used for non-blocking I-cache
`define paddr 32
`define numsets 64      // (Integer)
`define numways 4       // (Integer)
`define blocksize 512   // (Bits)
`define wordsize 128    // (Bits) 
`define wordsperblock 4 // (Integer) blocksize/wordsize
`define setbits 6       // (Bits) Log2(numsets)
`define wordbits 2     // (Bits) Log2(wordsperblock)  
`define bytebits 4     // (Bits) log2(wordsize/8)
`define tagbits 20      // (Bits) `paddr(32) - (setbits+wordbits+bytebits)
//i-class supports sv39