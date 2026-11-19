# pebc — Chapter 5 snapshot

The Pebble compiler at the end of Chapter 5, *Names and Types*. Pebble now has types:
`i64`, `i32`, `u8`, `bool` and pointer types such as `*u8` (the type of a string literal).
A new phase, the checker, sits between the parser and the code generator. It resolves
every name, works out the type of every expression, and reports type errors. The code
generator trusts its results and picks QBE instructions by type.

```
extern fn printf(format: *u8, ...) i32;

fn fib(n: i64) i64 {
    if n < 2 {
        return n;
    }
    return fib(n - 1) + fib(n - 2);
}

fn main() {
    var i = 0;
    while i < 20 {
        printf("fib(%ld) = %ld\n", i, fib(i));
        i = i + 1;
    }
}
```

## Build and test

Requires Zig 0.17.1, QBE 1.2 (`qbe` on `PATH`) and a C compiler (`cc`).

```sh
zig build                                   # builds zig-out/bin/pebc
zig build test                              # unit tests + golden tests
zig build demo -Dsample=samples/fib.peb     # compiles and runs a sample
```

## Run

```sh
zig-out/bin/pebc check tests/errors/types.peb
zig-out/bin/pebc ir tests/run/types.peb
zig-out/bin/pebc build samples/fib.peb -o fib && ./fib
```

## Files

| File | What it does |
|---|---|
| `src/main.zig` | command line: `tokens`, `ast`, `check`, `ir`, `build` |
| `src/diag.zig` | spans, line:col, diagnostics with carets |
| `src/lexer.zig` | tokens |
| `src/ast.zig` | the syntax tree, type expressions, symbols |
| `src/types.zig` | Pebble's types: size, QBE base type, which values fit |
| `src/parser.zig` | declarations and statements (recursive descent), expressions (Pratt), error recovery |
| `src/print.zig` | S-expression printer |
| `src/check.zig` | names, types, returns, loops, `main` |
| `src/codegen.zig` | checked syntax tree → QBE IL, chosen by type |
| `src/driver.zig` | runs `qbe` and `cc` |
| `tests/golden.zig` | the golden runner: `tests/run`, `tests/errors`, `tests/ast` |

## What changed since Chapter 4

- Parameters, `let`/`var` and return types can be written: `fn f(a: i64, s: *u8) i32`,
  `let b: u8 = 200;`. With no return type a function returns nothing.
- `x as T` converts between integer types and from `bool` to an integer.
- `src/check.zig` does all name resolution (moved from the code generator) and type
  checking. An integer literal takes the type its context expects, so `let b: u8 = 200;`
  needs no cast. Conditions must be `bool`. A function with a return type must return on
  every path. `main` returns `i32` or nothing.
- An expression with an error gets the type `invalid`, which every later check accepts
  silently: one mistake produces one message.
- The code generator uses `w` for `i32`, `u8` and `bool` and `l` for `i64` and pointers.
  It sizes stack slots by type (`storeb`/`loadub` for `u8`), cuts `u8` results back to
  8 bits with `and 255`, and uses unsigned division and comparisons for `u8`.
- `pebc check FILE` reports errors without compiling.
