# Chapter 5 — Names and Types

Chapter 4's pebc treats every value as a 64-bit word, the way B did in 1970. That is enough
for `fib` and FizzBuzz, and it stops being enough the moment a program touches a byte. This
chapter adds a **checker**, a new phase between the parser and the code generator. It resolves
every name to the declaration it means, gives every expression a **type** (`i64`, `i32`, `u8`,
`bool` or a pointer `*T`), reports every place where types don't fit, and enforces the rules a
grammar can't express: every path through a function returns, `break` sits inside a loop,
`main` has the right shape. The checker writes what it learns into the tree, so the code
generator can trust the tree and do only its own job: pick `w` or `l`, `storeb` or `storel`,
`div` or `udiv`. The project gains `types.zig`, `check.zig`, a `pebc check` command, and
Pebble programs that wrap around at 8, 32 or 64 bits as they should.

Previous: [Chapter 4](04-statements-and-functions.md). Next: [Chapter 6](06-pointers-and-arrays.md).

## Why types

Here is a program for Chapter 4's pebc. It has no types to write, because Chapter 4's Pebble
has none:

```
extern fn printf(format, ...);

fn main() {
    let big = 5000000000;
    printf("%d %ld\n", big, big);
    let s = "hi";
    printf("%ld\n", s);
}
```

```console
$ ../../project/ch04/zig-out/bin/pebc build big.peb && ./big
705032704 5000000000
104710984945688
```

(`big.peb` is a throwaway file in a scratch directory; the last number changes on every run.)
Three things happened, and none of them was reported:

- `big` is a 64-bit word. `%d` tells printf to read an `int`, 32 bits, so it read the low
  half of the register: 5000000000 is `0x12A05F200`, and its low 32 bits are `0x2A05F200`,
  which is 705032704.
- `s` is "the address of some bytes". To pebc it is just another word, so printing it as a
  number prints the address, which the loader picks anew each run.
- Nothing stops you. Chapter 4's pebc can't tell a number from an address, so it can't
  complain about either line.

And one thing it can't do at all. `idx.peb` declares `extern fn putchar(c);` and tries to
print the first letter of a string:

```console
$ ../../project/ch04/zig-out/bin/pebc build idx.peb
idx.peb:5:13: error: pebc cannot compile indexing yet
    putchar(s[0]);
            ^~~~
```

To compile `s[0]` a compiler must know that `s` points to *bytes*: it must load one byte
(`loadub`), not eight (`loadl`), and to find `s[1]` it must add 1 to the address, not 8. The
size of the thing pointed to is not in the value; it has to come from somewhere else. That
somewhere is the type.

C has types, so a C compiler knows what `big` is, and it can even check printf's format string
against the arguments (a special case GCC adds for printf-like functions):

```console
$ gcc -Wall -o bigc big.c
big.c: In function ‘main’:
big.c:5:14: warning: format ‘%d’ expects argument of type ‘int’, but argument 2 has type ‘long int’ [-Wformat=]
    5 |     printf("%d %ld\n", big, big);
      |             ~^         ~~~
      |              |         |
      |              int       long int
      |             %ld
$ ./bigc
705032704 5000000000
```

Types give a compiler three things, and this chapter uses all three:

1. **Sizes.** How many bytes to load and store, how big a stack slot is, how far apart array
   elements are (Chapter 6).
2. **Operations.** The same bits compare differently as signed and unsigned numbers. The
   hardware has both kinds of instruction; the type says which one to emit.
3. **Mistakes found before the program runs.** `if count { ... }` where `count` is a number,
   `add(1, "two")`, a function that forgets to return: all errors at compile time, with a
   caret under the problem.

Pebble will not check printf's format strings. A variadic argument has whatever type it has,
and `printf("%d", big)` still prints 705032704. That check needs knowledge of printf, not
types; GCC has it built in.

## History: how B became C

Pebble is retracing a step that C took around 1971. Dennis Ritchie's paper "The Development of
the C Language" tells the story from the inside.

- **B and BCPL had one type.** Ritchie describes both as "typeless, or rather have a single
  data type, the `word,' or `cell,' a fixed-length bit pattern". `+` "simply adds its operands
  using the machine's integer add instruction"; what a cell means "depends on the operation
  applied". That is Chapter 4's pebc exactly. Even `*p` comes from there: BCPL spelled
  indirection `rv`, later `!`, and B used unary `*`.
- **The PDP-11 broke the model.** B ran on word-addressed machines, where a cell was a
  machine word. The PDP-11 addressed bytes. Ritchie lists the problems: character handling
  that unpacked strings into cells and repacked them "began to feel awkward, even silly, on a
  byte-oriented machine"; floating point would not fit in a 16-bit word; and because pointers
  were word indices, "Each pointer reference generated a run-time scale conversion from the
  pointer to the byte address expected by the hardware". His conclusion: "a typing scheme was
  necessary to cope with characters and byte addressing, and to prepare for the coming
  floating-point hardware."
- **NB, then C.** In 1971 Ritchie added a character type to B and rewrote its compiler to
  generate PDP-11 instructions; he called the result NB, "new B". NB had `int` and `char`,
  arrays of them and pointers to them. Indexing and pointer arithmetic now "depended on the type
  of the array or the pointer": `iarray[i]` scales `i` by the element size. That is the sizes
  argument above, and it is what Chapter 6 does with `a[i]`.
- **Checking came later.** Ritchie is frank about it: "Other issues, particularly type safety
  and interface checking, did not seem as important then as they became later." In his critique
  of C he notes that compilers "in 1977, and even well after" did not complain about assigning
  between integers and pointers, and that in K&R C "supplying arguments of the proper type to a
  function call was the responsibility of the programmer". Argument types in function
  declarations came with the ANSI X3J11 standard, which Ritchie calls the committee's "boldest
  and most painful innovation". Until then the separate `lint` program checked calls against
  definitions.

Pebble gets to skip the 18 years between NB and ANSI C: every parameter has a type from the
start, and every call is checked against it.

## Syntax for types

The grammar changes in four places (from the comment at the top of `parser.zig`):

```diff
-    decl      = "fn" NAME params block
-              | "extern" "fn" NAME params ";"
+    decl      = "fn" NAME params [ type ] block
+              | "extern" "fn" NAME params [ type ] ";"
+    param     = NAME ":" type
+    type      = NAME | "*" type
-    stmt      = ("let" | "var") NAME "=" expr ";"
+    stmt      = ("let" | "var") NAME [ ":" type ] "=" expr ";"
+    as                       (x as T)
```

- A parameter is `name: T`. Its type is required: the caller and the callee must agree on how
  the value travels, and there is nothing else to infer it from.
- The return type follows the `)`. No type means the function returns nothing.
- `let x: T = e` gives a variable a type. Without one, the variable takes the type of `e`.
- `e as T` converts. There are no implicit conversions in Pebble, so this is the only way to
  get an `i32` from an `i64`.

The type names `i64`, `i32`, `u8` and `bool` are ordinary identifiers to the lexer and the
parser. Only the checker knows which names are types. `*T` is a pointer to a `T`; a string
literal has type `*u8`. The `:` and `as` tokens were already in Chapter 2's lexer, so the lexer
doesn't change.

