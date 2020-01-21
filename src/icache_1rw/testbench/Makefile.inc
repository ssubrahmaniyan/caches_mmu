XLEN=64

# Supervisor related settings
SUPERVISOR=sv39
ITLBSIZE=4
ASIDWIDTH=9
ATOMIC=disable

ICACHE=enable
ISETS=128
IWORDS=4
IBLOCKS=8
IWAYS=4
IESIZE=2
IFBSIZE=6
IREPL=PLRU
IRESET=1
IDBANKS=1
ITBANKS=1
IBUSWIDTH=64
ECC=disable
ECC_TEST=disable

THREADS=1
COVERAGE=line
TRACE=disable

TOP_MODULE:=mkimem_tb
DIR:=../:./common_bsv:./common_verilog/bsvwrappers:../../:../../tlbs/
TOP_DIR:= ./
TOP_FILE:= imem_tb.bsv

