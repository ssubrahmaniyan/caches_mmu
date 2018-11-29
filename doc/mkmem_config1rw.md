## Contents

- [Quick Info](#quick-info)
- [General Description:](#general-description-)
- [Parameters](#parameters)
  * [Interface Parameters:](#interface-parameters-)
  * [Module Parameters:](#module-parameters-)
- [Global structures](#global-structures)
- [Methods](#methods)
- [Rules](#rules)

## Quick Info

* **Module Name**: [``mkmem_config1rw``](../src/mem_config.bsv#L77)
* **Package Name**: [``mem_config``](../src/mem_config.bsv)
* **Interface Name**: [``Ifc_mem_config1rw``](../src/mem_config.bsv#L72)
* **BSV Libraries Used**: None
* **Local Packages Used**: [`bram_1rw`](../src/bram_1rw.bsv)

## General Description:

This module allows one to create different sized and styled single-ported RAM modules.
It is typically used to instantiate different data and tag RAMs for caches and possibly
also for various TLB configurations. 
The module allows you to configure the number of entries
in the ram, the datawidth of each ram and the number of such rams to be banked horizontally.

This module uses a BVI module ``bram_1rw_new`` to implement the required single-ported RAM 
structures. Such a model of RAM only allows either a read or a write to occur on any given 
posedge. The module can be used directly for FPGAs and also enables easy porting to 
ASIC SRAM libraries by maintaining a generic interface scheme.

## Parameters

### Interface Parameters:

1. ``n_entries``: This is a numeric parameter which defines the number of entries of each single-ported RAM instance.
2. ``datawidth``: This is a numeric parameter which defines the total read-response or write-request width from/to 
   the module
3. ``banks``: This is a numeric parameter which defines the number of banks to be instantiated. The width of those banks 
is defined as '_datawidth/banks_' . It is necessary that ``datawidth`` is a multiple of ``banks``

### Module Parameters:

1. ``ramreg``: This is a boolean parameter which indicates whether the RAM outputs are registered or not.
2. ``porttype``: This is a string parameter which sould always be driven as `"single"`. This will be made obsolete in
future versions

## Global structures

1. ``ram_single``: This variable is an array of `mkbram_1rw` module type which implement the single-ported rams. The array size
is defined by the `banks` parameter.
2. ``rg_output``: This is a CReg type register with 2 ports. Based on the value of `ramreg` parameter this variable will act as 
a register or a bypass wire.

## Methods

1. ``request``: _Action Type_
    * **Explicit Conditions**: None
    * **Implicit Conditions**: None
    * **Arguments**:
        * we: A single bit value indicating a write operation to the RAM when `1` and a read operation from the RAM when `0`
        * index: this is a `TLog(n_entries)`-bit wide argument which indicates the entry of RAM which needs to be accessed.
        * data: this is `datawidth`-bit wide argument which represents the data to be written to the RAM entry on a write operation
    * **Details**: This method latches the address, write-enable and the data onto the ports of the BVI module `mkbram_1rw`.
2. ``read_response``: _ActionValue Type_ 
    * **Explicit Conditions**: None
    * **Implicit Conditions**: None
    * **Arguments**: None
    * **Return Type**: Bit#(`datawidth`)
    * **Details**: method which return the a `datawidth`-bit value from the RAM on a read-operation. The value returned is obtained from the first-port of the `rg_output` variable.


## Rules

1. ``capture_output``: 
    * **Explicit Conditions**: `ramreg`==False
    * **Implicit Conditions**: None
    * **Details**: This rule simply captures the output from the RAM (BVI module `mkbram_1rw`) and writes it to the zeroth port
    of the `rg_output` register. Since the `read_response` method reads from the first port, `rg_output` acts as a bypass wire 
    in this case.
2. ``capture_output_reg``: 
    * **Explicit Conditions**: `ramreg`==True
    * **Implicit Conditions**: None
    * **Details**: This rule simply captures the output from the RAM (BVI module `mkbram_1rw`) and writes it to the first port
    of the `rg_output` register. Since the `read_response` method also reads from the first port, `rg_output` acts as a regular
    register on the output of the RAMs.