`parseType` is one switch that builds an `ast.TypeExpr`: an identifier is a named type
(`.name`), and `*` is a pointer to whatever type follows (`.pointer`), parsed by calling
`parseType` again. Anything else is `expected a type, found ...`.

`as` is a postfix operator with a precedence of its own, `cast`, tighter than `*`:

```zig
const Prec = enum(u8) { lowest, @"or", @"and", compare, add, mul, cast };
```

It gets its own branch in the precedence-climbing loop of Chapter 3, because its right side is
a type, not an expression:

```zig
        while (true) {
            if (p.peek().tag == .kw_as) {
                if (@backingInt(Prec.cast) <= @backingInt(min)) break;
                _ = p.advance();
                const ty = try p.parseType();
                lhs = try p.node(lhs.span.to(ty.span), .{ .cast = .{ .operand = lhs, .type = ty } });
                continue;
            }
```

So `n as u8 * 2` means `(n as u8) * 2`, and `x as *u8 as i64` means `(x as *u8) as i64`.
Prefix operators bind tighter still: `-n as u8` converts `-n`. `pebc ast` prints the types:

```console
$ cd project/ch05/tests
$ ../zig-out/bin/pebc ast ast/expressions.peb
(fn main ()
  (- (+ 1 (* 2 3)) 4)
  (|| a (&& b (== c (+ d (* e f)))))
  (+ (- (. x y)) (* (* (index p 2)) (! (call f 1 (call g 2)))))
  (|| (== (+ 'a' '\n') "tab\t") true)
  (+ (* (as (- n) u8) 2) (as (as x *u8) i64)))
$ ../zig-out/bin/pebc ast ast/statements.peb | head -2
(extern fn printf ((format *u8) ...) i32)
(fn sign ((n i64)) i32
```

Every test program from Chapter 4 changes too. Most changes are annotations:
`extern fn printf(format, ...);` becomes `extern fn printf(format: *u8, ...) i32;`, and
`fn fib(n)` becomes `fn fib(n: i64) i64`. A few are the type rules below showing through. A
condition must now be a `bool`, so `run/scopes.peb`'s `if big {` becomes `if big != 0 {`, and
`run/short_circuit.peb`'s `fn say(name, value)` becomes `fn say(name: *u8, value: bool) bool`,
called with `true` and `false` instead of 1 and 0. And a `bool` or a `u8` is now a 32-bit
value, so printf reads it with `%d`, not `%ld`. The expected outputs don't change.

## Types in Zig: `types.zig`

The checker needs a value that *is* a type, to compare and print. `types.zig` defines it:

```zig
pub const Type = union(enum) {
    void,
    bool,
    i64,
    i32,
    u8,
    /// `*T`. String literals are `*u8`.
    pointer: *const Type,
    /// The type of an expression that has an error. Every check accepts
    /// it silently, so one mistake produces one message, not a cascade.
    invalid,
```

A tagged union, like `Expr.Kind` in Chapter 3. Most members carry nothing. `pointer` carries a
pointer to the type it points to, so `**u8` is a `pointer` whose target is a `pointer` whose
target is `u8`. `void` is the "type" of a call to a function that returns nothing. `invalid`
is explained under "Good diagnostics" below.

`eql` compares two types: equal tags and, for pointers, equal targets (it calls itself). The
rest are small questions the checker and code generator ask:

```zig
    /// The size in bytes of a value of this type in memory.
    pub fn size(t: Type) u64 {
        return switch (t) {
            .void, .invalid => 0,
            .u8 => 1,
            .bool, .i32 => 4,
            .i64, .pointer => 8,
        };
    }
```

- `isInteger` (i64, i32, u8) and `isSigned` (i64, i32) complete the set, with `fits(t,
  value)`, which compares a literal with `std.math.maxInt` of the type.
- `fits` takes a `u64` because literals have no sign: `-5` is negation applied to `5`
  (Chapter 3). So `-128` as an i32 is fine, and a `u8` can't be negated at all (below).
- `bool` takes 4 bytes. It could take 1; 4 keeps it a plain `w` in memory, with `storew` and
  `loadw`, and costs nothing that matters.
- `base` answers "which QBE temporary": `'l'` for `i64` and pointers, `'w'` for everything
  else. QBE has only two integer temporaries, `w` and `l`. A `u8` lives in a `w` and only
  becomes a byte when stored (below).

Every `switch` here lists the tags it handles, with no `else` where it matters. That pays off in
exercise 1: add a type and the Zig compiler lists every switch that must learn about it.

Finally, a `format` method lets Zig's `{f}` print a type: the tag name, or `*` and the target
for a pointer. So `try c.diags.err(span, "expected '{f}', found '{f}'", .{ want, got })` prints
`expected 'i64', found '*u8'`. The unit test at the bottom of `types.zig` checks that two
`*u8`s are equal, that `*u8` and `*i32` are not, and that a pointer prints as `*u8`.

## The checker

Chapter 4's code generator did two jobs at once: it looked names up in its own list of locals,
reported `unknown name` and friends, and wrote IL. Chapter 5 splits those jobs. `main.zig` runs
one more phase, and each phase runs only if the ones before it found no errors:

```zig
    var checker: Checker = .init(arena, &diags);
    try checker.checkProgram(program);
    if (diags.hasErrors()) return fail(diags, stderr);
    if (command == .check) return 0;
```

`pebc check FILE` stops right there: it reports errors without writing any IL. The code
generator lost its `CodegenError` and its `diags`: by the time it runs, the program is known to
be correct.

### Symbols

The checker's output goes into the tree. Every declared name gets a `Symbol`:

```zig
/// What a name refers to. The checker makes one for every function,
/// parameter and variable, and points each use of the name at it.
pub const Symbol = struct {
    name: []const u8,
    /// Where it is declared, for error notes.
    span: Span,
    kind: enum { variable, function },
    /// The type of a variable, or the return type of a function.
    type: Type,
    mutable: bool = false,
    /// Makes the stack slot name %name.id unique within a function.
    id: u32 = 0,
    func: ?*Func = null,
};
```

and `Expr` gains two fields the parser leaves empty: `type: Type = .invalid` and, for a
`.name`, `sym: ?*Symbol = null`. After checking, every `x` in the tree points at the one
`Symbol` for the `x` it means, and every expression knows its type. The code generator reads
`e.type` and `e.sym` and never searches for anything.

### Two passes

`checkProgram` loops over the declarations twice:

```zig
        // Pass 1: function signatures, so a call can come before the
        // function it calls.
        for (program.decls) |decl| switch (decl) {
            .func => |f| try c.declareFunction(f),
        };
        // Pass 2: function bodies.
```

Pass 1 reads only signatures: parameter types and return types, resolved from `TypeExpr` to
`Type` by `resolveType`, and puts a function symbol in `funcs`. Pass 2 checks bodies. Because
every signature is known before any body is checked, `main` can call a function defined below
it, and two functions can call each other. C made the other choice (declare before use, hence
prototypes and header files), which suits a compiler that works in one pass with little memory.
Ritchie's paper notes that "Storage limitations on the B compiler demanded a one-pass
technique in which output was generated as soon as possible", and that the syntax redesigned
for it "was carried forward into C". Pebble's whole program is in memory anyway.

