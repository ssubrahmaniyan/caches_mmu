############ DO NOT CHANGE THESE #################
SUPPORTED:=./src/
TOP_MODULE:=mkimem_tb
XLEN=64
define_macros:=-D VERBOSITY=2 -D ASSERT=True -D atomic=True -D pmp=True -D PMPSIZE=16 \
               -D iwords=4 -D iblocks=16 -D iways=4 -D isets=64 -D paddr=32 -D vaddr=$(XLEN) \
               -D ifbsize=8 -D iesize=3 -D mmu=True -D RV$(XLEN)=True
############# User changes to be done below #################
DIR:=./src/common_bsv/:./src/common_verilog/:./tb/
TOP_DIR:= ./tb/
TOP_FILE:= ./imem_tb.bsv

