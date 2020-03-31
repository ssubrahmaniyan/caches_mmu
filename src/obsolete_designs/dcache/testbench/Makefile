### Makefile for the devices

include Makefile.inc

BSVBUILDDIR:=./build/
VERILOGDIR:=./verilog/
BSVINCDIR:= .:%/Prelude:%/Libraries:%/Libraries/BlueNoC:$(DIR)
BSVOUTDIR:=./bin

define_macros += -D Addr_space=25
ifeq ($(ECC_TEST), enable)
	override define_macros += -D ecc_test
endif
ifeq ($(ECC), enable)
	override define_macros += -D ECC
endif
ifeq ($(ATOMIC), enable)
  override define_macros += -D atomic=True
endif
ifeq ($(DCACHE), enable)
  override define_macros += -D dcache=True
endif

ifneq ($(SUPERVISOR),  none)
  override define_macros += -D supervisor=True -D $(SUPERVISOR)
endif
ifeq ($(COVERAGE), none)
else ifeq ($(COVERAGE),all)
  coverage := --coverage
else
  coverage := --coverage-$(COVERAGE)
endif

ifeq ($(TRACE), enable)
  trace := --trace
endif

override define_macros += -D ASSERT=True -D dwords=$(DWORDS) -D dblocks=$(DBLOCKS) -D dways=$(DWAYS) \
								-D dsets=$(DSETS) -D dfbsize=$(DFBSIZE) -D drepl=$(DREPL) -D dcachereset=$(DRESET) \
								-D desize=$(DESIZE) -D ddbanks=$(DDBANKS) -D dtbanks=$(DTBANKS) -D dsbsize=$(DSBSIZE)\
								-D paddr=32 -D vaddr=$(XLEN) -D RV$(XLEN)=True -D asidwidth=$(ASIDWIDTH) \
								-D simulate=True -D dtlbsize=$(DTLBSIZE) -D causesize=6 \
								-D dbuswidth=$(XLEN)

ifeq (, $(wildcard ${TOOLS_DIR}/shakti-tools/insert_license.sh))
    VERILOG_FILTER:= -verilog-filter ${BLUESPECDIR}/bin/basicinout \
									 -verilog-filter ./rename_translate.sh
else
    VERILOG_FILTER:= -verilog-filter ${BLUESPECDIR}/bin/basicinout \
									 -verilog-filter ${TOOLS_DIR}/shakti-tools/insert_license.sh \
									 -verilog-filter ./rename_translate.sh
  VERILOGLICENSE:= cp ${TOOLS_DIR}/shakti-tools/IITM_LICENSE.txt ./verilog
endif

verilate_fast := OPT_SLOW="-O3" OPT_FAST="-O3"
VERILATOR_FLAGS = --stats -O3 -CFLAGS -O3 -LDFLAGS "-static" --x-assign fast --x-initial fast \
--noassert --cc $(TOP_MODULE).v sim_main.cpp --bbox-sys -Wno-STMTDLY -Wno-UNOPTFLAT -Wno-WIDTH \
-Wno-lint -Wno-COMBDLY -Wno-INITIALDLY --autoflush $(coverage) $(trace) --threads $(THREADS) \
-DBSV_RESET_FIFO_HEAD -DBSV_RESET_FIFO_ARRAY --output-split 20000 --output-split-ctrace 10000

BSC_CMD:= bsc -u -verilog -elab
BSVCOMPILEOPTS:= +RTS -K40000M -RTS -check-assert  -keep-fires -opt-undetermined-vals \
									$(suppresswarn) -remove-false-rules -remove-empty-rules -remove-starved-rules \
									-remove-dollar -unspecified-to X -show-schedule -show-module-use

define presim_config
	python3 gen_test.py
endef
default: generate_verilog link_verilator simulate

