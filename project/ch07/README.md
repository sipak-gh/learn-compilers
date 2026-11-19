# pebc — Chapter 7 snapshot

The Pebble compiler at the end of Chapter 7, *Structs and libc*. Pebble now has structs,
`null`, `sizeof(T)` and pointer casts with `as`. That is enough to call `malloc` and
`free`, build linked lists on the heap, and write the two classic demos in `samples/`:
Conway's Game of Life and a Mandelbrot renderer.

```
extern fn printf(format: *u8, ...) i32;
extern fn malloc(size: i64) *u8;

struct Node {
    value: i64,
    next: *Node,
}

fn push(head: *Node, value: i64) *Node {
    let node = malloc(sizeof(Node)) as *Node;
    node.value = value;
    node.next = head;
    return node;
}

fn main() {
    var list: *Node = null;
    var i = 1;
    while i <= 5 {
        list = push(list, i);
        i = i + 1;
    }
    while list != null {
        printf("%ld ", list.value);
        list = list.next;
    }
    printf("\n");
}
```

## Build and test

Requires Zig 0.17.1, QBE 1.2 (`qbe` on `PATH`) and a C compiler (`cc`).

```sh
zig build                                   # builds zig-out/bin/pebc
zig build test                              # unit tests + golden tests
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
| `tests/golden.zig` | the golden runner: `tests/run`, `tests/errors`, `tests/ast` |

## What changed since Chapter 6

- `struct Name { field: Type, ... }` declares a struct at the top level. Fields are laid
  out like C: each at the next offset that is a multiple of its alignment, and the size
  rounded up to the struct's alignment. Structs may be declared in any order and may
  point to themselves (`next: *Node`), but may not contain themselves.
- `s.f` reads or writes a field. On a pointer to a struct, `p.f` follows the pointer
  first (there is no `->`).
- A struct is a value: `var b = a;` and `*heap = a;` copy all of it with QBE's `blit`.
  `var s: S;` starts at zero. Structs can't be compared with `==`, passed to functions
  or returned; pass a pointer instead.
- `null` is the zero pointer; its type comes from the context (`var p: *Node = null;`).
- `sizeof(T)` is the size of a type in bytes, an `i64` worked out by the checker.
- `as` converts between pointer types and between pointers and `i64`, as in
  `malloc(sizeof(Node)) as *Node`.
- The checker runs in four passes: declare struct names, lay structs out, declare
  functions and globals, check function bodies.
- New tests: `run/structs`, `run/list`, `run/life`, `run/mandelbrot`, `errors/structs`,
  `ast/structs`, and a struct layout unit test in `check.zig`. New samples: `life.peb`
  (a Gosper glider gun on a 64×40 torus) and `mandelbrot.peb` (writes a 600×400 PPM
  image to standard output).
