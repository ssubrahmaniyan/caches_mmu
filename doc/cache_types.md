## Contents
- [Quick Info](#quick-info)
- [General Description](#general-description)
- [Type Definitions](#type-definitions)
- [Functions](#functions)

## Quick Info

* **Module Name**: None
* **Package Name**: [``cache_types``](../src/cache_types.bsv)
* **Interface Name**: None
* **BSV Libraries Used**: None
* **Local Packages Used**: None

## General Description

This package contains various type definitions which are used by various caches and TLB structure
available in the src folder of this repo.

## Type Definitions

1. `ICore_request`: Tuple of 4 elements
    * **Arguments**: `addr` , `esize`
    * **Description**: This type represents the request packet format from the core to the instruction cache.
    * **Fields**: 
        1. An `addr`-bit wide field containing the address of the request.
        2. A boolean field indicating if the request is a fence operation or not.
        3. A `esize`bit field indicating `epoch` tag of the request.
        4. A boolean field indicating if the request is a prefetch request.
2. `ICore_response`: Tuple of 3 elements
    * **Arguments**: `data` , `esize`
    * **Description**: This type represents the response packet from the instruction cache to the core.
    * **Fields**: 
        1. `data`-bit wide field containing the instruction to be sent to the core.
        2. A boolean field indicating if the request faced a bus-error.
        3. A `esize`-bit field containing the `epoch` tag of the request.
3. `IMem_request`: Tuple of 3 elements
    * **Arguments**: `addr`
    * **Description**: This type represents the packet format of the request sent to the memory bus from the instruction cache.
    * **Fields**: 
        1. A `addr`-bit wide field containing the address of the read request on the bus
        2. An 8-bit field containing the burst length of the transaction to be initiated.
        3. A 3-bit field indicating the size of a transaction (eg. 32-bit, 64-bit, etc).
4. `IMem_response`: Tuple of 3 elements
    * **Arguments**: `data`
    * **Description**: This type represents the packet format of the response from the memory bus to the instruction cache.
    * **Fields**: 
        1. A `data`-bit wide field containing the instruction of the read request from the bus
        2. A boolean field indicating if this is the last beat of the burst transfer or not.
        3. A boolean field indicating if the response has an error from the bus or the slave.
5. `RespState`: Enum of 3 valid values
    * **Arguments**: None
    * **Description**: This type is used to indicate if a hit or miss has occurred for a request in any of the data structures 
used in the cache designs
    * **Enums**: 
        1. `Hit`: Indicates a hit in the respective data structure
        2. `Miss`: Indicates a miss in the respective data structure
        3. `None`: Default response of the data structure when no request is pending.
6. `DCore_request`: Tuple of 6 elements
    * **Arguments**: `addr` and `data`
    * **Description**: This type represents the request packet format from the core to the data cache.
    * **Fields**: 
        1. An `addr`-bit wide field containing the address of the request.
        2. A boolean field indicating if the request is a fence operation or not.
        3. A Single bit field indicating `epoch` tag of the request.
        4. A 2-bit field containing the type of access. 0-Instruction, 1-Load, 2-Store and 3-Atomic
        5. A 3 bit field containing the size of the access. MSB-bit value of 1 indicates zero-extension otherwise the value is 
        sign extended. LSB 2 bits: 00-byte access, 01-halfword access, 10-word access and 11-doubleword access.
        6. A `data`-bit wide field carrying the data to be written on a store or atomic operation.
7. `DCore_response`: Tuple of 3 elements
    * **Arguments**: `data`
    * **Description**: This type represents the response packet from the instruction cache to the core.
    * **Fields**: 
        1. `data`-bit wide field containing the instruction to be sent to the core.
        2. A boolean field indicating if the request faced a bus-error.
        3. A single-bit field containing the `epoch` tag of the request.
8. `DMem_read_request`: Tuple of 3 elements
    * **Arguments**: `addr`
    * **Description**: This type represents the packet format of the request sent to the memory bus from the instruction cache.
    * **Fields**: 
        1. A `addr`-bit wide field containing the address of the read request on the bus
        2. An 8-bit field containing the burst length of the transaction to be initiated.
        3. A 3-bit field indicating the size of a transaction (eg. 32-bit, 64-bit, etc).
9. `DMem_read_response`: Tuple of 3 elements
    * **Arguments**: `data`
    * **Description**: This type represents the packet format of the response from the memory bus to the instruction cache.
    * **Fields**: 
        1. A `data`-bit wide field containing the instruction of the read request from the bus
        2. A boolean field indicating if this is the last beat of the burst transfer or not.
        3. A boolean field indicating if the response has an error from the bus or the slave.
10. `DMem_write_response`: Boolean
    * **Arguments**: None
    * **Description**: A True value indicates that the write request to the memory responded with an error.
11. `TLB_permissions`: A struct of 8 fields
    * **Arguments**: None
    * **Descriptions**: This type is used in TLBs to represent the access properties of the page as defined in the risc-v supervisor spec.
    * **Fields**:
        1. `v`: Boolean field indicating if the page is valid.
        2. `r`: Boolean field indicating if the page has read permissions.
        3. `w`: Boolean field indicating if the papge has write permissions.
        4. `x`: Boolean field indicating if the papge has execute permissions.
        5. `u`: Boolean field indicating if the papge is a user allocated page.
        6. `g`: Boolean field indicating if the papge has global access.
        7. `a`: Boolean field indicating if the papge has been previously accesssed or not.
        8. `d`: Boolean field indicating if the papge has been previously written. 

## Functions

1. `bits_to_permissions`: 
    * **Arguments**: 8-bit value
    * **Return Type**: `TLB_permissions` type
    * **Description**: converts the lower 8 bits of the page table entry into `TLB_permissions` type.
2. `countName`:
    * **Arguments**: Integer 
    * **Return Type**: String
    * **Description**: This function is used by the i-cache to associate string name with varios performance counters. Each performance counter is numbered
    and this function associates the number with the relevent string definition.
