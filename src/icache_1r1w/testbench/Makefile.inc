XLEN=32

# Supervisor related settings
SUPERVISOR=sv32
ITLBSIZE=4
ASIDWIDTH=9
ATOMIC=disable

ICACHE=enable
ISETS=64
IWORDS=4
IBLOCKS=16
IWAYS=4
IESIZE=2
IREPL=PLRU
IRESET=1
IDBANKS=1
ITBANKS=1
ECC=disable
ECC_TEST=disable

THREADS=1
COVERAGE=line
TRACE=disable

TOP_MODULE:=mkimem_tb
DIR:=../:./common_bsv:./common_verilog/bsvwrappers:../../:../../tlbs/
TOP_DIR:= ./
TOP_FILE:= imem_tb.bsv