`declareFunction` also catches a second function with the same name (`errors/no_main.peb`
gets `error: 'helper' is already declared`, with a note at the first declaration).

### Scopes

Variables live in a **scope stack**: a list of `*Symbol`, innermost last. A block remembers
how long the list was and cuts it back when it ends:

```zig
    fn checkBlock(c: *Checker, b: ast.Block) Error!void {
        const scope_start = c.scope.items.len;
        defer c.scope.shrinkRetainingCapacity(scope_start);
        try c.checkStmts(b.stmts);
    }
```

`lookup` searches from the end of the list, so an inner `x` hides an outer one. A linear
search looks slow, and isn't: a function has a handful of variables in scope at any point. A
hash map per scope would be more code for no gain at this size.

`let` declares its symbol *after* checking the value:

```zig
            .let => |*l| {
                var t: Type = undefined;
                if (l.type) |te| {
                    t = try c.resolveType(te);
                    try c.expectType(l.value, t, try c.checkExpr(l.value, t));
                } else {
                    t = try c.checkValue(l.value, null);
                }
                // Declared after the value is checked: in `let x = x + 1;`
                // the x on the right is the outer one.
                l.sym = try c.newSymbol(.{ .name = l.name, ..., .type = t, .id = c.nextId() });
                try c.scope.append(c.arena, l.sym);
            },
```

`tests/run/scopes.peb` depends on that order: it declares `let x = 1;`, then in an inner block
`let x = x + 10;`, and prints `inner 11` then `outer 1`. The two `x`s are two symbols, with ids
1 and 2, so their stack slots are `%x.1` and `%x.2`. The id counter restarts in every function,
which keeps the IL readable: the first variable of every function is `.1`.

Function names are not in the scope stack; they are in `funcs`. A variable used as a function,
or a function used as a variable, gets its own message instead of a plain `unknown name`:

```console
$ ../zig-out/bin/pebc check errors/names.peb 2>&1 | tail -6
errors/names.peb:7:5: error: 'printf' is a function, not a variable
    printf = 3;
    ^~~~~~
errors/names.peb:8:13: error: 'main' is a function, not a variable
    let f = main;
            ^~~~
```

## Type rules

The checker's core is `checkExpr(e, want)`. It works out the type of `e`, stores it in
`e.type`, and returns it; `want` is explained below. Inside, `typeOf` is one `switch` over the
node kinds. The rules:

| Expression | Rule | Type |
|---|---|---|
| `42`, `'a'` | takes `want` if it is an integer type, else `i64` (`u8` for a char); must fit | the integer type |
| `true` | | `bool` |
| `"hi"` | | `*u8` |
| `x` | must be declared | the variable's type |
| `-e` | `e` must be signed | type of `e` |
| `!e` | `e` must be `bool` | `bool` |
| `a + b` (and `-`, `*`, `/`, `%`) | integers, the same type | that type |
| `a < b` (and `<=`, `>`, `>=`) | integers, the same type | `bool` |
| `a == b`, `a != b` | the same type: integer, bool or pointer | `bool` |
| `a && b`, `a \|\| b` | both `bool` | `bool` |
| `f(args)` | each argument matches its parameter | the return type |
| `e as T` | integer to integer, or `bool` to integer | `T` |

### Literals take the type the context wants

`let b: u8 = 200;` should just work, and so should `b + 55`. But `200` on its own is an `i64`.
The `want` parameter carries the context's expectation down into the expression, and
`literalType` uses it:

```zig
    fn literalType(c: *Checker, e: *Expr, value: u64, default: Type, want: ?Type) Error!Type {
        const t = if (want != null and want.?.isInteger()) want.? else default;
        if (!t.fits(value)) return c.fail(e.span, "{d} does not fit in '{f}'", .{ value, t });
        return t;
    }
```

