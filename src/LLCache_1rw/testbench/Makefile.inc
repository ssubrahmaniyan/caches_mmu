XLEN=64

# Supervisor related settings
SUPERVISOR=sv39
DTLBSIZE=4
ASIDWIDTH=9
ATOMIC=enable

DCACHE=enable
DSETS=64
DWORDS=8
DBLOCKS=8
DWAYS=16
DESIZE=1
DSBSIZE=2
DFBSIZE=8
DREPL=1
DRESET=1
DDBANKS=4
DTBANKS=1
DBUSWIDTH=64
ECC=disable
ONE_HOT=0
ECC_TEST=disable
PORT=single
PMPSIZE=0
GRAINBITS=3

OVLASSERT=disable
SVAASSERT=enable

THREADS=1
COVERAGE=none
TRACE=disable

# params for testbench
LLCWAYS=8
PADDR=32

TOP_MODULE:=mkLLCTestbench
DIR:=../:./common_bsv:./common_verilog/bsvwrappers:../../tlbs/:../../pmp/:../src/
TOP_DIR:= ./
TOP_FILE:=LLCache_tb.bsv
