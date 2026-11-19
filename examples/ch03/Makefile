# Chapter 3 examples. `make` builds Chapter 3's pebc, prints the syntax tree
# of every .peb file here, then compiles and runs chain.c (C's chained
# comparisons). `make clean` removes the C program.
PROJECT := ../../project/ch03
PEBC    := $(PROJECT)/zig-out/bin/pebc
PEBS    := $(sort $(wildcard *.peb))

.PHONY: all pebc trees clean
all: trees chain
	./chain

pebc:
	cd $(PROJECT) && zig build

# pebc exits with 1 on the files that have errors; keep going.
trees: pebc
	@for f in $(PEBS); do echo "--- $$f: $$(cat $$f)"; $(PEBC) ast $$f || true; done

chain: chain.c
	gcc -std=c11 -Wall -Wextra -o $@ $<

clean:
	rm -f chain
