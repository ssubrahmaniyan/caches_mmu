## Quick Info

* **Module Name**: [``mkl1icache``](../src/l1icache.bsv#L81)
* **Package Name**: [``l1icache``](../src/l1icache.bsv)
* **Interface Name**: [``Ifc_l1icache``](../src/l1icache.bsv#L53)
* **BSV Libraries Used**: Vector,  FIFOF, DReg, GetPut, BUtils, Assert
* **Local Packages Used**: [`cache_types`](../src/cache_types.bsv), [`mem_config`](../src/mem_config.bsv), [`replacement`](../src/replacement.bsv)

## General Description

This module implements an L1 instruction cache. The cache can be configured to implement an n-way associative
cache with configurable number of sets and bytes per block. This particular version of cache has been modeled to leverage
a single-ported RAM which contains a single port for read and write operations. 

The instruction cache is blocking in nature, i.e. unless a miss is served the next request cannot be served.
Multiple FIFOs have been used to ensure a near pipeline like nature in situations of continuous cache hits.

The cache can also be disabled at runtime through software, after which all requests will be directed to the 
system bus. All peripheral IO accesses which are non-cacheable always will also be directed directly to the 
system bus.

The cache also contains a variable size fill-buffer which is used to hold lines coming from the next level of
memory on a miss at L1. When the cache is idle or when an oppurtunity exists to use the port of the RAM, filled
lines from the fill-buffer start populating the respective lines in the RAM.

Currently the cache supports 3 replacement policies: random, round-robin and pseudo-lru (for 4 ways only). The 
choice of the replacement policy can be defined at instance declaration itself. The replacement policy is
update either on a hit to a line (in case of PLRU only) or while filling up the RAM with a line from the fill-buffer.
Since the instruction cache does not support write operations, the replaced line is simply overwritten and there
is no notion of _dirty_.

## Parameters

### Interface Parameters:

1. `wordzie`: This is a numeric parameter which defines the number of bytes in a word. This defines the response interface between the core and cache.
2. `blocksize`: This is a numeric parameter which defines the number of words that exist per block
3. `sets`: This is a numeric parameter which defines the number of sets for the data and tag array.
4. `ways`: This is a numeric parameter which defines the number of blocks per set.
5. `paddr`: This is numeric parameter indicating the size of address of the system bus. This helps identify the number of tagbits that will be required.
6. `fbsize`: This is a numeric parameter defining the number of entries in the fill-buffer.

### Module Parameters:

1. ``is_IO``: This is a boolean function which returns a `True` if the request should bypass the cache and go directly
to the system bus. This function takes the current requested address as input compares it with the memory mapped IO addresses
and also checks if the programmable `cache-disable` bit set and decides if the request should bypass the cache or not.
2. `alg`: This is a string parameter which defines the replacement policy to be chosen. Valid values are `RANDOM`, `RROBIN` and `PLRU`.

### Derived Parameters:
The following parameters are internall derived through provisos
1. `respwidth`: This variable is 8x`wordsize` and defines the response data width to the core from the cache.
2. `linewidth`: This variable is 8x`wordsize`x`blocksize` and defines the size of each block in number of bits.
3. `setbits`: This variable indicates the number of bits required to represent a `set` index. Value is `TLog#(sets)`
4. `wordbits`: This variable indicates the number of bits required to index a byte within a word. Value is `TLog#(wordize)`
5. `blockbits`: This variable indicates the number of bits required to represent each word within a block. Value is `TLog#(blocksize)`
5. `tagbits`: This variable is `paddr` - `setbits` - `blockbits` - `wordbits` and represent the size of the tag-array.


## Global Structures


