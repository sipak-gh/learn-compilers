# Runs Chapter 2's pebc on the example files. Most of them contain errors on
# purpose, so a failing pebc does not stop make (the leading '-').
PROJECT = ../../project/ch02
PEBC ?= $(PROJECT)/zig-out/bin/pebc

EXAMPLES = tokens u1 u2 u3 u4 tab

all: $(EXAMPLES)

$(EXAMPLES): $(PEBC)
	-$(PEBC) tokens $@.peb

# u4 lexes fine; the bad number is found when the compiler reads it.
u4-ir: $(PEBC)
	-$(PEBC) ir u4.peb

$(PEBC):
	cd $(PROJECT) && zig build

.PHONY: all $(EXAMPLES) u4-ir
