# Appendix A — Cheat Sheet

The course on a few pages: the commands of `pebc` and its build, Pebble's grammar, types and
rules, the subset of QBE IL that pebc writes, the names pebc gives things in the IL, the errors
you are likely to meet from QBE and the assembler, the testing tools of Chapter 8 and the
folding rules of Chapter 9. Unless a chapter is named, every value here is from the final
snapshot, `project/ch09/`, built with Zig 0.17.1 and QBE 1.2 on x86-64 Linux. For the reasoning
behind each line, read the chapter; this page is for looking things up.

Previous: [Chapter 9](09-constant-folding-and-where-to-go-next.md). Next: [References](REFERENCES.md).

## The pipeline

```
file.peb --pebc--> file.ssa (QBE IL) --qbe--> file.s (x86-64, AT&T syntax) --cc--> file
```

`qbe` only writes assembly; `cc` runs the assembler and the linker and brings in libc (that is
where `printf` comes from). The same steps by hand:

```console
$ pebc ir x.peb > x.ssa && qbe -o x.s x.ssa && cc -o x x.s && ./x
$ qbe -o hello.s hello.ssa && cc -o hello hello.s && ./hello      # hand-written IL (Chapter 1)
```

`qbe` and `cc` must be on `PATH`: `pebc build` and `zig build test` run them by name. Without
`qbe`, pebc prints `pebc: cannot run 'qbe': FileNotFound` and every golden test fails.

## Commands

**pebc:** `zig-out/bin/pebc COMMAND FILE [-o OUT] [--no-fold]` (options go after `FILE`).

| Command | Does | Since |
|---|---|---|
| `tokens FILE` | one token per line, `line:col  tag  text`; diagnostics on stderr | Chapter 2 |
| `ast FILE` | the syntax tree as S-expressions: `1 + 2 * 3` → `(+ 1 (* 2 3))` | Chapter 3 |
| `check FILE` | diagnostics only (lex, parse, check, and from Chapter 9 fold) | Chapter 5 |
| `ir FILE` | QBE IL on stdout | Chapter 1 |
| `build FILE [-o OUT]` | writes `OUT.ssa`, runs `qbe -o OUT.s OUT.ssa`, then `cc -o OUT OUT.s`; keeps the `.ssa` and `.s` for reading. Default `OUT`: the file's name without `.peb`, in the current directory | Chapter 1 |
| `--no-fold` | codegen ignores folded values (the folder still runs and still reports errors) | Chapter 9 |

Exit status: 0 success, 1 the program has errors (or `qbe`/`cc` failed, or the file can't be
read), 2 bad usage (unknown command, unexpected argument). Each phase runs only if the ones
before it found no errors.

**zig build** (run in `project/chNN/`):

| Command | Does | Since |
|---|---|---|
| `zig build` | installs `zig-out/bin/pebc` | Chapter 1 |
| `zig build test --summary all` | unit tests + golden tests (needs `qbe` and `cc`) | Chapter 1 |
| `zig build run -- ARGS` | runs pebc with `ARGS` | Chapter 1 |
| `zig build demo [-Dsample=samples/X.peb]` | compiles and runs a sample (default `samples/answer.peb`) | Chapter 1 |
| `zig build test -Dfilter=TEXT` | only the golden tests whose path contains `TEXT` | Chapter 8 |
| `zig build test -Dupdate` | rewrites the golden files with the actual output (read every diff first) | Chapter 8 |
| `zig build test --fuzz=50K` | runs the fuzz test for 50,000 inputs (plain `zig build test` runs it once on built-in inputs) | Chapter 8 |
| `zig build difftest [-Dseed=N] [-Dcount=N] [-Dkeep]` | differential testing against `cc -fwrapv` | Chapter 8 |
| `zig build test -Dno-fold`, `zig build difftest -Dno-fold` | the same with pebc's folding turned off | Chapter 9 |

