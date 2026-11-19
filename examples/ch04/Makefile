# Chapter 4 examples.
#   make           compile the hand-written jnz.ssa with qbe and cc, and run it
#   make alloc     show the assembly QBE makes for an alloc8 inside a loop
#   make run-big   compile big.peb with Chapter 4's pebc and run it
#   make cascade   show pebc's errors for cascade.peb
#   make status    compile status.peb with pebc and print its exit status
#   make clean     remove everything the targets build
QBE ?= qbe
CC ?= cc
PROJECT := ../../project/ch04
PEBC := $(PROJECT)/zig-out/bin/pebc

# jnz exits with status 7 on purpose; print it instead of failing.
all: jnz
	./jnz; echo "exit $$?"

jnz.s: jnz.ssa
	$(QBE) -o $@ $<

jnz: jnz.s
	$(CC) -o $@ $<

alloc:
	$(QBE) alloc.ssa | sed -n '/^main:/,/end function/p'

pebc:
	cd $(PROJECT) && zig build

# pebc build leaves big.ssa and big.s next to big, so you can read them.
run-big: pebc big.peb
	$(PEBC) build big.peb -o big
	./big

# pebc exits with status 1 here, as it should.
cascade: pebc
	-$(PEBC) ir cascade.peb

status: pebc
	$(PEBC) build status.peb -o status
	./status; echo "exit $$?"

clean:
	rm -f jnz jnz.s nolabel.ssa big big.ssa big.s status status.ssa status.s

.PHONY: all alloc pebc run-big cascade status clean
