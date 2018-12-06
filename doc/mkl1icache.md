## Quick Info

* **Module Name**: [``mkl1icache``](../src/l1icache.bsv#L81)
* **Package Name**: [``l1icache``](../src/l1icache.bsv)
* **Interface Name**: [``Ifc_l1icache``](../src/l1icache.bsv#L53)
* **BSV Libraries Used**: Vector,  FIFOF, DReg, GetPut, BUtils, Assert
* **Local Packages Used**: [`cache_types`](../src/cache_types.bsv), [`mem_config`](../src/mem_config.bsv), [`replacement`](../src/replacement.bsv)

## General Description

This module implements an L1 instruction cache. Following are some of the overall features of the design:

1. The cache can be configured to implement an n-way associative cache with configurable number of sets 
and bytes per block. This particular version of cache has been modeled to leverage a single-ported RAM which 
contains a single port for read and write operations. 
2. The instruction cache is blocking in nature, i.e. unless a miss is served the next request cannot be served.
3. Multiple FIFOs have been used to ensure a near pipeline like nature in situations of continuous cache hits.
4. The cache can also be disabled at runtime through software, after which all requests will be directed to the 
system bus. All peripheral IO accesses which are non-cacheable always will also be directed directly to the 
system bus.
5. The cache also contains a variable size fill-buffer which is used to hold lines coming from the next level of
memory on a miss at L1. When the cache is idle or when an oppurtunity exists to use the port of the RAM, available
lines from the fill-buffer start populating the respective lines in the RAM.
6. Currently the cache supports 3 replacement policies: random, round-robin and pseudo-lru (for 4 ways only). 
The replacement policy is updated either on a hit to a line in the RAM (in case of PLRU only) or while filling 
up the RAM with a line from the fill-buffer. Since the instruction cache does not support write operations, the replaced line is simply overwritten and there is no notion of a _dirty_ line.
7. Fence operation for the instruction cache is a single operation which invalidates all the valid bits of the RAM 
and the fill-buffer.

## Parameters

### Interface Parameters:

1. `wordzie`: This is a numeric parameter which defines the number of bytes in a word. This defines the response interface between the core and cache.
2. `blocksize`: This is a numeric parameter which defines the number of words that exist per block
3. `sets`: This is a numeric parameter which defines the number of sets for the data and tag array.
4. `ways`: This is a numeric parameter which defines the number of blocks per set.
5. `paddr`: This is numeric parameter indicating the size of address of the system bus. This helps identify the number of tagbits that will be required.
6. `fbsize`: This is a numeric parameter defining the number of entries in the fill-buffer. `fbsize` should always be > 0.
7. `esize`: This is a numeric parameter indicating the size of the `epoch` field in the request and
the response from/to the core respectively.

### Module Parameters:

1. ``is_IO``: This is a boolean function which returns a `True` if the request should bypass the cache and go directly
to the system bus. This function takes the current requested address as input compares it with the memory mapped IO addresses
and also checks if the programmable `cache-disable` bit set and decides if the request should bypass the cache or not.
2. `alg`: This is a string parameter which defines the replacement policy to be chosen. Valid values are `RANDOM`, `RROBIN` and `PLRU`.

### Derived Parameters:
The following parameters are internally derived through provisos
1. `respwidth`: This variable is 8x`wordsize` and defines the response data width to the core from the cache.
2. `linewidth`: This variable is 8x`wordsize`x`blocksize` and defines the size of each block in number of bits.
3. `setbits`: This variable indicates the number of bits required to represent a `set` index. Value is `TLog#(sets)`
4. `wordbits`: This variable indicates the number of bits required to index a byte within a word. Value is `TLog#(wordize)`
5. `blockbits`: This variable indicates the number of bits required to represent each word within a block. Value is `TLog#(blocksize)`
5. `tagbits`: This variable is `paddr` - `setbits` - `blockbits` - `wordbits` and represent the size of the tag-array.


## Global Structures

### Structures used at interface

1. `ff_core_request`: This is a 2-entry FIFO of type `ICore_request#(paddr)`. This fifo is used to capture the request from the core
through the `core_req` interface. Data in this fifo is enqued in the `core_req` interface and is dequed either during a fence operation
or when responding back to the core with relevant data.
2. `ff_core_response`: This is a 2-entry FIFO of type `ICore_response#(respwidth)`. Data in this fifo is enqued when there is a hit either in
the data-RAM, the fill-buffer or on completed IO read-request. The value from the fifo is dequed in the `core_resp` interface towards the core.
3. `ff_read_mem_request`: This is a 2-entry FIFO of type `IMem_request#(paddr)`. Data is enqued into this fifo when a miss occurs in both the data-RAMs
and the fill-buffer for a cacheable request. Data is dequed through the `read_mem_req` interface by the system bus transactor. The `burst_len` and `burst_size`
fields of the tuple are hardcoded to `blocksize-1` and `wordbits-1` respectively for all line-requests.
4. `ff_read_mem_response`: This is a 2-entry BypassFIFO of type `IMem_response(respwidth)` which is enqued through the interface `read_mem_resp` 
when the system bus responds with the data for the respective line-request. The fifo is dequed within the module while filling a line in the fill-buffer.
5. `ff_io_read_request`: This is a 2-entry FIFO of type `IMem_request#(paddr)` which is enqued on a non-cacheable request from the core. The fifo 
is dequed through the `io_read_req` interface by the system bus transactor.
6. `ff_io_read_response`: This is a 2-entry BypassFIFO of type `IMem_response(respwidth)` which is enqued through the interface `io_read_resp` 
when the system bus responds with the data for the respective non-cacheable request. The fifo is dequed within the module whie responding to the core
with the relevant data.
7. `wr_takingrequest`: This a Boolean wire which is set to `True` for the cycle when the `core_req` interface is fired. This wire is used to indicate an oppurtunity to the fill-buffer - that the core is not or cannot request an operation on the RAM ports in this cycle and thus the fill buffer may choose to replace a line back in to the RAMs.
8. `wr_cache_enable`: This is a Boolean wire, which when set to `True` indicates that the current request from the core needs to be cached (if it is non-IO access) else bypass the cache for the core request.
9. `wr_total_access`: This a single-bit wire which is set to `1` whenever the core sends a request through the `core_req` interface.
10. `wr_total_cache_hits`: This is a single-bit wire which is set to `1` whenever there is a hit in the RAMs
11. `wr_total_fb_hits`: This is a single-bit wire which is set to `1` whenever there is a hit in the fill-buffer.
12. `wr_total_nc`: This is a single-bit wire which is set to `1` whenever there is a non-cacheable request from the core.
13. `wr_total_fbfills`: This is a single-bit wire which is set to `1` whenever the fill-buffer is successfull in writing a line from the RAMs.

### Structures to maintain RAM access

1. `data_arr`: This an array of `ways` elements, where each element is of type
[`mkmem_config1rw`](./mkmem_config1rw.md) with `sets` depth and `linewidth` width. 
This structure maintains the cache lines of each way.
2. `tag_arr` This is an array `ways` elements, wherer each element if of type 
[`mkmem_config1rw`](./mkmem_config1rw.md) with `sets` depth and `tagbits` width. 
This structure holds the tag bits of each corresponding line in the `data_arr`.
3. `replacement`: This is an instance of the [`mkreplacement`](./mkreplacement.md) module
and provides the replacement policy to replace lines in an n-way (n>1) associative cache.
4. `rg_valid`: This is an array of `sets` registers, with each register being `ways`-bits wide. This structure indicates which ways of a particular set are valid. 
5. `wr_ram_response`: This is a wire of enum type [`RespState`](./cache_types.md#type-definitions) which indicates if a core request is a hit or miss in the `tag_arr`.
6. `wr_ram_hitword`: This is a wire of `respwidth`-bits which contains the hit word from the 
ram if `wr_ram_response` indicates a hit in `tag_arr`. On a ram miss it holds `0`.
7. `wr_ram_hitway`: This is a wire of `TLog#(ways)`-bits wide which holds the ram way 
which gave a hit for `wr_ram_response`. On a ram miss this wire holds `0`. This wire is used
to update the `PLRU` replacement policy on a hit in the ram. For a cache configuration
with less than 2 ways or `RROBIN` or `RANDOM` replacement policies, this wire is not used.
8. `wr_ram_hitindex`: This is a `Mayb#(TLog#(sets))`-bit wide wire which holds the index of set
 number which was a hit in the RAM for a given core-request. When the `PLRU` replacement
 policy is enabled this wire is read when the fill-buffer performs a write in to the RAM. 
 If this write is to the same set as a hit in the RAM, then the RAM hit gets precedence
 over-updating the `PLRU` states rather than the fill-buffer write updating the policy.

 ### Common Control-flow structures
 1. `rg_miss_ongoing`: This is a boolean register which is set to `True` when a miss
 in both RAM and fill-buffer is identified for a particular core request. Once this
 register is set then the following rules are diabled:
    * tag_match
    * request_to_memory
This will prevent from any further requests from the core being serviced. The register is
set to `False` only when the next memory level has responded with the required request and 
that value is forwarded back to the core.
2. `rg_fence_stall`: This is a boolean register which is set to `True` as soon as a
fence request from the core is received. When set to `True` the cache will no longer
receive requests from the core i.e. it disables the interface `core_req` from firing. When 
set to `True`, this register can trigger the rule `release_from_FB` to fire as well if 
other conditions are met as well. Rule `fence_operation` will also fire when this register 
is set to `True` if all the other conditions for the rule are met.

### Non-Cacheable Structures
1. `wr_nc_response`: This is a wire of enum type [`RespState`](./cache_types.md#type-definitions) which indicates if the response for a non-cacheable
request has arrived. 
2. `wr_nc_word`: This a `respwidth`-bit wide wire which carries the word of non-cacheable
response which needs to be forwarded back to the core.
3. `wr_nc_errr`: This is a boolean wire which indicates if a bus-error occurred while
 performing a non-cacheable access. 

### Fill Buffer Structures
1. `fb_dataline`: This is an `fbize` array of registers, with each register being `linewidth`
 -bits wide. This array stores the data-line that was received from the next level memory.
2. `fb_addr`: This is an `fbsize` array of registers, with each register holding the physical
address of the corresponding line in the fill-buffer. This register is filled when there is 
a miss in both RAM and fill-buffer for a given request from the core.
3. `fb_enables`: This is an `fbsize` array of registers, with each register holding a 
`blocksize`-bit variable indicating which words in the corresponding `fb_dataline` are present
in the registers. Each bit in this register is set once the corresponding word from the next 
level of memory arrives to the cache.
4. `fb_valid`: This is an `fbsize` array of boolean type registers. This is register is made
`True` when there is a miss in the RAM and fill-buffer for a given core request. The register 
is made `False` when the fill-buffer writes the dataline back to the RAM. 







