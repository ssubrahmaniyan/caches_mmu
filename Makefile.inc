############ DO NOT CHANGE THESE #################
SUPPORTED:=./src/
TOP_MODULE:=mkdmem
XLEN=64
define_macros:=-D VERBOSITY=2 -D ASSERT=True -D atomic=True -D pmp=True -D PMPSIZE=16 \
               -D iwords=4 -D iblocks=16 -D iways=4 -D isets=64 -D ifbsize=8 -D iesize=3 \
               -D ibanks=1 -D dbanks=1 \
               -D dwords=4 -D dblocks=16 -D dways=4 -D dsets=64 -D dfbsize=8 -D desize=2 -D dsbsize=2\
               -D paddr=32 -D vaddr=$(XLEN) -D mmu=True -D RV$(XLEN)=True -D asidwidth=9
############# User changes to be done below #################
DIR:=./src/common_bsv/:./src/common_verilog/:./tb/
TOP_DIR:= ./src/
TOP_FILE:= ./dmem.bsv

