# pebc — Chapter 6 snapshot

The Pebble compiler at the end of Chapter 6, *Pointers and Arrays*. Pebble can now take
the address of a variable (`&x`), read and write through a pointer (`*p`), and index
arrays and pointers (`a[i]`). Arrays have fixed sizes such as `[100]bool`. Variables can
also be declared outside functions as global variables.

```
extern fn printf(format: *u8, ...) i32;

var composite: [1000]bool;

fn main() {
    var n = 2;
    while n < 1000 {
        if !composite[n] {
            printf("%ld ", n);
            var m = n * n;
            while m < 1000 {
                composite[m] = true;
                m = m + n;
            }
        }
        n = n + 1;
    }
    printf("\n");
}
```

## Build and test

Requires Zig 0.17.1, QBE 1.2 (`qbe` on `PATH`) and a C compiler (`cc`).

```sh
zig build                                   # builds zig-out/bin/pebc
zig build test                              # unit tests + golden tests
zig build demo -Dsample=samples/sieve.peb   # compiles and runs a sample
```

## Run

```sh
zig-out/bin/pebc check tests/errors/pointers.peb
zig-out/bin/pebc ir tests/run/pointers.peb
zig-out/bin/pebc build samples/strings.peb -o strings && ./strings
```

## Files

| File | What it does |
|---|---|
| `src/main.zig` | command line: `tokens`, `ast`, `check`, `ir`, `build` |
| `src/diag.zig` | spans, line:col, diagnostics with carets |
| `src/lexer.zig` | tokens |
| `src/ast.zig` | the syntax tree, type expressions, symbols |
| `src/types.zig` | Pebble's types: size, alignment, QBE base type, which values fit |
| `src/parser.zig` | declarations and statements (recursive descent), expressions (Pratt), error recovery |
| `src/print.zig` | S-expression printer |
| `src/check.zig` | names, types, places (what can be assigned or pointed to), globals, returns, loops, `main` |
| `src/codegen.zig` | checked syntax tree → QBE IL: addresses, loads and stores, global data |
| `src/driver.zig` | runs `qbe` and `cc` |
| `tests/golden.zig` | the golden runner: `tests/run`, `tests/errors`, `tests/ast` |

## What changed since Chapter 5

- Types can be arrays: `[10]i64`, `[3][4]u8`. An array has no value of its own: it can't
  be assigned, passed, returned or copied as a whole, only indexed or pointed into with
  `&a[0]`.
- `&x` takes the address of a `var`, an array element or `*p`. `*p` reads or writes
  through a pointer. `a[i]` indexes an array or a pointer; the index can be any integer
  type. There is no pointer arithmetic: write `&p[i]`.
- `var x: T;` without a value starts at zero (arrays through `memset`). A `let` still
  needs a value.
- `var`/`let` outside a function declares a global variable. Its value must be a
  constant (an integer, character, `true`/`false` or string); it becomes QBE `data`.
  Globals and functions share one namespace.
- The code generator has one new idea, `genAddr`: the address of a variable, `*p` or
  `a[i]`. Reading loads from that address; assigning stores to it. Stack slots are
  aligned for their type (`alloc4`, `alloc8`).
- New tests: `run/pointers`, `run/arrays`, `run/globals`, `run/strings`, `run/sieve`,
  `errors/pointers` (replaces `errors/pointer`), `ast/pointers`. New samples:
  `sieve.peb`, `strings.peb`.
