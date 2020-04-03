XLEN=64

# Supervisor related settings
SUPERVISOR=sv39
ITLBSIZE=4
ASIDWIDTH=9

ICACHE=enable
ISETS=128
IWORDS=4
IBLOCKS=8
IWAYS=4
IESIZE=1
IFBSIZE=8
IREPL=1
IRESET=1
ITBANKS=1
IBUSWIDTH=64
ECC=enable
ONE_HOT=0
ECC_TEST=disable
PMPSIZE=4
GRAINBITS=3

THREADS=1
COVERAGE=none
TRACE=disable

TOP_MODULE:=mkimem_tb
DIR:=../:./common_bsv:./common_verilog/bsvwrappers:../../tlbs/:../../pmp
TOP_DIR:= ./
TOP_FILE:= imem_tb.bsv

