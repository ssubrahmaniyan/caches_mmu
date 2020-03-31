XLEN=64

# Supervisor related settings
SUPERVISOR=sv39
DTLBSIZE=4
ASIDWIDTH=9
ATOMIC=disable

DCACHE=enable
DSETS=64
DWORDS=8
DBLOCKS=8
DWAYS=4
DFBSIZE=4
DSBSIZE=2
DESIZE=1
DREPL=PLRU
DRESET=1
DDBANKS=1
DTBANKS=1
ECC=enable
ECC_TEST=enable

THREADS=1
COVERAGE=line
TRACE=disable

TOP_MODULE:=mkdmem_tb
DIR:=../:./common_bsv:./common_verilog/bsvwrappers:../../:../../tlbs
TOP_DIR:= ./
TOP_FILE:= dmem_tb.bsv

