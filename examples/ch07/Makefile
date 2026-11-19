# Runs Chapter 7's pebc on rect.peb. `make` prints the IL, `make run` builds
# and runs the program, `make asm` shows what QBE made of it.
PROJECT = ../../project/ch07
PEBC ?= $(PROJECT)/zig-out/bin/pebc

all: ir

ir: $(PEBC)
	$(PEBC) ir rect.peb

# pebc build leaves rect.ssa and rect.s next to rect, so you can read them.
rect: rect.peb $(PEBC)
	$(PEBC) build rect.peb

run: rect
	./rect

asm: rect
	cat rect.s

$(PEBC):
	cd $(PROJECT) && zig build

clean:
	rm -f rect rect.ssa rect.s

.PHONY: all ir run asm clean
