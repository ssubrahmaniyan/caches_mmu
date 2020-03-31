# Micro-Architecture for L1 Caches

This document describes the micro-architecture of the local L1 I-cache and D-cache to be used in the design. These caches are local to each core.

- [Micro-Architecture for L1 Caches](#micro-architecture-for-l1-caches)
  * [Overview](#overview)
  * [Block Diagram](#block-diagram)
  * [Working Principle](#working-principle)
  * [Note](#note)
  * [Extra Features](#extra-features)
    + [1. ECC for the Caches](#1-ecc-for-the-caches)
  * [Testing](#testing)
    + [Configuring the Cache instance and sim environment](#configuring-the-cache-instance-and-sim-environment)
    + [Testbench Structure](#testbench-structure)
    + [Running tests](#running-tests)


## Overview

1. The caches are Virtually-indexed and Physically tagged.
2. RISC-V virtualization schemes (sv32, sv39 and sv48) assume a page size of minimum 4KB and thus use a 12-bit page offset. To prevent page-aliasing issues (synonyms) within the cache we will use the following configuration:
    * **4-way** set associative cache. 
    * **64 bytes per block**. (6-bits to identify byte within block)
    * **64 sets** (6-bits to identify a set)
    * Total cache size : **16KB**.
    * D-cache can **support byte,half-word,word and double-word load/stores** as specified by the RISC-V ISA. An **atomic ALU** also exists within the data-cache to support `RISC-V A` extension.
    * `Note: if synonyms are re-solved in the software higher-cache configurations can be achieved. Else synonym resolutions will have to be done in the hardware which can tend to be very costly in performance and area.`
3. The caches follow a write-back policy. This reduces the traffic to the next-level caches.
4. The caches are designed to use **Single-ported SRAMs/BRAMs** (1-rw configuration) for data and tag arrays. This means that at any given cycles the SRAMs can either perform a read or a write. This choice **improves the area,latency and power** consumption of the entire cache since SP-SRAMs are the lightest-configurations available with a Fab or FPGAs. 
5. The caches also assume that the SRAMs follow a *NO_CHANGE* policy for the read-ports, where only a read-access can cause a change in the output ports. More info on this can be found on page 46 of this [manual](https://www.xilinx.com/support/documentation/ip_documentation/blk_mem_gen/v8_3/pg058-blk-mem-gen.pdf)
6. These are blocking caches. If a miss is encountered, the caches can latch only one more request from the cache which will get served only after the previous miss has been served to the core.
7. On a cache-line miss, the caches expect the fabric/bus to respond with the critical word first.
8. The caches can be disabled at runtime by clearing the bits in a specified csr. `TODO: Give link to custom CSR spec`.
9. To ensure pipeline-like performance and high-throughput from the above choices, the caches also include a **fill-buffer**. The fill-buffer size can be configured at compile time. The fill-buffer is used to hold cache lines temporarily.
    * When there is a line-miss in the cache, a fill-buffer entry gets allotted to the line and the response from the fabric/bus occupies that entry in the fill-buffer.
    * When a store/atomic-request is made by the core, if a hit-occurs in the SRAMs, the respective line is transferred from the SRAMs to the fill-buffer. Thus, the store is always performed in the fill-buffers and not the SRAMs. This design avoids the contention of the SRAM ports by the core for load/stores.
    * When the fill-buffer is full or if the cache is idle, the fill-buffer will release some of the lines into the SRAMs. The **opportunistic-release** algorithm described below, ensures that fill-buffer does not reach its capacity often.
    * It is only during the release from the fill-buffer that a line from a set get allotted or evicted.
10. The caches follow a **Round-Robin** replacement policy per set which requires only 2 bits to be maintained per set. The policy only comes into picture for a set if all lines are valid, else the invalid lines are filled first.
11. The **valid and dirty bits are stored as an array of registers** instead of the in the SRAMs along with the tag. This enables a single-cycle flush operation for a I-Cache and a non-dirty D-Cache. Storing them as register also enables easy control flow-logic for the fill-buffer during allocation and release phases.
12. For the D-Cache, during a fence operation a set can be skipped by simply checking for valid and dirty bits, thereby improving the penalty of a fence operation. A global-dirty bit is also maintained to check if the fence can be completed within a single cycle similar to the D-Cache.
13. The D-cache also employs a variable entry **store-buffer**. This buffer holds the meta-data of the store/atomic operation to be performed by the core during the execute/memory stage of the core-pipeline. The write-back stage of the core instructs the cache to perform the respective store in the fill-buffer or simply discard the store entry in case of a previous trap.
14. The physical **Tags** for comparison are received from the respective TLBs. The size of the tags depends on the physical address size being employed by the platform. RISC-V ISA can support a maximum of 56-bit physical address for sv39.
15. The caches without ECC do not generate any exceptions internally. Access exceptions are received from the fabric and page-faults are captured by the TLBs.
16. A non-cacheable access is identified by the TLB and the cache is responsible for latching the respective request to the fabric. 

## Block Diagram

![](https://i.imgur.com/RgXSBJC.png)
## Working Principle

A request from the core is enqueued into a request fifo (`ff_core_request`). On a hit within the cache, the required word is enqueued into the response fifo (`ff_core_response`) which is read by the core. On a miss, a read request for the line is sent to the fabric via the `ff_read_mem_request` and simultaneously an entry in the fill-buffer is allotted to capture the fabric response. The responses from the fabric are enqueued in the `ff_read_mem_response` fifo. When a dirty line needs to be evicted, a write request for that line is enqueued into `ff_write_mem_request` fifo and the response of this write is captured in `ff_write_mem_response` fifo.

Please note, though the description below is presented for D-Cache, the I-Cache also works in the similar fashion where the requests are treated similar to a Load-request.

**Serving core requests**
A core request can only be enqueued in `ff_core_request` fifo if the following conditions are true :- 

1. Fill-buffer is not full.
2. Core is ready to receive a response or deq the previous response
3. Fence operation is not in progress.
4. A replay of SRAM tag and data request (for a previous request) is not happening (its necessity is discussed in later sections).

The reason for point 1 and 2 being, once either of the two structures are full, a hit or a miss cannot be processed further. In this situation, if there is one outstanding request already present in `ff_core_request`, enqueuing one more request would overwrite the SRAM tag and data values of the previous one. When tag matching resumes, incorrect tag would be used leading to incorrect behaviour.

Once a request is enqueued into the `ff_core_request` fifo, a tag and data read request is sent to the SRAMs simultaneously. In the next cycle, if there isn't a pending request and fill-buffer & ff_core_response are not full, the tag field of the request is compared with the tags stored in the SRAMs (tag field of all the ways for particular set) and the fill-buffer (tag field of all the entries). 

A hit occurs in following scenarios :- 1. Tag matches in SRAM 2. Tag matches in fill-buffer and also the requested word is present. There might be a case where tag matches in fill-buffer but the word is not present as the line is still getting filled by the fabric. In that case we keep polling on the fill-buffer until there's a **word-hit**. Please note, that a tag-hit can occur either in the SRAM or the fill-buffer and never both. Assertions to check this have been put in place. A miss occurs when tag match fails in both the SRAM and the fill-buffer. Now following scenarios can occur :-
1. **For a Load request**: if it's a hit, the requested word is enqueued in `ff_core_response` fifo in the same cycle as the tag-match. When it's a hit in the FB, before enqueuing the response, we check if there is a pending store to the same word, if so we enqueue the updated word accordingly. Since, the SRAMs are not updated with stores immediately, the store-buffer is looked up only in the case of a fill-buffer hit.
2. **For a Load request**: If it's a miss, the address (after making it word aligned) is enqueued into the `ff_read_mem_request` fifo to be sent to fabric. Simultaneously, a fill-buffer entry is assigned to capture the line requested from the fabric. Once the requested word is captured in the fill-buffer (while rest of the line is still getting filled), it is enqueued into the `ff_core_response` to be sent to core and the entry in `ff_core_request` is dequeued. We are now ready to service the subsequent request in the next cycle.
3. **For a store request**: If it's a hit in the fill-buffer, a store buffer entry is allotted to store the data to be written and response is enqueued in the `ff_core_response` fifo (response being that it is store hit). If it's a hit in the SRAM, in addition to performing actions that of a fill-buffer hit, the line is copied into the fill-buffer (since all stores are performed here) while making it invalid in the SRAM.
4. **For a store request**: If it's a miss, request would be sent to fabric as was when load miss occurred. Once the requested word is captured in the fill-buffer, the actions that follow are similar to those of store hit in fill-buffer.
5. **For atomic requests**: The control is similar to that store-requests apart from the fact that the updated word undergoes arithmetic op before being written in the store-buffer.

**Release from fill-buffer**

The necessary condition for a release of a line from fill-buffer and its updation into SRAM is that the line itself is valid and all the words in the line are present and updated by store-buffer if necessary. If there is any pending store in the store buffer, the line won't be released. Given this is true, following conditions would initiate a release :- 

1. **Fill-buffer is full**. A release is necessary in this case since no more requests can be taken and it can stall the pipe. While the release happens, suppose there is an entry already present in the request fifo which is to the line being released. The tag and data for that entry have already been read and would be used to check hit/miss. The SRAM tag matching would take place with a stale value and would result in a miss. It would also be a miss in fill-buffer since the line would already have been released. To prevent this incorrect behaviour, we need to replay the SRAM tag and data requests (now it would be a hit in SRAM).
2. **Opportunistic fill**: if the fill-buffer is not full but there is no request being enqueued in a particular cycle (this does not mean `ff_core_request` is empty). Given this, if there is an entry in `ff_core_request` to the line being released, we prevent the release for not wanting to replay the SRAM read request (described in point 1).

Now given the release can actually take place, following scenarios would arise :-

1. If the line in the SRAM being evicted is not dirty, then we can directly put a write request (of the line being released) to the SRAM along with updation of the SRAM dirty and valid bits accordingly.
2. If the line being replaced is dirty, we need to write it back to fabric. So first we put a read request to SRAM for the dirty line, in the next cycle we enqueue this line in the `ff_write_mem_request` for it to be written back in fabric while also putting a SRAM write request for line being released.

Once a release is done from the fill-buffer, that particular entry in the fill-buffer is invalidated and thus is available for new allocation on a miss or a store-hit.

The fill-buffer is implemented as a circular-buffer with head and tail pointer-registers.

**Fence operation**
A cache-flush operation is initiated when the core presents a fence instruction. A fence operation can only start if following conditions are met:

1. the entire fill-buffer is empty (i.e. all lines are updated in the SRAM).
2. there are not pending write-backs to fabric 
3. the store-buffer is empty.

In case of the I-cache, the fence operation is a single cycle operation which invalidates all the SRAM entries.
In case of the D-Cache, the fence operation is a single cycle operation if the global-dirty bit is clear, where all the lines are invalidated and the dirty bits of each line are cleared as well. If the global-dirty bit is set, the fence operation in the D-Cache traverses through each set and identifies which lines need to the written back to the fabric. Traversing a set, requires traversing each of the way and checking if a write-back is required. A set is ignored if there are no valid dirty lines in the set. At the end of each set traversal, the valid and dirty bits of the entire set are cleared. The fence operation in the D-Cache is only over when the last set has been completely traversed. Until this point, not new requests are entertained from the core-side.

## Note
1. The vipt and pipt versions are maintained as different bluespec design for now.

## Extra Features

### 1. ECC for the Caches

Since the caches follow a write-back policy, the ECC at L1 will require both correction and detection to be available.
We will be using basic **Hamming-Code** based algorithms to implement the encoders and decoders required for correction and detection. The ECC logic will be able to detect upto 2 errors and correct only a single error following the **SEC-DED** principle.

Points of consideration:
1. Since we are using a 64-bit core, the fabric data-width is also going to be 64-bits (double-word). This means that on a line-miss, the cache will receive 64-bits at-a-time from the fabric. 
2. All line-misses will be occupied in the fill-buffer first. The lines from the fill-buffer will be released to the SRAMs when either the fill-buffer is full or when a *release-opportunity exists*
3. All stores from the core update the respective bytes (byte, half-word, word, double-word) of a fill-buffer entry.

Now there are multiple approaches possible to implement ECC in the caches:

1. `Adding ECC support to cache lines within the fill-buffer at a double-word granularity`: 
    1. The fill-buffers are implemented as registers. Thus when the fabric responds with a double-word the ECC encoder can generate the parity for the double word and store it alongside the respective fill-buffer entry. Hamming-Code based ECC will require upto 7-bits of storage per double-word. In our architecture we will have 8 double words per block and thus will require a storage of 56-extra bits per bloc.
    2. The fill-buffer is also updated on a store and within a cycle only a single store can occur on the entire fill-buffer. This requires reading the double-word from the fill-buffer registers, updating the respective bytes of the double-word and generating the new parity bits for the same.
    3. We will also maintain a separate structure of SRAMs which hold the 56 parity bits for each block of the data-SRAMs. Since the fill-buffer now already holds the ECC bits, they are simply updated into the SRAMs without any further computations.
    4. Each time the core make a request, the SRAMs and fill-buffer entries are looked up, the respective double-word holding the required bytes is extracted and the parity is checked only for that double-word (irrespective if the request is for byte, half-word, double-word, word). If an ECC-error is detected an access-fault can be generated or a new trap-cause can be allotted for the same.
    5. This entire scheme will employ 1-decoder and 2-encoders (one during fabric-fill and one during store update) each operating on a double-word granularity.

2. `Adding ECC support to cache lines within the fill-buffer at a block granularity`:
    1. This will be similar to the above scheme, but instead will operate on a block level. Once the fabric has responded with all the double-words required in the block, the ECC encoder is used to generate the parity of the entire block.
    2. Similarly on a store, the updated line in the fill-buffer is used as input to the ECC encoder.
    3. This scheme as well will require 1-decoder and 2-encoders but each operating on a block level (64-bytes)

3. `Adding ECC support to only SRAMs`: 
    1. Here we will not perform any ECC on the fill-buffers. 
    2. When a line is released from the fill-buffer to the SRAM the parity-bits are generated and stored in the SRAMs.
    3. A look-up will invoke the ECC decoder for parity check only if there is a hit in the SRAMs and not otherwise.
    4. Options of doing ECC at a double-word or block also exist here. If the ECCs are stored on a double-word granularity then 8-encoders and 8-decoders will be required. However, if the ECC is done on a block granularity a single-encoder and decoder is employed.


The modules currently available implement the first scheme!

## Testing

A test-bench is available in the testbench folder. 
The Makefile.inc can be used to configure the type of cache to be instantiated. Please note for the
I-Cache the response-width to the core should always be 32. The bus-width however depends on the
XLEN of the core it is connected to. Following are details of various hooks that can be manipulated
for testing the cache

### Configuring the Cache instance and sim environment
* __XLEN__ : should be set to either 32 or 64. For I-Cache this corresponds to the bus-width that is
  going to be used for memory transactions.
* __DCACHE__: Valid options:
    * `enable`: Will enable creating a single instance of the instruction-cache
    * `disable`: No instruction cache will be instantiated. But instead a simple state-machine to handle requests on the fabric will be instantiated. This simple state-machine is created to keep the interface between the core and the fabric constant irrespective of whether a cache is instantiated or not.
* __DSETS__: An integer value indicating the number of sets of the SRAMs in the I-cache.
* __DWORDS__: An integer value indicating the number of bytes in a word for the I-cache. For any core-config this should be typically be set to 4. This variable defines the size of the response from the cache to the core. Even when compressed is enabled, we expect the I-cache to respond with 32-bits, and expect the fetch-stage to handle the split/join of the instructions.
* __DBLOCKS__: An integer value indicating the number of the words in a block/cache-line. Please note to prevent aliasing in the caches the following should hold: `ISETS`x`IWORDS`x`IBLOCK`<=4096.
* __DWAYS__: An integer value >0 indicating the number of ways in the I-cache.
* __DFBSIZE__: An integer value >1 indicating the number of entries in the Fill-buffer of the I-cache. 
* __DSBSIZE__: An integer value >1 indicating the number of entries in the store-buffer of the D-cache. 
* __DESIZE__: Should always be set to 3 for all configs. This variable indicates the number of the `epoch` bits in the request from the core to the Cache.
* __DRESET__: Can be either 0 or 1. A value of 0 indicates that the I-cache, though instantiated in HW, will be disabled on reset and has to be enabled thorugh software by setting the relevant bit in the custom-control csr. A value of 1 indicates that the I-cache is available immediately after reset.
* __DDBANKS__: The number of banks that data-rams of the I-cache should be split into.
* __DTBANKS__: The number of banks that tag-rams of the I-cache should be split into.
* __SUPERVISOR__: Valid options:
    * `sv32`: enables the `sv32` mode support only if XLEN is 32
    * `sv39`: enables the `sv39` mode support only if XLEN is 64
    * `sv48`: enables the `sv48` mode support only if XLEN is 64
    * `none`: disables the `S` Extension of the RISC-V ISA spec.
* __DTLBSIZE__: Integer value defining the number of entries in the fully-associative Instruction TLB
* __ECC__: Valid options:
    * `enable`: implements basic SEC-DED logic within the cache for 32-bit granularity
    * `disable`: no ECC support is available within the Cache.
* __ECC_TEST__: Valid options:
    * `enable`: This will inject a single-bit-error within the response from the BRAMs or Fillbuffer
      through LFSRs. These errors are expected to be corrected by the SEC-DED logic and thus allow
      all tests to pass

### Testbench Structure

The testbench uses a stimulus text file which is generated by gen_test.py. This python program makes it easy to generate
random and directed test-cases. Executing gen_test.py creates 2 files: 
    * `data.mem`: which consists of ramdomized data-memory
    * `test.mem`: which consists of the requests to be made to the cache. The request includes: fence, address, size, read/write (in case of data caches) and no op cycles.

The testbench also uses a `test_cache` as the golden model to verify the outputs of the cache under test. The `test_cache` is modeled quite simply by performing single cycle ops using a RegFileLoad module. Each time a response from the cache is obtained the same request is performed on the test_cache and the outputs are compared. The simulation terminates at any point when the results mismatched of the stimulus indicates end of simulation (an all zero input)

### Running tests
in the testbench folder a python program is available which can be used to make directed tests for
the i-cache in a simple and easy manner. Currently there are 15-odd tests available which check
various aspects of the cache. To run these tests set the Makefile.inc based on your requirement and
do the following:
``` bash
cd testbench
./manager.sh update_deps
make
```

Expected output:
``` bash
Generating test for Following Parameters: 
Sets: 64
Ways: 4
Word_size: 4
Block_size: 16
Addr_width: 32
Repl_Policy: PLRU
Total Entries in Test: 339
TB: ********** Test:         1 PASSED****
TB: ********** Test:         2 PASSED****
TB: ********** Test:         3 PASSED****
TB: ********** Test:         4 PASSED****
TB: ********** Test:         5 PASSED****
TB: ********** Test:         6 PASSED****
TB: ********** Test:         7 PASSED****
TB: ********** Test:         8 PASSED****
TB: ********** Test:         9 PASSED****
TB: ********** Test:        10 PASSED****
TB: ********** Test:        11 PASSED****
TB: ********** Test:        12 PASSED****
TB: ********** Test:        13 PASSED****
TB: ********** Test:        14 PASSED****
TB: ********** Test:        15 PASSED****
TB: All Tests PASSED. Total TestCount:         15
- verilog//mkimem_tb.v:617: Verilog $finish
Simulation finished

```

Details of each test-case is available in `gen_test.py`.
