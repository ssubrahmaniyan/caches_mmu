### Makefile for the devices

include Makefile.inc

BSVBUILDDIR:=./build/
VERILOGDIR:=./verilog/
BSVINCDIR:= .:%/Libraries:$(DIR)
BSVOUTDIR:=./bin
BSC_DIR:=$(shell which bsc)
BSC_VDIR:=$(subst bin/bsc,bin/,${BSC_DIR})../lib/Verilog

define_macros += -D Addr_space=25
ifeq ($(ECC_TEST), enable)
	override define_macros += -D ecc_test
endif
ifeq ($(ECC), enable)
	override define_macros += -D icache_ecc
endif
ifeq ($(ATOMIC), enable)
  override define_macros += -D atomic=True
endif
ifeq ($(ICACHE), enable)
  override define_macros += -D icache=True
endif

ifneq ($(SUPERVISOR),  none)
  override define_macros += -D supervisor=True -D $(SUPERVISOR) -D perfmonitors
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
ifneq ($(PMPSIZE) , 0)
  override define_macros += -D pmp -D pmpsize=$(PMPSIZE)
endif

override define_macros += -D ASSERT=True -D iwords=$(IWORDS) -D iblocks=$(IBLOCKS) -D iways=$(IWAYS) \
								-D isets=$(ISETS) -D irepl=$(IREPL) -D icachereset=$(IRESET)\
								-D ifbsize=$(IFBSIZE)\
								-D iesize=$(IESIZE) -D itbanks=$(ITBANKS) \
								-D paddr=32 -D vaddr=$(XLEN) -D RV$(XLEN)=True -D asidwidth=$(ASIDWIDTH) \
								-D simulate=True -D itlbsize=$(ITLBSIZE) -D causesize=6 \
								-D ibuswidth=$(IBUSWIDTH) -D pmp_grainbits=$(GRAINBITS)	-D icache_onehot=$(ONE_HOT)

verilate_fast := OPT_SLOW="-O3" OPT_FAST="-O3"
VERILATOR_FLAGS = --stats -O3 -CFLAGS -O3 -LDFLAGS "-static" --x-assign fast --x-initial fast \
--noassert --cc $(TOP_MODULE).v sim_main.cpp --bbox-sys -Wno-STMTDLY -Wno-UNOPTFLAT -Wno-WIDTH \
-Wno-lint -Wno-COMBDLY -Wno-INITIALDLY --autoflush $(coverage) $(trace) --threads $(THREADS) \
-DBSV_RESET_FIFO_HEAD -DBSV_RESET_FIFO_ARRAY -DVERBOSE --output-split 20000 --output-split-ctrace 10000

VCS_MACROS = +define+BSV_RESET_FIFO_HEAD=True +define+BSV_RESET_FIFO_ARRAY=True +define+BSV_ASYNC_RESET +define+VERBOSE

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
	bsc -u -verilog -elab -vdir $(VERILOGDIR) -bdir $(BSVBUILDDIR) -info-dir $(BSVBUILDDIR) \
		+RTS -K40000M -RTS -check-assert  -keep-fires -opt-undetermined-vals -remove-false-rules \
		-remove-empty-rules -remove-starved-rules -remove-dollar -unspecified-to X -show-schedule \
		-show-module-use $(define_macros) -D verilog=True $(BSVCOMPILEOPTS) \
		-p $(BSVINCDIR) -g $(TOP_MODULE) $(TOP_DIR)/$(TOP_FILE)  || (echo "BSC COMPILE ERROR"; exit 1) 
	@echo "old_define_macros = $(define_macros)" > vars
	@cp common_verilog/*.v $(VERILOGDIR)
	@cp ${BSC_VDIR}/../Verilog.Vivado/RegFile.v $(VERILOGDIR)  
	@cp ${BSC_VDIR}/FIFO2.v $(VERILOGDIR)
	@cp ${BSC_VDIR}/FIFO1.v $(VERILOGDIR)
	@cp ${BSC_VDIR}/FIFO10.v $(VERILOGDIR)
	@cp ${BSC_VDIR}/RevertReg.v $(VERILOGDIR)
	@cp ${BSC_VDIR}/FIFO20.v $(VERILOGDIR)
	@cp ${BSC_VDIR}/FIFOL1.v $(VERILOGDIR)
	@cp ${BSC_VDIR}/SyncFIFO.v $(VERILOGDIR)
	@cp ${BSC_VDIR}/Counter.v $(VERILOGDIR)
	@cp ${BSC_VDIR}/SizedFIFO.v $(VERILOGDIR)
	@cp ${BSC_VDIR}/RegFileLoad.v $(VERILOGDIR)

.PHONY: link_vcs
link_vcs: ## Generate simulation executable using Synopsys VCS
	@rm -rf $(BSVOUTDIR)
	@mkdir -p $(BSVOUTDIR)
	vcs -gui -LDFLAGS -Wl,--no-as-needed -l vcs_compile.log -sverilog +vpi +v2k -lca +define+TOP=$(TOP_MODULE) $(VCS_MACROS) \
	+define+BSV_TIMESCALE=1ns/1ps +cli+4 +libext+.v +notimingcheck \
	-y $(VERILOGDIR)/ -y common_verilog/ \
	${BLUESPECDIR}/Verilog/main.v -o out
	@mv csrc out* $(BSVOUTDIR)

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

