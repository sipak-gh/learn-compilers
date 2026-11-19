# pebc — Chapter 9 snapshot

The Pebble compiler at the end of Chapter 9, *Constant Folding and Where to Go Next*: the
finished compiler of the course. New in this chapter is a pass between the checker and
the code generator, `src/fold.zig`, which works out the value of every constant
expression while compiling:

- `60 * 60 * 24` becomes `86400`, `-1 as u8` becomes `255`, and `false && f()` becomes
  `false` without a call, with exactly the wrapping arithmetic the program would do.
- A global variable's value can be any constant expression, not just a literal.
- An `if` or `while` whose condition is always true or always false compiles only the
  code that can run.
- Division by a constant zero, a constant index outside an array and `MIN / -1` are
  compile-time errors.
- `pebc --no-fold` turns the folded values off in the code generator, so the tests can
  check both ways.

## Build and test

Requires Zig 0.17.1, QBE 1.2 (`qbe` on `PATH`) and a C compiler (`cc`).

```sh
zig build                                   # builds zig-out/bin/pebc
zig build test                              # unit tests + golden tests
zig build test -Dno-fold                    # the same, with pebc --no-fold
zig build test -Dfilter=structs             # only the golden tests whose path has "structs"
zig build test -Dupdate                     # rewrite the golden files (review the diff!)
zig build test --fuzz=100K                  # fuzz the compiler for 100,000 runs
zig build difftest                          # 100 random programs, pebc vs cc
zig build difftest -Dno-fold                # the same, with pebc --no-fold
zig build difftest -Dseed=7 -Dcount=1 -Dkeep  # one program, kept in .zig-cache
zig build demo -Dsample=samples/life.peb    # compiles and runs a sample
```

## Run

```sh
zig-out/bin/pebc check tests/errors/structs.peb
zig-out/bin/pebc ir tests/run/structs.peb
zig-out/bin/pebc ir tests/run/fold.peb --no-fold
zig-out/bin/pebc build samples/mandelbrot.peb -o mandelbrot && ./mandelbrot > mandelbrot.ppm
```

## Files

| File | What it does |
|---|---|
| `src/main.zig` | command line: `tokens`, `ast`, `check`, `ir`, `build`, `--no-fold` |
| `src/diag.zig` | spans, line:col, diagnostics with carets |
| `src/lexer.zig` | tokens |
| `src/ast.zig` | the syntax tree, type expressions, symbols |
| `src/types.zig` | Pebble's types: size, alignment, QBE base type, which values fit, struct layouts |
| `src/parser.zig` | declarations (functions, globals, structs) and statements (recursive descent), expressions (Pratt), error recovery |
| `src/print.zig` | S-expression printer |
| `src/check.zig` | struct layout, names, types, places (what can be assigned or pointed to), globals, returns, loops, `main` |
| `src/fold.zig` | constant folding: the value of every constant expression, wrapping like the machine; division by zero, constant indexes |
| `src/codegen.zig` | checked syntax tree → QBE IL: addresses, loads and stores, field offsets, `blit` copies, global data, folded values, dead branches |
| `src/driver.zig` | runs `qbe` and `cc` |
| `src/fuzz.zig` | the fuzz test: random bytes or random tokens through every phase |
| `tests/golden.zig` | the golden runner: `tests/run`, `tests/errors`, `tests/ast`; line diffs, `--update`, `--filter`, `--no-fold`, timeouts |
| `tests/difftest.zig` | the differential tester: a random program generator that writes Pebble and C |

## What changed since Chapter 8

- `src/fold.zig` (new): `Folder.foldProgram` walks the checked tree and sets
  `Expr.value` (new in `src/ast.zig`) for every expression whose value is known: literals,
  `-`, `!`, arithmetic, comparisons, `&&`, `||` and `as` of known values. Arithmetic
  wraps in the operand's type (`castInt`, moved here from `codegen.zig`); `/` and `%`
  round toward zero. It reports `division by zero`, `index N is out of bounds for
  '[L]T'` and `MIN / -1 overflows 'T'`. Unit tests check the values.
- `src/main.zig`: the folder always runs after the checker (also for `pebc check`);
  `--no-fold` tells the code generator not to use its values.
- `src/codegen.zig`: a known value is emitted as a number; `if` with a known condition
  compiles one branch; `while false` compiles nothing and `while true` has no test;
  `true && x` and `false || x` are just `x`. Global data always uses the folded values,
  even with `--no-fold`.
- `src/check.zig`: `isConstant` accepts arithmetic, comparisons, `!`, `-` and `as` of
  constants, so `let seconds_per_day = 60 * 60 * 24;` is a valid global.
- `src/types.zig` and `src/check.zig`: a type may be at most `Type.max_size` bytes
  (2 GiB); `'[9223372036854775807]i64' is too large` used to crash pebc with an integer
  overflow in `Type.size`. Found while extending array lengths in an exercise; neither
  the fuzzer nor difftest had found it.
- `src/fuzz.zig` runs the folder too.
- `tests/golden.zig` and `tests/difftest.zig` take `--no-fold` (`-Dno-fold`), which they
  pass to pebc. New golden tests: `run/fold`, `errors/fold` and `errors/sizes`.