`let b: u8 = 200;` checks `200` with `want = u8`, so it is a `u8`. `let b: u8 = 300;` is an
error: 300 does not fit. A typed `let`, an argument (want = the parameter's type), a `return`
(want = the return type) and a condition (want = `bool`) all pass a `want`.

For a binary operator the other operand is the context. In `b + 55`, the `55` should become a
`u8` because `b` is one. In `55 + b` the literal comes first, so `checkBinary` checks the
operands in whichever order puts the literal last:

```zig
        if (isLiteral(b.lhs) and !isLiteral(b.rhs)) {
            rhs = try c.checkValue(b.rhs, operand_want);
            lhs = try c.checkValue(b.lhs, rhs);
        } else {
            lhs = try c.checkValue(b.lhs, operand_want);
            rhs = try c.checkValue(b.rhs, lhs);
        }
```

`isLiteral` also accepts a negated literal, so `-1 * x` works for an `i32 x`. When both sides
are literals, `want` decides: `let d: i32 = -1 * 7;` makes both `i32`. A comparison passes no
`want` to its operands, because `want` for a comparison is `bool` and says nothing about them.
Zig does something similar, with a real type for it: an integer literal is a
`comptime_int` until it meets a context that gives it a concrete type.

### No implicit conversions

Once both operands are checked, `checkBinary` requires `lhs.eql(rhs)`; otherwise it reports
`'+' needs operands of the same type, not 'i64' and 'i32'`, with a note on the right operand:
`convert one of them with 'as'`. C would convert the `i32` to `long` silently ("the usual
arithmetic conversions"). That is convenient for adding, and a classic source of bugs for
comparing: in C, `-1 < 1u` is false, because `-1` is converted to unsigned first. Zig and Rust
don't convert integers implicitly (Zig widens when no value can be lost); Pebble follows the
strictest version of that rule, because it is the easiest to explain: if you want a conversion,
write `as`.

### Conditions are `bool`

`if`, `while`, `!`, `&&` and `||` take a `bool` and nothing else. `if count { ... }` is legal C
and an error in Pebble; write `if count != 0`. This also sidesteps Chapter 4's `jnz` trap
(gotcha 5: `jnz` looks only at the low 32 bits of its operand): every condition is now a
comparison result, a `w` that is 0 or 1.

### Casts

The `.cast` case checks the operand with no `want`, resolves the target type, and accepts one
rule:

```zig
                if (from.eql(to) or (to.isInteger() and (from.isInteger() or from == .bool))) return to;
```

Any integer type converts to any other, and `bool` converts to an integer (`true as i64` is 1).
Integer to `bool` is refused with a hint (exercise 2 allows it). Pointer conversions are refused
too: `as` does arithmetic conversions only.

### Pointers have a type, but no operations yet

`*u8` exists so that strings and `printf` have a type. `&x` and `*p` parse (Chapter 3), but
the checker rejects them until Chapter 6 gives them a meaning:

```console
$ ../zig-out/bin/pebc check errors/pointer.peb
errors/pointer.peb:3:13: error: pebc cannot compile pointers yet
    let p = &x;
            ^~
```

## Good diagnostics

A checker that reports one error is easy. A checker that reports *every* error, each once, is
the work. The problem is the **cascade**: in `let x: i64 = 1 + nope * 2;`, `nope` is unknown.
What is the type of `nope * 2`? Of `1 + nope * 2`? If the checker guesses `i64`, it may be
wrong and report a mismatch that doesn't exist. If it reports "operand has unknown type", that
is a second message for the same mistake.

That is what `Type.invalid` is for. An expression with an error has type `invalid`, and every
rule accepts `invalid` silently:

```zig
    /// Reports an error unless `got` is `want`. Invalid types match
    /// anything: their error has been reported already.
    fn expectType(c: *Checker, e: *const Expr, want: Type, got: Type) Error!void {
        if (want == .invalid or got == .invalid or want.eql(got)) return;
        try c.diags.err(e.span, "expected '{f}', found '{f}'", .{ want, got });
    }
```

When either operand is `invalid`, `checkBinary` returns `invalid` without a message (a
comparison returns `bool`, since its own type is known whatever its operands are). `fail`
reports and returns `invalid` in one line, which is why so many cases end with `return
c.fail(...)`. The unit test `"one mistake, one message"` in `check.zig` holds the line: it
checks `fn main() { let x: i64 = 1 + nope * 2; if x > 0 && x < 9 {} }` and expects exactly one
error, `t.peb:1:30: error: unknown name 'nope'`.

`x` is declared with its written type `i64` even though its value is broken, so the `if` after
it checks cleanly. Without a written type, `x` would be `invalid`, and every later use of it
would stay silent: also right.

The golden test `errors/types.peb` collects one of each type error. Every message says what was
expected and what was found, and points at the smallest span that is wrong:

```console
$ ../zig-out/bin/pebc check errors/types.peb
errors/types.peb:4:21: error: 300 does not fit in 'u8'
    let small: u8 = 300;
                    ^~~
errors/types.peb:7:15: error: '+' needs operands of the same type, not 'i64' and 'i32'
    let sum = wide + narrow;
              ^~~~~~~~~~~~~
errors/types.peb:7:22: note: convert one of them with 'as'
    let sum = wide + narrow;
                     ^~~~~~
errors/types.peb:8:15: error: unknown type 'boolean'
    var flag: boolean = true;
              ^~~~~~~
errors/types.peb:9:8: error: a condition must be a 'bool', not 'i64'
    if wide {
       ^~~~
...
errors/types.peb:15:15: error: cannot negate a value of type 'u8'
    let neg = -small;
              ^~~~~~
errors/types.peb:16:13: error: cannot convert 'i64' to 'bool' with 'as'; compare it with 0 instead
    let t = 1 as bool;
            ^~~~~~~~~
...
errors/types.peb:18:19: error: this call returns nothing, so its result cannot be used
    let nothing = main();
                  ^~~~~~
```

(The two `...` hide `'!' needs a 'bool'`, `'&&' needs 'bool' operands` and `expected '*u8',
found 'i64'` for `let s: *u8 = 65;`.) Ten mistakes, ten errors. Line 8's unknown type makes
`flag` `invalid`, and nothing else mentions it. The last error comes from `checkValue`, a
wrapper around `checkExpr` for places that need a value: a `void` call is fine as a statement
(`printf(...)` throws its result away, and so may `main()`), but not as a value.

Calls are checked argument by argument against the parameters, and the count against the
declaration, with a note pointing at it:

```console
$ ../zig-out/bin/pebc check errors/calls.peb
errors/calls.peb:8:5: error: 'add' takes 2 arguments, but 1 was given
    add(1);
    ^~~~~~
errors/calls.peb:3:4: note: 'add' is declared here
fn add(a: i64, b: i64) i64 {
   ^~~
...
errors/calls.peb:14:12: error: expected 'i64', found '*u8'
    add(1, "two");
           ^~~~~
```

(`...` stands for four more errors: three arguments to `add`, none to `printf`, calling a
variable, and an unknown function.) Arguments after a variadic `...` are checked for being
values but match nothing, which is why printf's format strings stay unchecked.

## Rules that aren't about types

Some rules can't be written in the grammar and aren't about types either. The checker is the
natural place for them, because it is the last phase that may report errors.

**Every path returns.** A function with a return type must end in a `return` on every path.
`alwaysReturns` answers that for a list of statements:

```zig
/// Does running these statements always end in a `return`?
fn alwaysReturns(stmts: []const *Stmt) bool {
    for (stmts) |s| switch (s.kind) {
        .@"return" => return true,
        .block => |b| if (alwaysReturns(b.stmts)) return true,
        .@"if" => |i| if (i.@"else") |e| {
            if (alwaysReturns(i.then.stmts) and alwaysReturns(&.{e})) return true;
        },
        // `while true { ... }` only ends through a break or a return.
        .@"while" => |w| if (w.cond.kind == .bool and w.cond.kind.bool and !hasBreak(w.body.stmts)) return true,
        else => {},
    };
    return false;
}
```

- A statement list returns if *any* statement in it returns: everything after that is dead.
- An `if` returns only if it has an `else` and *both* branches return.
- A `while true` with no `break` never falls out of the bottom: the only way out is a
  `return`. Any other `while` might run zero times, so it doesn't count. `hasBreak` looks for a
  `break` of *this* loop, so it does not search inside nested `while`s.

The analysis is conservative. `if n < 0 { return -1; } if n >= 0 { return 1; }` always returns,
but the checker doesn't know arithmetic, so it asks for a `return` at the end. Java, C# and
Rust make the same trade, for the same reason: deciding exactly which paths can run is
undecidable in general.

**`return` matches the function**, and **`main` has one of two shapes**: no parameters, and a
return type of `i32` or nothing (the code generator returns 0 for you). `break` and `continue`
must be inside a loop, which the checker tracks with a `loop_depth` counter. The golden test:

```console
$ ../zig-out/bin/pebc check errors/returns.peb
errors/returns.peb:7:1: error: missing 'return' at the end of 'sign', which returns 'i64'
}
^
errors/returns.peb:10:5: error: 'twice' must return a value of type 'i64'
    return;
    ^~~~~~~
errors/returns.peb:14:12: error: 'hello' returns nothing, so 'return' cannot have a value
    return 1;
           ^
errors/returns.peb:22:11: error: 'main' must return 'i32' or nothing, not 'i64'
fn main() i64 {
          ^~~
```

The "missing return" error points at the closing brace, because that is where the function
falls off. `errors/returns.peb` also contains `fn forever() i32 { while true { } }`, which
produces no error: it never returns at all, so it never returns the wrong thing. The code
generator ends such a function with `hlt`, the QBE instruction for a point that is never
reached (it stops the program if it is).

## Generating typed code

The code generator was rewritten for this chapter, and became simpler. It no longer reports
errors, so every `catch`/`fail` path is gone, and lookups are replaced by `e.sym`. What it
gains is a series of decisions driven by `e.type`.

**Temporaries.** `i64` and pointers live in `l` temporaries, everything else in `w`
(`Type.base`). Parameters, return values and call arguments use the same rule, so
`average(a: u8, b: u8) u8` becomes `function w $average(w %a, w %b)`. A `u8` passed to printf
is a `w` holding the byte's value, which is what C's "default argument promotions" do to a
`char` (they widen it to `int`), so `%d` prints it.

**Stack slots and memory.** `declare` makes a slot as big as the type, aligned to at least 4
(QBE's smallest `alloc`): `%b.1 =l alloc4 1` for a `u8`, `alloc8 8` for an `i64`. Two small
functions pick the memory instruction from the size:

| size | `storeSuffix` | `loadOp` |
|---|---|---|
| 1 (`u8`) | `storeb` | `loadub` (fills bits 8 to 31 with zeros) |
| 4 (`i32`, `bool`) | `storew` | `loadw` |
| 8 (`i64`, `*T`) | `storel` | `loadl` |

**Signed or unsigned.** QBE has no unsigned *types*. A `w` is 32 bits; whether they mean
-1 or 4294967295 is decided by the instruction that uses them: `div` or `udiv`, `rem` or
`urem`, `csltw` or `cultw`, `loadsb` or `loadub`, `extsw` or `extuw`. Real CPUs work the same
way: x86-64 has `idiv` and `div`, `jl` and `jb`. `examples/ch05/signs.ssa` shows one bit
pattern read both ways:

`examples/ch05/signs.ssa`

```
# The same bits, read two ways. QBE has no signed or unsigned types:
# the instruction decides.
data $byte = { b 200 }
data $fmt = { b "%-6s signed %11d   unsigned %11u", b 10, b 0 }
data $cmp = { b "x < 1", b 0 }
data $div = { b "x / 2", b 0 }
data $load = { b "byte", b 0 }

export function w $main() {
@start
	%x =w sub 0, 1                  # all 32 bits set
	%slt =w csltw %x, 1             # -1 < 1
	%ult =w cultw %x, 1             # 4294967295 < 1
	call $printf(l $fmt, ..., l $cmp, w %slt, w %ult)
	%sdiv =w div %x, 2
	%udiv =w udiv %x, 2
	call $printf(l $fmt, ..., l $div, w %sdiv, w %udiv)
	%sb =w loadsb $byte             # copies bit 7 into bits 8..31
	%ub =w loadub $byte             # fills bits 8..31 with zeros
	call $printf(l $fmt, ..., l $load, w %sb, w %ub)
	ret 0
}
```

```console
$ cd examples/ch05
$ make signs
qbe -o signs.s signs.ssa
cc -o signs signs.s
$ ./signs
x < 1  signed           1   unsigned           0
x / 2  signed           0   unsigned  2147483647
byte   signed         -56   unsigned         200
```

`u8` is Pebble's only unsigned type, so `genBinary` has one flag, `const unsigned = t ==
.u8;`, and uses it to choose `cult`/`cule`/`cugt`/`cuge` over `cslt`/..., and `udiv`/`urem` over
`div`/`rem`. The comparison instruction also names its operand type: `{s}{c}` builds `csltl`
for two `i64`s and `cultw` for two `u8`s.

**Wrapping at 8 bits.** A `u8` lives in a `w`, so `200 + 100` computes 300 in 32 bits. A byte
would hold 44. `genBinary` cuts the result back after `+`, `-` and `*`:

```zig
        // A u8 lives in a 32-bit temporary; cut the result back to 8 bits
        // so that 200 + 100 is 44, as it would be in a byte.
        if (unsigned and (b.op == .add or b.op == .sub or b.op == .mul)) {
            return g.result(.u8, "and {f}, 255", .{v});
        }
```

Division and remainder can't make a `u8` bigger, and comparisons produce a `bool`, so they need
no mask. `i32` needs nothing at all: `w` arithmetic already wraps at 32 bits.

Why not skip the mask and let `storeb` drop the high bits? Because the value isn't always
stored. In `(b + 100) / 2` the sum goes straight into `udiv`, and 300 / 2 is 150, while
44 / 2 is 22. The value of a `u8` expression must be correct in the temporary, not just in
memory.

**Casts.** `genCast` converts between integer types:

```zig
    /// `x as T`. The checker only allows integer and bool conversions.
    fn genCast(g: *CodeGen, v: Value, from: Type, to: Type) Error!Value {
        if (v == .int) return .{ .int = castInt(v.int, to) };
        if (to == .u8 and from != .u8 and from != .bool) return g.result(.u8, "and {f}, 255", .{v});
        if (to == .i64 and from != .i64) {
            // Widen: i32 copies its sign bit into the new high bits; u8
            // and bool are never negative, so they get zeros.
            return g.result(.i64, "{s} {f}", .{ if (from == .i32) "extsw" else "extuw", v });
        }
        // Narrow i64 to i32 by keeping the low 32 bits. (`=w copy` would
        // also do it, but when QBE 1.2 knows the value is a constant it
        // emits it untruncated, and the assembler warns.)
        if (to == .i32 and from == .i64) return g.result(.i32, "and {f}, 4294967295", .{v});
        // Everything else (u8 or bool to i32, ...) has the same bits.
        return v;
    }
```

- To `u8`: keep the low 8 bits. A `bool` is already 0 or 1.
- To `i64`: widen. `extsw` (extend signed word) copies bit 31 into bits 32 to 63, so -1 stays
  -1. `extuw` fills them with zeros, right for `u8` and `bool`.
- `i64` to `i32`: keep the low 32 bits.
- `u8` or `bool` to `i32`: the `w` already holds the right bits.

A constant is converted at compile time by `castInt`, with Zig's `@truncate` doing the work:
`.u8 => @as(u8, @truncate(@as(u64, @bitCast(n))))`, `.i32 => @as(i32, @truncate(n))`.
`castInt` must agree exactly with what `genCast` does at run time, which is the kind of rule
Chapter 8's differential tests are built to check.

### Three QBE details

The comment about `=w copy` in `genCast` hides a story. There are several ways to write "the
low 32 bits of this `l`" in QBE, and they don't all behave the same. `examples/ch05/` has one
file per finding.

`examples/ch05/wc.ssa`

```
# Two ways to cut a 64-bit value down to 32 bits.
data $fmt = { b "%d %d", b 10, b 0 }
export function w $main() {
@start
	%n.1 =l alloc8 8
	storel 5000000000, %n.1
	%.1 =l loadl %n.1
	%.2 =w copy %.1                 # QBE knows %.1 is a constant...
	%.3 =w and %.1, 4294967295      # ...and here it folds the and
	call $printf(l $fmt, ..., w %.2, w %.3)
	ret 0
}
```

```console
$ make wc
qbe -o wc.s wc.ssa
cc -o wc wc.s
wc.s: Assembler messages:
wc.s:15: Warning: 0x000000012a05f200 shortened to 0x000000002a05f200
$ ./wc
705032704 705032704
$ grep -n 'movl \$[1-9]' wc.s
14:	movl $705032704, %edx
15:	movl $5000000000, %esi
```

QBE propagated the stored constant into both instructions. For `and` it folded the result to
705032704. For `copy` it passed 5000000000 through unchanged, and wrote `movl $5000000000` into
the assembly: a 32-bit move with a 64-bit constant. The assembler truncates it and warns. The
program is right, but a compiler whose output makes the assembler warn on every build is not.
pebc uses `and`.

At run time, when QBE can't see the value, `=w copy` of an `l` does keep the low 32 bits.
`examples/ch05/ty2.ssa` passes 4294967301 (2^32 + 5) and -1 to a function `$trunc(l %x)` that
returns `%n =w copy %x`; `./ty2` prints `5` and `-1`.

And the third: `extsw` takes a `w`. Giving it an `l` is a type error *in QBE*, which checks its
own IL. `examples/ch05/tr.ssa` loads an `l` with `%n =l loadl %s` and then, on line 8, writes
`%w =w extsw %n`:

```console
$ make tr
qbe -o tr.s tr.ssa
qbe:tr.ssa:11: invalid instruction type in extsw
make: *** [Makefile:10: tr.s] Error 1
```

Line 11 is the function's closing `}`, not the `extsw` on line 8: QBE checks the types of a
function after it has parsed all of it, and reports the line it had reached.

That is why `genCast` never sign-extends an `i64`: there is nothing to extend. `make` builds
`wc`, `ty2` and `signs`; `make tr` is kept out of `all` because it fails on purpose, and `make
clean` removes everything built.

## Reading QBE's output

`tests/run/types.peb` exercises all of it. Besides `printf` and `putchar` it declares
`average(a: u8, b: u8) u8`, which returns `a / 2 + b / 2`, and `shout(c: u8) u8`, which
returns `c - 32` for a lowercase letter and `c` otherwise. Its `main`:

```
fn main() {
    let b: u8 = 200;
    printf("%d %d %d\n", b + 100, b * 2, 3 as u8 - 4);
    printf("%d\n", average(250, 240));

    let big: i32 = 2147483647;
    printf("%d %d\n", big + 1, -big - 1);

    let n = 5000000000;
    printf("%d %d %ld\n", n as i32, n as u8, (n as i32) as i64);
    printf("%ld %ld\n", -1 as i32 as i64, 255 as u8 as i64);
    printf("%ld\n", (true as i64) + (false as i64) * 10);

    var c = 'a';
    while c <= 'e' {
        putchar(shout(c) as i32);
        c = c + 1;
    }
    putchar('\n');
}
```

```console
$ cd project/ch05/tests
$ ../zig-out/bin/pebc build run/types.peb -o types && ./types
44 144 255
245
-2147483648 -2147483648
705032704 0 705032704
-1 255
1
ABCDE
```

Line by line:

- `200 + 100` is 300, which is 44 in 8 bits; `200 * 2` is 400, which is 144; `3 as u8 - 4`
  is -1, which is 255. Note that `4` became a `u8` because `3 as u8` is one.
- `average(250, 240)` halves first, so it never overflows: 125 + 120 = 245.
- `big + 1` wraps from the largest `i32` to the smallest, because `i32` arithmetic is `w`
  arithmetic. `-big - 1` gets to the same number without overflowing.
- 5000000000 is `0x12A05F200`. As an `i32` it keeps `0x2A05F200` = 705032704; as a `u8`, the
  low byte `0x00`. Widening the `i32` back to `i64` with `extsw` gives 705032704 again,
  because bit 31 of `0x2A05F200` is 0.
- `-1 as i32 as i64` is -1 (`extsw` copies the sign); `255 as u8 as i64` is 255 (`extuw`).
- `true as i64` is 1.
- `c` is a `u8` because `'a'` is one; `shout` subtracts 32 from lowercase letters.

The IL for `average`:

```console
$ ../zig-out/bin/pebc ir run/types.peb
function w $average(w %a, w %b) {
@start
	%a.1 =l alloc4 1
	%b.2 =l alloc4 1
	storeb %a, %a.1
	storeb %b, %b.2
	%.1 =w loadub %a.1
	%.2 =w udiv %.1, 2
	%.3 =w loadub %b.2
	%.4 =w udiv %.3, 2
	%.5 =w add %.2, %.4
	%.6 =w and %.5, 255
	ret %.6
}
```

One-byte slots (`alloc4 1`), `storeb`/`loadub`, `udiv` and the `and 255` after `add`. Further
down, `n as i32` and `n as u8` are `and %.18, 4294967295` and `and %.20, 255`. Now the assembly
QBE made of it:

```console
$ ../zig-out/bin/pebc ir run/types.peb > types.ssa && qbe types.ssa
average:
	pushq %rbp
	movq %rsp, %rbp
	movzbl %dil, %eax
	movl $2, %ecx
	movl $0, %edx
	divl %ecx
	movl %eax, %ecx
	movzbl %sil, %eax
	movl $2, %esi
	movl $0, %edx
	divl %esi
	addl %ecx, %eax
	andl $255, %eax
	leave
	ret
```

(Only `average` shown.) The slots are gone: QBE saw that their addresses never escape and
kept the values in registers, as it did for `i64`s in Chapter 4. What remains of
`storeb`/`loadub` is `movzbl %dil, %eax`, "move a zero-extended byte to a long": the low byte
of the first argument register, widened with zeros. That is the `u8`-ness of `a`, in one
instruction.

Then two `divl`s. Unsigned division by 2 is a right shift by one bit, and a shift is one of
the cheapest instructions a CPU has while `div` is one of the slowest. QBE doesn't make that
substitution (it is called *strength reduction*). GCC does, for the same
function in C:

```console
$ cat average.c
unsigned char average(unsigned char a, unsigned char b) {
    return a / 2 + b / 2;
}
$ gcc -O2 -S -o - average.c | sed -n '/^average:/,/ret/p'
average:
.LFB0:
	.cfi_startproc
	endbr64
	shrb	%dil
	shrb	%sil
	leal	(%rdi,%rsi), %eax
	ret
```

That is not a bug in QBE; it is the price of its design goal, 70% of the performance of
industrial compilers in 10% of the code. Chapter 9 measures what QBE does and doesn't do for
us.

`shout` shows the comparisons: `cugew %.2, 97` became `cmpl $97, %eax` and `setae`, "set if
above or equal", the unsigned condition. A signed `>=` would have been `setge`.

## The project at the end of the chapter

```
project/ch05/src/
  types.zig     86 lines (new)  Type, size, fits, base, format
  check.zig    495 lines (new)  names, types, returns, main; unit tests
  ast.zig      193              + TypeExpr, Symbol, Expr.type/sym, Cast
  parser.zig   539              + parseType, ': type', return types, 'as'
  print.zig    168              prints types in `pebc ast`
  codegen.zig  439              rewritten: typed, reports no errors
  main.zig     144              + `pebc check`
```

The tests gain `run/types`, `errors/types` and `errors/returns`. Every other test program got
type annotations; `errors/calls.peb` gained `add(1, "two")`.

```console
$ cd project/ch05
$ zig build test --summary all
...
golden: 24 passed, 0 failed
Build Summary: 6/6 steps succeeded; 17/17 tests passed
test success
+- run test 17 pass (17 total) 10ms MaxRSS:4M
|  +- compile test debug native success 984ms MaxRSS:160M
+- run exe golden (golden) success 456ms
   +- compile exe golden debug native success 714ms MaxRSS:152M
   +- compile exe pebc debug native success 842ms MaxRSS:158M
```

(Timings from this machine; yours will differ.) The usage message that `pebc` prints with no
arguments gains one line: `check   check FILE for errors without compiling it`.

## Summary

- A **type** tells the compiler sizes (how many bytes to load, store and allocate),
  operations (signed or unsigned instructions) and mistakes (caught before the program runs).
  B had one type, the word; C added types to cope with bytes on the PDP-11.
- Pebble writes types after names (`x: i64`, `fn f() i32`, `let b: u8 = 200`); `e as T` binds
  tighter than any binary operator.
- `Type` is a tagged union; `size`, `fits`, `base` (`w` or `l`) and `format` (`{f}`) answer
  the questions the other phases ask.
- The **checker** runs between parser and code generator. Pass 1 declares every function, pass
  2 checks bodies, so order doesn't matter. Variables live on a **scope stack** searched from
  the innermost end; `let` declares its name after checking its value.
- Results go **into the tree**: `Expr.type`, `Expr.sym`. The code generator trusts them and
  reports no errors.
- **Literals take the type the context wants**; otherwise there are **no implicit
  conversions**. Conditions must be `bool`.
- The **`invalid` type** absorbs follow-on errors: one mistake, one message.
- `alwaysReturns` is a conservative check that every path returns; `while true` without
  `break` counts.
- QBE has no unsigned types: the **instruction** decides (`udiv`, `cultw`, `loadub`,
  `extuw`). A `u8` lives in a `w` and is cut back to 8 bits with `and 255`; `i64` to `i32` is
  `and 4294967295`, never a constant `=w copy`.

## Exercises

1. **Add `u32`.** Add an unsigned 32-bit type. `let max: u32 = 4294967295;` should give
   `max + 1` = 0, `max / 2` = 2147483647, `max > 1` true, `max as i64` = 4294967295, and
   `-1 as u32 as i64` = 4294967295. Start by adding `u32` to the `Type` union and building:
   let the compiler tell you what else to change.

<details><summary>Solution</summary>

After adding `u32,` to the union, `zig build` stops at the first `switch` that doesn't handle
it:

```console
$ zig build
...
src/types.zig:39:16: error: switch must handle all possibilities
        return switch (t) {
               ^~~~~~
src/types.zig:11:5: note: unhandled enumeration value: 'u32'
...
```

That is `size`. Exhaustive switches turn "find every place that needs to know about the new
type" into a list of compile errors. Not every place is a switch, though: `isInteger` has an
`else` and compiles fine while being wrong. The complete change:

```diff
--- src/types.zig
     u8,
+    u32,
@@ pub fn isInteger(t: Type) bool {
-            .i64, .i32, .u8 => true,
+            .i64, .i32, .u8, .u32 => true,
@@ pub fn size(t: Type) u64 {
-            .bool, .i32 => 4,
+            .bool, .i32, .u32 => 4,
@@ pub fn fits(t: Type, value: u64) bool {
             .u8 => value <= std.math.maxInt(u8),
+            .u32 => value <= std.math.maxInt(u32),
--- src/check.zig (resolveType)
-                const named = std.meta.stringToEnum(enum { i64, i32, u8, bool }, name) orelse {
+                const named = std.meta.stringToEnum(enum { i64, i32, u8, u32, bool }, name) orelse {
@@
                     .u8 => .u8,
+                    .u32 => .u32,
--- src/codegen.zig
-        const unsigned = t == .u8;
+        const unsigned = t == .u8 or t == .u32;
@@
-        if (unsigned and (b.op == .add or b.op == .sub or b.op == .mul)) {
+        if (t == .u8 and (b.op == .add or b.op == .sub or b.op == .mul)) {
@@ fn genCast
-        if (to == .i32 and from == .i64) return g.result(.i32, "and {f}, 4294967295", .{v});
+        if ((to == .i32 or to == .u32) and from == .i64) return g.result(to, "and {f}, 4294967295", .{v});
@@ fn castInt
         .i32 => @as(i32, @truncate(n)),
+        .u32 => @as(u32, @truncate(@as(u64, @bitCast(n)))),
```

`isSigned` and `base` need nothing: `u32` is not signed, and it lives in a `w`. The mask after
`+` stays `u8`-only, because `w` arithmetic already wraps at 32 bits. Widening to `i64` already
uses `extuw` for everything that isn't `i32`.

`u32.peb` prints `max + 1`, `max / 2` and `max > 1` with `"%u %u %d\n"`, then `max as i64`
and `-1 as u32 as i64` with `%ld`, then `big as u32` for `let big: i64 = 4294967296 + 7;`:

```console
$ zig-out/bin/pebc build u32.peb && ./u32
0 2147483647 1
4294967295 4294967295
7
```

The IL has `udiv %.3, 2`, `cugtw %.5, 1` and `extuw`, and the tests still pass. With `div`
instead of `udiv`, `max / 2` would print 0 (it is -1 / 2 in signed arithmetic), and with
`csgtw`, `max > 1` would be false.

</details>

2. **Allow `as bool`.** Make `n as bool` legal for every integer type, meaning `n != 0`.
   `var n = 6; while n as bool { printf("%ld ", n); n = n - 2; }` should print `6 4 2`.
   What does `4294967296 as bool` give, and why is that not Chapter 4's `jnz` trap?

<details><summary>Solution</summary>

In the checker, the error becomes a success:

```diff
-                if (to == .bool and from.isInteger()) {
-                    return c.fail(e.span, "cannot convert '{f}' to 'bool' with 'as'; compare it with 0 instead", .{from});
-                }
+                // Nonzero is true, as in C.
+                if (to == .bool and from.isInteger()) return .bool;
```

In the code generator, a comparison with 0, and the same rule for constants:

```diff
         if (v == .int) return .{ .int = castInt(v.int, to) };
+        if (to == .bool and from != .bool) return g.result(.bool, "cne{c} {f}, 0", .{ from.base(), v });
@@ fn castInt
         .i32 => @as(i32, @truncate(n)),
+        .bool => @intFromBool(n != 0),
```

The `errors/types.peb` golden test contains `let t = 1 as bool;` to test the old error. Delete
that line and regenerate `errors/types.err` with `pebc check errors/types.peb 2>
errors/types.err` (from `tests/`).

`asbool.peb` runs the loop from the task, then, with `let big = 4294967296;` and
`let small: u8 = 0;`, prints `big as bool`, `4294967296 as bool`, `(300 as u8) as bool` and
`small as bool`:

```console
$ zig-out/bin/pebc build asbool.peb && ./asbool
6 4 2 
1 1 1 0
```

The loop condition became `%.2 =w cnel %.1, 0`; `small as bool` became `cnew` (a `u8` is a
`w`); the three constants were converted by `castInt`. `4294967296 as bool` is 1. Its low 32
bits are all zero, so `jnz` on that `l` would take the false branch (gotcha 5). But `cnel`
compares all 64 bits with zero and produces a `w` that is 0 or 1, and `jnz` only ever sees
that. `(300 as u8) as bool` is 1 because 300 as `u8` is 44. The checker's rule that conditions
are `bool` is what makes the generated code safe: a condition is always a comparison result.

</details>

3. **Warn about unused variables.** Report `warning: 'x' is never used` for every variable and
   parameter that is never read. Names starting with `_` are exempt, so a parameter can be
   kept for its position. Warnings don't stop compilation. Which tests break, and why?

<details><summary>Solution</summary>

Diagnostics get a third severity, symbols a flag, and the checker sets the flag whenever an
expression names the symbol:

```diff
--- src/diag.zig
-pub const Severity = enum { @"error", note };
+pub const Severity = enum { @"error", warning, note };
--- src/ast.zig (Symbol)
     mutable: bool = false,
+    /// Set when an expression names this symbol.
+    used: bool = false,
--- src/check.zig (typeOf, the .name case)
                 e.sym = sym;
+                sym.used = true;
                 return sym.type;
```

When a scope ends, every symbol declared in it is checked. Blocks end in `checkBlock`; the
function's own scope (its parameters and top-level variables) ends in `checkFunction`, and
starts at 0 because the scope stack is cleared for each function:

```zig
    /// Warns about the variables declared since `start` that nothing reads.
    fn warnUnused(c: *Checker, start: usize) Error!void {
        for (c.scope.items[start..]) |sym| {
            if (sym.used or std.mem.startsWith(u8, sym.name, "_")) continue;
            try c.diags.add(.warning, sym.span, "'{s}' is never used", .{sym.name});
        }
    }
```

```diff
@@ fn checkFunction
         try c.checkStmts(body.stmts);
+        try c.warnUnused(0);
@@ fn checkBlock
         try c.checkStmts(b.stmts);
+        try c.warnUnused(scope_start);
--- src/main.zig
     if (diags.hasErrors()) return fail(diags, stderr);
+    try diags.render(stderr); // warnings
     if (command == .check) return 0;
```

`renderOne` prints the severity with `{t}` (the tag name), so `warning` needs no new printing
code. An assignment `x = 5` also sets `used`, because the target is checked as an expression;
a stricter version would mark only reads.

`w.peb` defines `fn area(width: i64, height: i64, _unit: i64) i64` returning
`width * width`; its `main` declares `let count = 3;`, an inner block with `let total = 10;`,
and prints `count + area(1, 2, 3)`:

```console
$ zig-out/bin/pebc build w.peb && ./w; echo "exit $?"
w.peb:3:21: warning: 'height' is never used
fn area(width: i64, height: i64, _unit: i64) i64 {
                    ^~~~~~
w.peb:10:13: warning: 'total' is never used
        let total = 10;
            ^~~~~
4
exit 0
```

`area` returns `width * width`: the warning found a real bug in this little program. Five
golden tests break (`errors/calls`, `names`, `pointer`, `returns`, `types`), because their
programs have variables that exist only to carry an error, and failing compilations print
warnings too. One unit test breaks: `literals take their type from the context` expects no
output for `let b: u8 = 200; let c = b + 55; let d: i32 = -1 * 7;`, where `c` and `d` are never
read. Rename them to `_c` and `_d`, and the `b` of its second program to `_b` (its expected
error moves one column, to `t.peb:1:26`), and regenerate the five `.err` files with
`pebc ir errors/NAME.peb 2> errors/NAME.err`. Read the diff before accepting it: each change
should be a new `warning:` block and nothing else. Then all 24 golden and 17 unit tests pass.

</details>

4. **"Did you mean ...?"** When a name is unknown, suggest a variable in scope with a similar
   name, as a note at its declaration. `cuont` should suggest `count`, and `xx` should suggest
   `x`, but `y` should not suggest `x`. Use the Levenshtein edit distance: the fewest one-letter
   insertions, deletions and substitutions that turn one string into the other.

<details><summary>Solution</summary>

The distance by dynamic programming, keeping one row of the table: `row[j]` is the distance
between the first `i` letters of `a` and the first `j` letters of `b`.

```zig
/// Levenshtein distance: the fewest one-letter insertions, deletions and
/// substitutions that turn `a` into `b`. Names longer than 64 bytes are
/// never suggested.
fn editDistance(a: []const u8, b: []const u8) usize {
    if (b.len > 64) return std.math.maxInt(usize);
    // row[j] is the distance between the first i letters of a and the
    // first j letters of b.
    var row: [65]usize = undefined;
    for (0..b.len + 1) |j| row[j] = j;
    for (a, 1..) |ca, i| {
        var corner = row[0]; // the old row[j - 1]
        row[0] = i;
        for (b, 1..) |cb, j| {
            const above = row[j];
            row[j] = @min(above + 1, row[j - 1] + 1, corner + @intFromBool(ca != cb));
            corner = above;
        }
    }
    return row[b.len];
}
```

`above + 1` deletes a letter of `a`, `row[j - 1] + 1` inserts a letter of `b`, and `corner`
plus 0 or 1 keeps or substitutes. A `test editDistance` block checks kitten/sitting (3),
cuont/count (2) and two empty strings (0). (The first draft called `corner` `diag`, and Zig refused:
`local variable shadows declaration of 'diag'`, the import at the top of `check.zig`. Zig
never lets a local hide an outer name.)

A method `closest(c, name) ?*Symbol` walks the scope stack from the innermost end, computes
`editDistance(name, sym.name)` for each symbol, and keeps the nearest one whose distance is
below `best_distance`, which starts at `(name.len + 1) / 3 + 1`. That allows about one edit
per three letters, `(len + 1) / 3`, so one-letter names get no suggestion at all. The `.name`
case adds the note:

```diff
-                    return c.fail(e.span, "unknown name '{s}'", .{name});
+                    try c.diags.err(e.span, "unknown name '{s}'", .{name});
+                    if (c.closest(name)) |sym| try c.diags.add(.note, sym.span, "did you mean '{s}'?", .{sym.name});
+                    return .invalid;
```

```console
$ zig-out/bin/pebc build w.peb; echo "exit $?"
w.peb:10:21: error: unknown name 'xx'
    printf("%ld\n", xx + y);
                    ^~
w.peb:8:9: note: did you mean 'x'?
    let x = 1;
        ^
w.peb:10:26: error: unknown name 'y'
    printf("%ld\n", xx + y);
                         ^
w.peb:11:21: error: unknown name 'cuont'
    printf("%ld\n", cuont + area(1, 2, 3));
                    ^~~~~
w.peb:9:9: note: did you mean 'count'?
    let count = 3;
        ^~~~~
exit 1
```

(This `w.peb` declares `let x = 1;` and `let count = 3;` in `main` and uses `xx + y` and
`cuont`.) `errors/names.peb` misspells `count` the same way, so its golden output gains the
note; regenerate it and all tests pass.

`cuont` is distance 2 from `count`: swapping two neighbouring letters costs two substitutions
in plain Levenshtein. The **Damerau-Levenshtein** variant counts a swap of neighbours as one
edit. rustc's suggestions use it: `compiler/rustc_span/src/edit_distance.rs` says "The current
implementation is the restricted Damerau-Levenshtein algorithm", restricted "because it does
not permit modifying characters that have already been transposed". Its version also strips a
common prefix and suffix first, and gives up early once the distance must exceed the limit.

</details>

Sources for this chapter: [REFERENCES.md](REFERENCES.md#chapter-5--names-and-types)
