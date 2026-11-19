# pebc — Chapter 2 snapshot

The Pebble compiler at the end of Chapter 2, *Lexing*. A lexer now turns the source into
tokens with spans, and errors are reported with the file, line, column, and a caret under
the offending code. The compiler is still one pass over a single integer expression.

## Build and test

Requires Zig 0.17.1, QBE 1.2 (`qbe` on `PATH`) and a C compiler (`cc`).

```sh
zig build                      # builds zig-out/bin/pebc
zig build test                 # unit tests + golden tests in tests/run/ and tests/errors/
zig build demo                 # compiles and runs samples/answer.peb
```

## Run

```sh
zig-out/bin/pebc tokens samples/answer.peb         # one token per line
zig-out/bin/pebc ir samples/answer.peb             # print the QBE IL
zig-out/bin/pebc build samples/answer.peb -o answer && ./answer
```

## Files

| File | What it does |
|---|---|
| `src/main.zig` | command line: `pebc tokens`, `pebc ir`, `pebc build` |
| `src/diag.zig` | `Span`, `Source` (offset → line:col), `Diagnostics` with caret rendering |
| `src/lexer.zig` | `Token`, `Lexer`, `tokenize`, literal decoding |
| `src/compiler.zig` | the one-pass compiler, now reading tokens |
| `src/driver.zig` | runs `qbe` and `cc` |
| `tests/golden.zig` | the golden test runner |
| `tests/run/`, `tests/errors/` | programs with expected output / expected error messages |

## What changed since Chapter 1

- New `src/diag.zig` and `src/lexer.zig`; the lexer knows every token of the final language.
- `src/compiler.zig` reads tokens and reports errors as diagnostics.
- New command `pebc tokens`.
- The golden runner has a second suite, `tests/errors/`, and runs pebc inside `tests/`.
