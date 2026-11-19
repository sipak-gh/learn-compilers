# Looks inside QBE with Chapter 8's pebc. `make dump` shows the IL after
# slot promotion (M), after SSA construction (N) and the register mappings
# (R); `make asm` shows the final assembly. QBE prints -d dumps to stderr.
PROJECT = ../../project/ch08
PEBC ?= $(PROJECT)/zig-out/bin/pebc
QBE ?= qbe
PASSES ?= MNR

all: dump

sum.ssa: sum.peb $(PEBC)
	$(PEBC) ir sum.peb > sum.ssa

ir: sum.ssa
	cat sum.ssa

dump: sum.ssa
	$(QBE) -d $(PASSES) sum.ssa 2>&1 >/dev/null

asm: sum.ssa
	$(QBE) sum.ssa

$(PEBC):
	cd $(PROJECT) && zig build

clean:
	rm -f sum.ssa

.PHONY: all ir dump asm clean
