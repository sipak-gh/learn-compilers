# pebc — Chapter 4 snapshot

The Pebble compiler at the end of Chapter 4, *Statements and Functions*. Programs are now
real programs: functions, `extern` declarations of libc functions (including variadic ones
like `printf`), `let`/`var`, assignment, `if`/`else`, `while`, `break`, `continue`,
`return`, blocks, string literals and short-circuit `&&`/`||`. Pebble has no types yet:
every value is a 64-bit integer, as in B.

```
extern fn printf(format, ...);

fn fib(n) {
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
zig-out/bin/pebc ast tests/ast/statements.peb
zig-out/bin/pebc ir tests/run/fib.peb
zig-out/bin/pebc build samples/fib.peb -o fib && ./fib
```

## Files

| File | What it does |
|---|---|
| `src/main.zig` | command line: `tokens`, `ast`, `ir`, `build` |
| `src/diag.zig` | spans, line:col, diagnostics with carets |
| `src/lexer.zig` | tokens |
| `src/ast.zig` | the syntax tree: `Program`, `Func`, `Stmt`, `Expr` |
| `src/parser.zig` | declarations and statements (recursive descent), expressions (Pratt), error recovery |
| `src/print.zig` | S-expression printer |
| `src/codegen.zig` | syntax tree → QBE IL: stack slots, labels, calls, string data, name lookup |
| `src/driver.zig` | runs `qbe` and `cc` |
| `tests/golden.zig` | the golden runner: `tests/run`, `tests/errors`, `tests/ast` |

## What changed since Chapter 3

- A program is a list of `fn` and `extern fn` declarations; `main` is required.
- New statements: `let`, `var`, assignment, `if`/`else if`/`else`, `while`, `break`,
  `continue`, `return`, blocks, expression statements.
- After a syntax error the parser skips to the next statement or declaration, so one run
  reports every syntax error.
- The code generator resolves names (scopes, shadowing, `let` is read-only), checks
  argument counts, puts every variable in an `alloc8` slot in the start block, and
  generates control flow with labels and `jnz`/`jmp`.
- `&&` and `||` short-circuit.
- All golden tests are now whole programs that print with `printf`.
