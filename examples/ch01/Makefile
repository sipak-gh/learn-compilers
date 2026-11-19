# Hand-written QBE IL: qbe turns X.ssa into X.s, cc assembles X.s and links it with libc.
QBE ?= qbe
CC ?= cc

# t1.ssa is left out on purpose: qbe rejects it (see the chapter).
PROGRAMS = hello fact t2 t3

all: $(PROGRAMS)

%.s: %.ssa
	$(QBE) -o $@ $<

%: %.s
	$(CC) -o $@ $<

run: hello fact
	./hello
	./fact

clean:
	rm -f $(PROGRAMS) *.s

# Keep the .s files so you can read them.
.SECONDARY:
.PHONY: all run clean
