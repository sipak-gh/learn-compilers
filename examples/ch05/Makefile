# Hand-written QBE IL for Chapter 5. `make` builds the programs that
# compile; `make tr` shows QBE rejecting tr.ssa.
QBE ?= qbe
CC ?= cc
PROGS = wc ty2 signs

all: $(PROGS)

%.s: %.ssa
	$(QBE) -o $@ $<

%: %.s
	$(CC) -o $@ $<

# Keep the .s files: reading them is the point.
.SECONDARY:

clean:
	rm -f $(PROGS) tr $(PROGS:=.s) tr.s

.PHONY: all clean
