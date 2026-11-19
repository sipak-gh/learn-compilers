# pebc — Chapter 3 snapshot

The Pebble compiler at the end of Chapter 3, *Parsing Expressions*. A precedence-climbing
(Pratt) parser builds a syntax tree in an arena, `pebc ast` prints it as an S-expression,
and a separate code generator walks the tree to produce QBE IL. A program is still one
expression; the parser knows the whole expression grammar (calls, indexing, fields,
pointers), but the code generator only handles integers, characters, booleans,
arithmetic, comparisons, `-` and `!`.

## Build and test

Requires Zig 0.17.1, QBE 1.2 (`qbe` on `PATH`) and a C compiler (`cc`).

```sh
zig build                      # builds zig-out/bin/pebc
zig build test                 # unit tests + golden tests (tests/run, tests/errors, tests/ast)
zig build demo                 # compiles and runs samples/answer.peb
```

## Run

```sh
zig-out/bin/pebc ast tests/ast/logic.peb    # (|| a (&& b (== c (+ d (* e f)))))
zig-out/bin/pebc ir tests/run/compare.peb
zig-out/bin/pebc build samples/answer.peb -o answer && ./answer
```

## Files

| File | What it does |
|---|---|
| `src/main.zig` | command line: `tokens`, `ast`, `ir`, `build` |
| `src/diag.zig` | spans, line:col, diagnostics with carets |
| `src/lexer.zig` | tokens |
| `src/ast.zig` | the syntax tree: `Expr`, `UnaryOp`, `BinaryOp` |
| `src/parser.zig` | the Pratt parser |
| `src/print.zig` | S-expression printer |
| `src/codegen.zig` | syntax tree → QBE IL |
| `src/driver.zig` | runs `qbe` and `cc` |
| `tests/golden.zig` | the golden runner, now with a third suite: `tests/ast/` |

## What changed since Chapter 2

- `src/compiler.zig` is gone. Parsing (`parser.zig`, `ast.zig`) and code generation
  (`codegen.zig`) are separate phases now.
- New command `pebc ast`; new golden suite `tests/ast/`.
- New operators: comparisons, `&&`, `||`, `!`, prefix `&` and `*`, calls, indexing, fields.
  Chained comparisons (`a < b < c`) are an error with a note.