`zig build test` and `zig build demo` don't install: run `zig build` before using
`zig-out/bin/pebc`. The golden step always runs (Zig can't see `qbe` and `cc`), while the unit
tests show `cached` when nothing changed.

**Exit statuses of compiled programs:**

| Status | Means | Seen in |
|---|---|---|
| low 8 bits of `main`'s `i32` | `return 300;` exits with 44; falling off the end of `main` returns 0 | Chapter 4 |
| 134 | 128 + 6, `SIGABRT`: `abort()`, or the stack protector's "stack smashing detected" | Chapter 6 |
| 136 | 128 + 8, `SIGFPE`: integer division by zero (`idiv` traps) | Chapters 1, 9 |
| 139 | 128 + 11, `SIGSEGV`: `*p` on `null`; buffered stdout to a pipe is lost | Chapter 6 |

## Pebble in one screen

The grammar is the comment at the top of `src/parser.zig`:

```
program = { decl } EOF
decl    = "fn" NAME params [ type ] block
        | "extern" "fn" NAME params [ type ] ";"
        | "struct" NAME "{" [ field { "," field } [ "," ] ] "}"
        | let
field   = NAME ":" type
params  = "(" [ param { "," param } [ "," "..." ] ] ")"
param   = NAME ":" type
type    = NAME | "*" type | "[" INT "]" type
block   = "{" { stmt } "}"
let     = ("let" | "var") NAME ( ":" type [ "=" expr ] | "=" expr ) ";"
stmt    = let
        | "if" expr block [ "else" ( block | if-stmt ) ]
        | "while" expr block
        | "break" ";" | "continue" ";"
        | "return" [ expr ] ";"
        | block
        | expr [ "=" expr ] ";"
```

Precedence, loosest first (Chapter 3; `as` from Chapter 5):

| Level | Operators | Notes |
|---|---|---|
| 1 | `\|\|` | short circuit, result 0 or 1 |
| 2 | `&&` | short circuit |
| 3 | `== != < <= > >=` | no chaining: `a < b < c` is an error with a note |
| 4 | `+ -` | left associative |
| 5 | `* / %` | left associative |
| 6 | `x as T` | binds tighter than any binary operator |
| 7 | prefix `-x !x &x *x` | |
| 8 | postfix `f(x) a[i] p.x` | bind tightest |

- **Keywords** (16): `as break continue else extern false fn if let null return sizeof struct
  true var while`. Type names (`i64`, `u8`, ...) are ordinary names.
- **Literals:** decimal and `0x` hex integers (2^63 and above is "too large"; `-5` is negation
  applied to `5`); `'c'` character literals, one byte, type `u8`; `"..."` strings, type `*u8`,
  NUL-terminated, no line breaks inside; `true`, `false`, `null`. Escapes: `\n \t \r \0 \\ \' \"`.
  Comments: `//` to the end of the line.
- **Declarations:** `fn` and `extern fn` (only `extern` may end its parameters with `...`),
  `struct` at the top level, `let`/`var` at the top level (globals) or in a block. Order of
  top-level declarations doesn't matter. A global's initializer must be a constant or a string
  (since Chapter 9, any constant expression the folder can compute). `var x: T;` without a
  value starts at zero.
- **`main`** takes no parameters and returns `i32` or nothing.

**Type rules** (Chapters 5–7):

- A literal takes the type its context wants (`let b: u8 = 200;` is fine, `256` is "does not
  fit in 'u8'"); without a context an integer literal is `i64`, a character literal `u8`. In
  `1 + x` the `1` gets `x`'s type.
- No implicit conversions: both operands of a binary operator have the same type; conditions
  are `bool`.
- `+ - * / %` and `< <= > >=` take integers; `== !=` take integers, `bool` or pointers (not
  structs or arrays); `&& || !` take `bool`; there is no pointer arithmetic (write `&p[i]`).
- Integer arithmetic wraps at the type's size; `/` and `%` round toward zero (`-7 / 2` is -3,
  `-7 % 2` is -1), like C99, x86 `idiv` and Zig's `@divTrunc`/`@rem`.
- `let` is immutable (no `=`, no `&`), `var` mutable. A `let`'s value is checked before its
  name is declared, so `let x = x + 10;` reads an outer `x`.
- Places (assignable, can take `&`): a `var` name, an element of a place array, a field of a
  place struct, and anything reached through a pointer (`*p`, `p[i]`, `p.f`).
- `a[i]` for `a: [N]T` or `a: *T` and any integer `i`; `p.f` dereferences one level of pointer
  automatically.
- Arrays are not values: no copying, passing, returning or C-style decay (write `&a[0]`).
  Structs can be copied by assignment (`blit`), but not passed, returned or compared.
- A function with a return type must return on every path (`alwaysReturns` is conservative:
  an `if` returns only with an `else` where both branches return; `while true` only without a
  `break`).
- Since Chapter 9 the largest type is `Type.max_size` = 2^31 − 1 bytes: `'[...]u8' is too large`.

**Conversions with `as`** (`genCast` in `codegen.zig`):

| From → to | Allowed | IL |
|---|---|---|
| `i32`, `u8`, `bool` → `i64` | yes | `extsw` from `i32`, `extuw` from `u8` or `bool` |
| `u8` → `i32` | yes | nothing (the same bits) |
| `i64` → `i32` | yes | `and v, 4294967295` (keeps the low 32 bits) |
| integer → `u8` | yes | `and v, 255` |
| `bool` → `i32`, `u8` | yes | nothing (0 or 1 already) |
| `*T` ↔ `i64`, `*T` → `*U` | yes | nothing (the same 64 bits) |
| integer → `bool` | no | "cannot convert 'i64' to 'bool' with 'as'; compare it with 0 instead" |

## Types in memory and in QBE

`types.zig`'s `size`, `alignment` and `base`:

| Pebble type | Size, alignment | QBE temporary | Load / store | Notes |
|---|---|---|---|---|
| `i64` | 8, 8 | `l` | `loadl` / `storel` | |
| `*T` | 8, 8 | `l` | `loadl` / `storel` | a string literal is `*u8` |
| `i32` | 4, 4 | `w` | `loadw` / `storew` | widened to `i64` with `extsw` |
| `bool` | 4, 4 | `w` | `loadw` / `storew` | 0 or 1; `sizeof(bool)` is 4 (C's `_Bool` is 1) |
| `u8` | 1, 1 | `w` | `loadub` / `storeb` | kept 0–255 with `and 255`; unsigned instructions |
| `[N]T` | N × size of T, alignment of T | address (`l`) | `blit` (Chapter 7's exercise 1) | `[3][4]i32` is 3 rows of 4 |
| `struct` | C layout (below) | address (`l`) | `blit src, dst, size` | |
| `void` | 0 | — | — | only as "returns nothing" |

**Struct layout** (System V ABI, `layoutStruct` in `check.zig`): each field goes at the next
multiple of its own alignment; the struct's alignment is its largest field's; its size is
rounded up to that alignment, so arrays of it stay aligned. Chapter 7's test: `struct Inner { b:
u8, n: i32 }` is size 8, alignment 4 (`n` at 4); `struct Outer { c: u8, inner: Inner, next:
*Outer, d: u8 }` puts `c` at 0, `inner` at 4, `next` at 16, `d` at 24, size 32. A struct that
contains itself is an error; a pointer to itself is fine. The checker runs four passes: struct
names, struct layouts, signatures and globals, bodies.

## QBE IL essentials

- **A file** is `data`, `type` and `function` definitions. Sigils: `$` global (function or data,
  always an address), `%` temporary, `@` label, `:` aggregate type.
- **Base types:** `w` (32-bit integer), `l` (64-bit), `s`, `d` (floats); `b` and `h` only in
  `data`, loads and stores. Comparisons produce 0 or 1 and the `=w`/`=l` on the left picks the
  result type: `%c =w csltl %a, %b`.
- **Instruction names:** signed/unsigned is in the instruction, not the type: `div`/`udiv`,
  `rem`/`urem`, `csltw`/`cultw`, `loadsb`/`loadub`, `extsw`/`extuw`. Comparison names are
  `c` + `eq ne slt sle sgt sge ult ule ugt uge` + `w` or `l`.
- **Functions:** `export function w $main() { @start ... ret 0 }`; `function l $f(l %a) {...}`.
- **Data:** `data $str.0 = { b "hi", b 10, b 0 }`, `{ l 0 }`, `{ w -3 }`, `{ l $str.0 }`,
  `{ z 32 }` (32 zero bytes, in `.bss`). QBE puts string literals in writable `.data` (C uses
  `.rodata`).
- **Stack slots:** `%p =l alloc8 8` / `alloc4 4` (the number in the name is the alignment, 4, 8
  or 16; the operand is the size); `storel v, %p`, `loadl %p`.
- **Calls:** `%r =l call $f(l %a, w 1)`; variadic: `call $printf(l $str.0, ..., l %x)`. The
  `...` marks where the variadic arguments start, so QBE sets `%al` (`movl $0, %eax`) as the
  System V ABI asks.
- **Copying memory:** `blit %src, %dst, 16` (QBE 1.2 expands it into 8-byte load/store pairs).
- **`hlt`** ends a block that can't be reached. There is no `extern` keyword: an undefined
  `$name` is resolved by the linker.

The subset pebc emits, counted over every golden test and sample with `--no-fold`, most used
first: `loadl storel add call alloc8 jnz mul ret jmp copy loadub csltl sub loadw storew rem div
storeb and alloc4 ceql neg cslel ceqw cnew cnel csgtl extsw culew csgel udiv cugew csltw blit
hlt`.

**Rules that bite:**

| Rule | Why it matters | Chapter |
|---|---|---|
| Every block ends with exactly one `jmp`, `jnz`, `ret` or `hlt`; code after one needs a new label | `qbe:t1.ssa:7: label or } expected`; pebc's `ensureBlock` makes `@dead.N` | 1, 4 |
| Temporaries may be assigned more than once; QBE builds SSA (and `phi`s) itself | pebc never writes a `phi` | 1, 8 |
| `jnz` tests only the low 32 bits | `jnz` on `1 << 32` takes the false branch; pebc's `genCond` adds `cnel v, 0` unless the value is already 0 or 1 | 4 |
| `alloc` belongs in the start block | an `alloc8` in a loop emits `subq $16, %rsp` on every iteration | 1, 4 |
| `extsw` takes a `w` operand | `qbe:tr.ssa:11: invalid instruction type in extsw` | 5 |
| `=w copy` of a known-constant `l` | the assembler warns `0x000000012a05f200 shortened to 0x000000002a05f200`; pebc narrows with `and v, 4294967295` | 5 |
| QBE checks the IL's form, not its meaning | `div 7, 0` compiles to `idivl` and dies with `SIGFPE` (136) | 1, 9 |

**`qbe -d LETTERS file.ssa`** prints the IL between passes on stderr (`2>&1 >/dev/null` keeps
only the dump): `P` parsing, `M` memory optimization (slot promotion), `N` SSA construction
(`phi`s appear), `C` copy elimination, `F` constant folding (SCCP), `A` ABI lowering, `I`
instruction selection, `L` liveness, `S` spilling, `R` register allocation.

**SCCP** (`qbe -d F`, Chapter 9): each temporary sits in a lattice: `Top` ("no value seen
yet"), a constant, or `Bot` ("more than one value, so not a constant"). Every temporary starts
at `Top`; QBE prints the "SCCP findings" for every temporary that didn't end at `Bot`, then the
dead blocks.

## pebc's names in the IL

| Name | Is | Since |
|---|---|---|
| `%t1`, `%t2`, ... and `$fmt` | temporaries and the format string of Chapters 1–3 | Chapter 1 |
| `%.N` | a temporary (a dot can't start a Pebble name, so no clash) | Chapter 4 |
| `%x` | the incoming value of parameter `x` | Chapter 4 |
| `%x.N` | the stack slot of variable `x` (`N` is a per-function symbol id; shadowed names never clash) | Chapter 4 |
| `$x` | a function or a global variable | Chapters 4, 6 |
| `$str.N` | a string literal | Chapter 4 |
| `@if.N.then`, `@if.N.else`, `@if.N.end` | an `if` | Chapter 4 |
| `@while.N.cond`, `@while.N.body`, `@while.N.end` | a `while`; `break` jumps to `.end`, `continue` to `.cond` | Chapter 4 |
| `@and.N.rhs`, `@and.N.end`, `@or.N.rhs`, `@or.N.end` | short circuit: one temporary assigned with `copy` on two paths | Chapter 4 |
| `@dead.N` | the label `ensureBlock` adds after a jump or `ret` | Chapter 4 |

Every slot is allocated in `@start`; a whole-array `var` is zeroed with
`call $memset(l %a.N, w 0, l size)`.

## Diagnostics

```
path:line:col: error: message
<the source line>
<spaces>^~~~~
```

- Columns are 1-based **bytes**; `^` under the first byte of the span, `~` under the rest;
  tabs in the source line are copied so the caret lines up; an error at end of file is shown
  after the last character. Optional `note:` lines follow in the same format.
- Wording: lower case, no full stop, quote source text in `'...'`, say what was expected and
  what was found, add a `note:` at the other place involved (`'add' is declared here`, `use 'var'
  here to make it a variable`).
- The lexer never stops: a bad character becomes an `invalid` token plus a diagnostic. The
  parser recovers in panic mode (`skipToStatement`, `skipToDeclaration`). One wrong expression
  gets the type `invalid`, which every rule accepts silently: one mistake, one message. Read
  the first error first.
- At most `Diagnostics.max_errors` = 20 errors are shown, then `path: N more errors not shown`
  (Chapter 8).
- The exercises add `warning:` (Chapter 4's unreachable code, Chapter 5's unused variables,
  Chapter 9's overflow); warnings don't change the exit status.

## Testing (Chapter 8)

| Kind | Where | Checks |
|---|---|---|
| unit tests | `test` blocks in `src/*.zig` | small known facts (23 in Chapter 9) |
| golden: run | `tests/run/NAME.peb` + `NAME.out` | the compiled program's stdout, exit status 0 |
| golden: errors | `tests/errors/NAME.peb` + `NAME.err` | stderr of `pebc ir`, which must fail |
| golden: trees | `tests/ast/NAME.peb` + `NAME.ast` | `pebc ast` output |
| fuzz | `src/fuzz.zig`, `std.testing.fuzz` + `std.testing.Smith` | random bytes and random tokens through lexer, parser, checker: never crash |
| difftest | `tests/difftest.zig` | a random program written twice, as `case.peb` and `case.c`; pebc and `cc -fwrapv` must agree |

- The golden runner runs pebc inside `tests/`, so paths in messages are `errors/NAME.peb` on any
  machine. It prints an LCS line diff with context, fails on a missing golden file, and stops a
  program after 10 seconds or 1 MiB of output.
- A crash the fuzzer finds is saved in `.zig-cache/f/crash`; every bug it finds becomes a small
  regression test.
- Difftest avoids C's undefined behaviour: `-fwrapv`, safe division helpers, a cast on every
  operation, functions that only read globals, bounded loops, no arrays. A failing case keeps
  its files and prints the first different line.
- To test an optimization, turn it off and compare: a bug that fails with folding on and
  passes with `-Dno-fold` is in the folder.

## Constant folding (Chapter 9)

- `Expr.value: ?i64`, normalized for its type: `u8` 0..255, `i32` sign-extended, `bool` 0 or 1,
  `null` 0. The pipeline is lex → parse → check → fold → codegen; the folder always runs.
- Match the machine: `+%`, `-%`, `*%`, then `castInt` cuts to 8 or 32 bits; `-x` is `0 -% x`;
  `@divTrunc` and `@rem` (toward zero), never `@divFloor`/`@mod` (toward −∞, like Python's
  `//`). `false && x` is 0 and `true || x` is 1 whatever `x` is.
- New compile-time errors: division or remainder by a constant zero (only the divisor needs to
  be known), a constant index out of bounds on an array, `MIN / -1` in `i64` and `i32`.
- Codegen: a known expression becomes its number; a known `if` compiles only the live branch;
  `while false` emits nothing; `while true` drops its `jnz`.
- QBE 1.2 also folds (SCCP) and removes dead branches, but doesn't fold a division by a constant
  zero and doesn't apply identities such as `x * 1`. With `--no-fold`, the assembly of every
  golden program is the same except `fold.peb`'s.
- LLVM IR of the same C function: `zig cc -S -emit-llvm -O0 -g0 -fno-sanitize=undefined
  -fno-discard-value-names -o sum0.ll sum.c` (and `-O2`).

## Growth of pebc

Lines in `src/*.zig`, source files, and golden tests, all passing at the end of each chapter:

| Chapter | `src/` lines | Files | Golden tests (run + errors + ast) |
|---|---|---|---|
| 1 | 297 | 3 | 4 (4 + 0 + 0) |
| 2 | 788 | 5 | 9 (4 + 5 + 0) |
| 3 | 1136 | 8 | 17 (6 + 7 + 4) |
| 4 | 1860 | 8 | 21 (8 + 11 + 2) |
| 5 | 2548 | 10 | 24 (9 + 13 + 2) |
| 6 | 2817 | 10 | 30 (14 + 13 + 3) |
| 7 | 3098 | 10 | 36 (18 + 14 + 4) |
| 8 | 3222 | 11 | 37 (19 + 14 + 4) |
| 9 | 3505 | 12 | 40 (20 + 16 + 4) |

In Chapter 9 the tests add 983 lines (`golden.zig` 281, `difftest.zig` 702) and `build.zig`
100. The snapshots of Chapters 6 to 8 still panic with an integer overflow on absurdly large
array types such as `[1000000][1000000]u8`; Chapter 9 finds and fixes that.

## Concept → code

In the Chapter 9 snapshot unless noted (`file` `function`):

| Concept | Where | Chapter |
|---|---|---|
| one-pass compiler, one function per grammar rule | `src/compiler.zig` `expr`, `term`, `unary`, `primary` (Chapters 1–2 only) | 1 |
| running `qbe` and `cc` | `src/driver.zig` `build`, `runTool` | 1 |
| spans, line:col, caret rendering | `src/diag.zig` `Source.locate`, `Diagnostics.render` | 2 |
| the error limit | `src/diag.zig` `Diagnostics.max_errors` | 8 |
| tokens, maximal munch, keywords | `src/lexer.zig` `Lexer.next`, `keywords` | 2 |
| integer literal decoding | `src/lexer.zig` `intValue` | 2 |
| the syntax tree (arena) | `src/ast.zig` `Expr`, `Stmt`, `Func`, `Symbol` | 3 |
| precedence climbing (Pratt) | `src/parser.zig` `Prec`, `precedence`, `expression`, `prefix`, `postfix` | 3 |
| tree printer | `src/print.zig` `writeExpr` | 3 |
| tree → IL, temporaries | `src/codegen.zig` `genExpr`, `newTemp` | 3 |
| statements, labels, blocks | `src/codegen.zig` `genStmt`, `label`, `ensureBlock` | 4 |
| short circuit `&&`/`\|\|` | `src/codegen.zig` `genLogical` | 4 |
| error recovery (panic mode) | `src/parser.zig` `skipToStatement`, `skipToDeclaration` | 4 |
| stack slots in the start block | `src/codegen.zig` `declare`, the `allocs` buffer | 4 |
| name resolution, scopes | `src/check.zig` `lookup`, the `scope` stack | 5 |
| types and their sizes | `src/types.zig` `Type`, `size`, `alignment`, `fits` | 5 |
| type checking, literal typing | `src/check.zig` `checkExpr`, `checkBinary`, `literalType` | 5 |
| "every path returns" | `src/check.zig` `alwaysReturns` | 5 |
| casts (`as`) | `src/codegen.zig` `genCast` | 5 |
| addresses vs values (places) | `src/check.zig` `checkPlace`; `src/codegen.zig` `genAddr` | 6 |
| struct layout | `src/check.zig` `layoutStruct` | 7 |
| calls, variadic libc calls | `src/check.zig` `checkCall`; `src/codegen.zig` `genCall` | 7 |
| string literals as data | `src/codegen.zig` `writeStringData` | 7 |
| golden tests | `tests/golden.zig` `Runner` (`runProgram`, `checkErrors`, `checkTree`) | 8 |
| fuzzing every phase | `src/fuzz.zig` `compileSomething` | 8 |
| differential testing against C | `tests/difftest.zig` `Gen`, `compareCase` | 8 |
| constant folding, machine arithmetic | `src/fold.zig` `foldExpr`, `foldBinary`, `castInt` | 9 |
| size limit for huge types | `src/types.zig` `max_size`; `src/check.zig` `checkSize` | 9 |
