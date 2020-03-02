XLEN=64

# Supervisor related settings
SUPERVISOR=sv39
DTLBSIZE=4
ASIDWIDTH=9
ATOMIC=disable

DCACHE=enable
DSETS=128
DWORDS=8
DBLOCKS=4
DWAYS=4
DESIZE=2
DSBSIZE=2
DREPL=1
DRESET=1
DDBANKS=1
DTBANKS=1
DBUSWIDTH=64
ECC=disable
ECC_TEST=disable

THREADS=1
COVERAGE=line
TRACE=enable

TOP_MODULE:=mkdmem_tb
DIR:=../:./common_bsv:./common_verilog/bsvwrappers:../../tlbs/
TOP_DIR:= ./
TOP_FILE:= dmem_tb.bsv

