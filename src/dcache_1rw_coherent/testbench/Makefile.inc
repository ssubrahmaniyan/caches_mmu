XLEN=64

# Supervisor related settings
SUPERVISOR=sv39
DTLBSIZE=4
ASIDWIDTH=9
ATOMIC=disable

DCACHE=enable
DSETS=128
DWORDS=8
DBLOCKS=1
DWAYS=1
DESIZE=2
DSBSIZE=2
DFBSIZE=2
DREPL=PLRU
DRESET=1
DDBANKS=1
DTBANKS=1
DBUSWIDTH=64
ECC=disable
ECC_TEST=disable
COHERENCE=enable

THREADS=1
COVERAGE=none
TRACE=disable

TOP_MODULE:=mktb_cache_controller
DIR:=../:./common_bsv:./common_verilog/bsvwrappers:../../tlbs/:./fabrics/shaktilink/coherence:../../llc
TOP_DIR:= ./
TOP_FILE:= tb_cache_controller.bsv

