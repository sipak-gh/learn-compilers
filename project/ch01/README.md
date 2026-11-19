# pebc — Chapter 1 snapshot

The Pebble compiler at the end of Chapter 1, *A Compiler in One Afternoon*. It reads a
file holding one integer expression and compiles it, in a single pass, into a QBE program
that prints the value. `qbe` turns that into x86-64 assembly and `cc` links it with libc.

## Build and test

Requires Zig 0.17.1, QBE 1.2 (`qbe` on `PATH`) and a C compiler (`cc`).

```sh
zig build                      # builds zig-out/bin/pebc
zig build test                 # unit tests + golden tests in tests/run/
zig build demo                 # compiles and runs samples/answer.peb
```

## Run

```sh
zig-out/bin/pebc ir samples/answer.peb             # print the QBE IL
zig-out/bin/pebc build samples/answer.peb -o answer
./answer                                           # prints 42
```

`pebc build` leaves `answer.ssa` (the IL) and `answer.s` (the assembly) next to the
executable.

## Files

| File | What it does |
|---|---|
| `src/main.zig` | command line: `pebc ir` and `pebc build` |
| `src/compiler.zig` | the one-pass compiler: characters → QBE IL |
| `src/driver.zig` | runs `qbe` and `cc` |
| `tests/golden.zig` | the golden test runner used by `zig build test` |
| `tests/run/` | test programs and their expected output |

## What changed

This is the first snapshot.