.PHONY: compile
compile:
	@echo Compiling $(TOP_MODULE)....
	@mkdir -p $(BSVBUILDDIR)
	@bsc -u -sim -simdir $(BSVBUILDDIR) -bdir $(BSVBUILDDIR) -info-dir $(BSVBUILDDIR) -keep-fires \
	-suppress-warnings S0015 -check-assert $(define_macros) -p $(BSVINCDIR) -g $(TOP_MODULE)  \
	$(TOP_DIR)/$(TOP_FILE) 
	@echo Compilation finished

.PHONY: link
link:
	@echo Linking $(TOP_MODULE)...
	@mkdir -p bin
	@bsc -e $(TOP_MODULE) -sim -o ./bin/out -simdir $(BSVBUILDDIR) -p .:%/Prelude:%/Libraries:%/Libraries/BlueNoC -keep-fires -bdir $(BSVBUILDDIR) -keep-fires  
	@echo Linking finished

.PHONY: generate_verilog 
generate_verilog:
	@echo Compiling $(TOP_MODULE) in verilog ...
	@mkdir -p $(BSVBUILDDIR); 
	@mkdir -p $(VERILOGDIR); 
	$(BSC_CMD) -suppress-warnings S0015 -vdir $(VERILOGDIR) -bdir $(BSVBUILDDIR) -info-dir $(BSVBUILDDIR)\
  $(define_macros) $(BSVCOMPILEOPTS) $(VERILOG_FILTER) \
  -p $(BSVINCDIR) -g $(TOP_MODULE) $(TOP_DIR)/$(TOP_FILE)  || (echo "BSC COMPILE ERROR"; exit 1) 
	@echo "old_define_macros = $(define_macros)" > vars
	@cp ${BLUESPECDIR}/Verilog.Vivado/RegFile.v ./verilog/  
	@cp ${BLUESPECDIR}/Verilog.Vivado/BRAM2BELoad.v ./verilog/
	@cp ${BLUESPECDIR}/Verilog.Vivado/BRAM2BE.v ./verilog/
	@cp ${BLUESPECDIR}/Verilog.Vivado/BRAM2.v ./verilog/
	@cp ${BLUESPECDIR}/Verilog/FIFO2.v ./verilog/
	@cp ${BLUESPECDIR}/Verilog/FIFO1.v ./verilog/
	@cp ${BLUESPECDIR}/Verilog/FIFO10.v ./verilog/
	@cp ${BLUESPECDIR}/Verilog/RevertReg.v ./verilog/
	@cp ${BLUESPECDIR}/Verilog/FIFO20.v ./verilog/
	@cp ${BLUESPECDIR}/Verilog/FIFOL1.v ./verilog/
	@cp ${BLUESPECDIR}/Verilog/SyncFIFO.v ./verilog/
	@cp ${BLUESPECDIR}/Verilog/Counter.v ./verilog/
	@cp ${BLUESPECDIR}/Verilog/SizedFIFO.v ./verilog/
	@cp ${BLUESPECDIR}/Verilog/RegFileLoad.v ./verilog/
	@$(VERILOGLICENSE)

.PHONY: link_verilator
link_verilator: 
	@echo "Linking $(TOP_MODULE) using verilator"
	@mkdir -p $(BSVOUTDIR) obj_dir
	@echo "#define TOPMODULE V$(TOP_MODULE)" > sim_main.h
	@echo '#include "V$(TOP_MODULE).h"' >> sim_main.h
	verilator $(VERILATOR_FLAGS) -y $(VERILOGDIR) -y common_verilog/ --exe
	@ln -f -s ../sim_main.cpp obj_dir/sim_main.cpp
	@ln -f -s ../sim_main.h obj_dir/sim_main.h
	make $(verilate_fast) VM_PARALLEL_BUILDS=1 -j8 -C obj_dir -f V$(TOP_MODULE).mk
	@cp obj_dir/V$(TOP_MODULE) bin/out

.PHONY: simulate
simulate:
	@echo Simulation...
	$(call presim_config)
	@exec ./$(BSVOUTDIR)/out
	@echo Simulation finished

.PHONY: clean
clean:
	rm -rf build bin *.jou *.log test.mem  log verilog fpga obj_dir sim_main.h vars data.mem

