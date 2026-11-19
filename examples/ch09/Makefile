# Chapter 9's examples. Most targets compare the Chapter 8 compiler (OLD)
# with the Chapter 9 one (PEBC); several commands fail on purpose, so
# their lines start with '-' and make carries on.
PROJECT = ../../project/ch09
PEBC ?= $(PROJECT)/zig-out/bin/pebc
OLD_PROJECT = ../../project/ch08
OLD ?= $(OLD_PROJECT)/zig-out/bin/pebc
QBE ?= qbe
ZIG ?= zig

all: before after

# Chapter 8's pebc: day.peb is rejected, zero.peb dies at run time.
before: $(OLD)
	-$(OLD) build day.peb
	-$(OLD) build zero.peb && ./zero

# Chapter 9's pebc: day.peb runs, zero.peb is rejected.
after: $(PEBC)
	$(PEBC) build day.peb && ./day
	-$(PEBC) build zero.peb

# demo.peb's IL without and with folding.
ir: $(PEBC)
	$(PEBC) ir demo.peb --no-fold
	$(PEBC) ir demo.peb

# QBE's own constant folding (SCCP) on the unfolded IL.
sccp: $(PEBC)
	$(PEBC) ir demo.peb --no-fold > off.ssa
	$(QBE) -d F off.ssa 2>&1 >/dev/null

# QBE compiles a division by zero without a word.
dz:
	$(QBE) -o dz.s dz.ssa && cc -o dz dz.s
	-./dz

# Chapter 8's pebc crashes on a huge array; Chapter 9's says why it's wrong.
huge: $(OLD) $(PEBC)
	-$(OLD) ir huge.peb 2>&1 | head -4
	-$(PEBC) check huge.peb

# The same function as LLVM IR, unoptimized and optimized, and via QBE.
llvm: $(PEBC)
	$(ZIG) cc -S -emit-llvm -O0 -g0 -fno-sanitize=undefined -fno-discard-value-names -o sum0.ll sum.c
	$(ZIG) cc -S -emit-llvm -O2 -g0 -fno-sanitize=undefined -o sum2.ll sum.c
	sed -n '/^define/,/^}/p' sum0.ll sum2.ll
	$(PEBC) ir sum.peb | $(QBE) | sed -n '/^sum:/,/ret/p'

$(PEBC):
	cd $(PROJECT) && $(ZIG) build

$(OLD):
	cd $(OLD_PROJECT) && $(ZIG) build

# dz.ssa is written by hand: never delete it.
clean:
	rm -f day day.ssa day.s zero zero.ssa zero.s dz dz.s off.ssa sum0.ll sum2.ll

.PHONY: all before after ir sccp dz huge llvm clean
