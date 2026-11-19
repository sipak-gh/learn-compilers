# pebc — Chapter 8 snapshot

The Pebble compiler at the end of Chapter 8, *Testing a Compiler*. The language is the
same as in Chapter 7; what is new is the ways of finding the compiler's bugs:

- **Golden tests** now print a line diff when they fail, can be filtered, are rewritten
  with `-Dupdate`, and stop a program that runs for more than 10 seconds or prints more
  than 1 MiB.
- **Fuzzing** (`src/fuzz.zig`): Zig's built-in fuzzer feeds the compiler random bytes and
  random token sequences, looking for a crash.
- **Differential testing** (`tests/difftest.zig`): random programs, generated in Pebble
  and in C at the same time, compiled with pebc and with `cc`; their output must match.

## Build and test

Requires Zig 0.17.1, QBE 1.2 (`qbe` on `PATH`) and a C compiler (`cc`).

```sh
zig build                                   # builds zig-out/bin/pebc
zig build test                              # unit tests + golden tests
zig build test -Dfilter=structs             # only the golden tests whose path has "structs"
zig build test -Dupdate                     # rewrite the golden files (review the diff!)
zig build test --fuzz=100K                  # fuzz the compiler for 100,000 runs
zig build difftest                          # 100 random programs, pebc vs cc
zig build difftest -Dseed=7 -Dcount=1 -Dkeep  # one program, kept in .zig-cache
zig build demo -Dsample=samples/life.peb    # compiles and runs a sample
```

## Run

```sh
zig-out/bin/pebc check tests/errors/structs.peb
zig-out/bin/pebc ir tests/run/structs.peb
zig-out/bin/pebc build samples/mandelbrot.peb -o mandelbrot && ./mandelbrot > mandelbrot.ppm
```

## Files

| File | What it does |
|---|---|
| `src/main.zig` | command line: `tokens`, `ast`, `check`, `ir`, `build` |
| `src/diag.zig` | spans, line:col, diagnostics with carets |
| `src/lexer.zig` | tokens |
| `src/ast.zig` | the syntax tree, type expressions, symbols |
| `src/types.zig` | Pebble's types: size, alignment, QBE base type, which values fit, struct layouts |
| `src/parser.zig` | declarations (functions, globals, structs) and statements (recursive descent), expressions (Pratt), error recovery |
| `src/print.zig` | S-expression printer |
| `src/check.zig` | struct layout, names, types, places (what can be assigned or pointed to), globals, returns, loops, `main` |
| `src/codegen.zig` | checked syntax tree → QBE IL: addresses, loads and stores, field offsets, `blit` copies, global data |
| `src/driver.zig` | runs `qbe` and `cc` |
| `src/fuzz.zig` | the fuzz test: random bytes or random tokens through every phase |
| `tests/golden.zig` | the golden runner: `tests/run`, `tests/errors`, `tests/ast`; line diffs, `--update`, `--filter`, timeouts |
| `tests/difftest.zig` | the differential tester: a random program generator that writes Pebble and C |

## What changed since Chapter 7

- `tests/golden.zig`: a failing test prints a line diff (`-` expected, `+` actual) with two
  lines of context instead of both outputs. A missing golden file is a failure, not a
  crash. `--update` (`-Dupdate`) writes the actual output into the golden files;
  `--filter TEXT` (`-Dfilter=TEXT`) runs only matching tests. A test program is stopped
  after 10 seconds or 1 MiB of output.
- `src/fuzz.zig`: a fuzz test, run once on an empty input by `zig build test` and for real
  by `zig build test --fuzz=N`. The unit tests are built with the LLVM backend
  (`.use_llvm = true`), which Zig's fuzzer needs for its coverage instrumentation.
- `src/diag.zig`: after 20 errors (`max_errors`, like Clang), further errors are counted
  but not kept: "garbage.peb: 1737 more errors not shown". 4 KB of random bytes
  produce 1757 errors; with all of them kept and printed, `zig build test --fuzz=20K`
  took 96 seconds instead of 20.
- `tests/difftest.zig` and `zig build difftest`: generates programs with `i64`, `i32` and
  `u8` arithmetic, casts, comparisons, `if`/`else`, nested `while` loops with `break` and
  `continue`, and functions; runs the Pebble and C versions; reports any difference.
  `-Dseed`, `-Dcount` and `-Dkeep` control it.
- New tests: `run/loops` (`break` and `continue` in an inner loop: no test covered that),
  a lexer test for a backslash at the end of the file, and a `max_errors` test in
  `diag.zig`.
- `lexer.Token.Tag.lexeme` is now public, for the fuzzer's token list.
