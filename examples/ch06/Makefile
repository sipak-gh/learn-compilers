# Chapter 6. `make` builds and runs memory.ssa (hand-written QBE IL), then
# prints the IL that Chapter 6's pebc makes from swap.peb. `make run-swap`
# builds swap with pebc and runs it.
QBE ?= qbe
CC ?= cc
PROJECT = ../../project/ch06
PEBC ?= $(PROJECT)/zig-out/bin/pebc

all: run-memory ir

memory.s: memory.ssa
	$(QBE) -o $@ $<

memory: memory.s
	$(CC) -o $@ $<

run-memory: memory
	./memory

ir: $(PEBC)
	$(PEBC) ir swap.peb

# pebc build leaves swap.ssa and swap.s next to swap, so you can read them.
swap: swap.peb $(PEBC)
	$(PEBC) build swap.peb

run-swap: swap
	./swap

$(PEBC):
	cd $(PROJECT) && zig build

clean:
	rm -f memory memory.s swap swap.ssa swap.s

.PHONY: all run-memory ir run-swap clean
