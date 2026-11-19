# Chapter 6 — Pointers and Arrays

Until now every Pebble variable was a value in a stack slot that only its own name could
reach. This chapter lets programs talk about *memory*: `&x`, the address of a variable; `*p`,
the memory a pointer points to; fixed-size arrays `[N]T` and indexing `a[i]`; and global
variables that live in the executable instead of on the stack. In the compiler there is one
new idea, `genAddr`, which works out *where* a place in memory is. Reading, assigning and `&`
are all built on it. With arrays come strings you can walk byte by byte and the sieve of
Eratosthenes, and with them the first Pebble programs that can corrupt their own memory without
a word of warning. We will look at exactly how that happens.

Previous: [Chapter 5](05-names-and-types.md). Next: [Chapter 7](07-structs-and-libc.md).

## Memory in QBE

Pebble has used memory since Chapter 4. Every variable gets a stack slot, `%x.1 =l alloc8 8`,
and every read and write is a `load` or a `store` through that slot's address. Programs just
couldn't *see* the address. Before giving them `&`, here is everything this chapter needs from
QBE, in one hand-written file:

`examples/ch06/memory.ssa`

```
# Memory in QBE: a global array, a stack slot, loads and stores.
data $nums = { l 10 20 30 }
data $fmt = { b "nums[2] = %ld, x = %ld", b 10, b 0 }

export function w $main() {
@start
	%x =l alloc8 8          # 8 bytes on the stack; %x is their address
	storel 5, %x
	%p =l add $nums, 16     # the address of nums[2]: 2 * 8 bytes in
	storel 31, %p
	%a =l loadl %p
	%b =l loadl %x
	call $printf(l $fmt, ..., l %a, l %b)
	ret 0
}
```

- `data $nums = { l 10 20 30 }` reserves 24 bytes in the executable, three `l` (8-byte)
  values. In the IL, `$nums` is not the array: it is the *address* of its first byte. That is
  true of every `$` name, functions included, and it is why `$fmt` can be passed to printf
  as an `l`.
- `alloc8 8` reserves 8 bytes on the stack and puts their address in `%x`. The QBE manual
  explains the number in the name: "The number ending the instruction name is the alignment
  required for the allocated slot." There are three: `alloc4`, `alloc8` and `alloc16`. The
  operand is the size.
- An address is just an `l`, so arithmetic on it is ordinary `add`. `nums[2]` is 2 elements of
  8 bytes past the start: `add $nums, 16`.
- `storel` and `loadl` write and read 8 bytes at an address.

```console
$ cd examples/ch06
$ make
qbe -o memory.s memory.ssa
cc -o memory memory.s
./memory
nums[2] = 31, x = 5
...
```

(`make` then builds Chapter 6's pebc and prints the IL for `swap.peb`, which we will meet
below; `make clean` removes what it built.) The assembly QBE made for `main` is shorter than
the IL:

```
main:
	pushq %rbp
	movq %rsp, %rbp
	movq $31, nums+16(%rip)
	movl $5, %edx
	movl $31, %esi
	leaq fmt(%rip), %rdi
	movl $0, %eax
	callq printf
	movl $0, %eax
	leave
	ret
```

The stack slot is gone. QBE saw that `%x` never leaves the function, so it kept the 5 in a
register, and it forwarded both stores to the loads that follow them: `%a` is known to be 31,
`%b` to be 5. The store into `nums` stays, because `nums` is memory that other code could read.
`nums+16(%rip)` is the x86-64 way of writing "the address of `nums`, plus 16".

That is the whole plan for this chapter. Pebble variables already have addresses (`%x.1`), and
global variables will get `$x` addresses. `&x` hands the address to the program; `*p` and
`a[i]` compute an address and then load or store through it.

## Syntax

The grammar changes in three places (from the comment at the top of `parser.zig`):

```diff
     decl      = "fn" NAME params [ type ] block
               | "extern" "fn" NAME params [ type ] ";"
+              | let
-    type      = NAME | "*" type
+    type      = NAME | "*" type | "[" INT "]" type
-    stmt      = ("let" | "var") NAME [ ":" type ] "=" expr ";"
+    let       = ("let" | "var") NAME ( ":" type [ "=" expr ] | "=" expr ) ";"
+    stmt      = let
```

- **Array types.** `[N]T` is N values of type `T`, one after the other. The length comes
  first, so a type reads left to right: `[3][4]i32` is 3 rows, each of 4 `i32`s, and
  `*[10]u8` is a pointer to an array of 10 bytes. C writes `int t[3][4]` with the name in the
  middle, which is where its famous spiral reading rule comes from. Zig uses the same order as
  Pebble.
- **Global variables.** A `let` or `var` may appear outside any function.
- **A `var` without a value**, `var buf: [64]u8;`, starts as zeros. Without a type, the
  value is required: it is the only thing the type could come from.

`&e`, `*e` and `a[i]` have parsed since Chapter 3; the checker has rejected them until now.
`ast/pointers.peb` shows the shapes the printer produces:

```console
$ cd project/ch06/tests
$ cat ast/pointers.peb
var grid: [3][4]u8;
let answer = 42;

fn main() {
    var a: [10]i64;
    var p: *i64 = &a[2];
    *p = **q + a[i][j];
    var r = &(*p)[0];
    let s = -*p * 2;
}
$ ../zig-out/bin/pebc ast ast/pointers.peb
(var grid [3][4]u8)
(let answer 42)
(fn main ()
  (var a [10]i64)
  (var p *i64 (& (index a 2)))
  (= (* p) (+ (* (* q)) (index (index a i) j)))
  (var r (& (index (* p) 0)))
  (let s (* (- (* p)) 2)))
```

(This file is only parsed, never checked, so `q`, `i` and `j` needn't exist.) `a[i][j]` is
`(index (index a i) j)`: index `a` with `i`, which gives a row, and index the row with `j`.
Postfix `[...]` binds tighter than prefix `*`, so `*p[0]` would mean `*(p[0])`; that is why
`r` needs parentheses.

The new `.l_bracket` case of `parseType` expects an integer token, a `]`, and then calls
`parseType` again for the element type, which is how `[3][4]i32` nests. The length must be an
integer literal: `[n]i64` is a parse error. Arrays whose size is known
only at run time would need memory that grows at run time; Chapter 7 gets that from `malloc`.

`let` moved into a function of its own, `letStatement`, because both `statement` and the
top-level declaration loop now call it. After a `:` and a type, the `= value` part is
optional; without a type, `expect(.equal, "':' or '='")` insists on it. `Stmt.Let.value`
became optional (`?*Expr`), and the top-level declaration loop gained one
case, `.kw_let, .kw_var => return .{ .global = try p.letStatement() }`, with a matching
`global: *Stmt` member in `ast.Decl`. A global is a `let` statement that happens to sit
outside a function, so it reuses the same node.

Error recovery needed a fix too. After a syntax error in a declaration, `skipToDeclaration`
skips tokens until something that starts a declaration. `let` and `var` start one now, but
only outside braces: a `let` inside a broken function body is part of that body. So the loop
counts brace depth, stopping at `let` or `var` only when `depth == 0`, and on `}` does
`depth -|= 1`. `-|=` is Zig's saturating subtraction: a stray `}` leaves `depth` at 0
instead of wrapping around to the largest `usize` (which in a Debug build would be a panic,
not a wrap).

## Types for memory

`Type` gains one member:

```zig
    /// `[len]T`: len values of type T, one after the other in memory.
    array: Array,
...
    pub const Array = struct { len: u64, elem: *const Type };
```

Like `pointer`, it points to its element type, so `[3][4]i32` is an array of 3 elements whose
element is an array of 4 `i32`s. Two arrays are equal when their lengths and element types
are. Three of the questions from Chapter 5 get an answer for arrays:

- `size` is `len * elem.size()`: `[3][4]i32` is 3 · 16 = 48 bytes.
- `alignment` is new: the address of a value must be a multiple of it. For a scalar it is the
  size (an `i64` at an address divisible by 8); for an array it is the element's alignment,
  because an array is only its elements, back to back. A `[16]u8` needs no alignment at all.
- `base` is `l` for an array. An array never lives in a temporary (see below); code works
  with its address, which is an `l`.

The new unit test, `"array sizes"`, builds `[2][3]i64` by hand and checks that its size is
48, its alignment 8, and that it prints as `[2][3]i64`.

## Places

Which expressions can stand on the left of `=`? Chapter 5 had one answer: a name declared
with `var`. Now `*p = 1`, `a[i] = 1` and `*a[0][1] = 1` are all legal, and `&x`, `&a[3]` and
`&(*p)[0]` all need the same property: the expression must be a **place**, something with an
address. C calls these *lvalues* ("left values"). The checker's `checkAssignable` grew into
`checkPlace`:

```zig
    /// Can `e` be assigned to, or have its address taken (`action` says
    /// which)? It must be a place in memory that may change: a `var`, an
    /// element of a `var` array, or anything reached through a pointer.
    fn checkPlace(c: *Checker, e: *const Expr, comptime action: []const u8) Error!bool {
        switch (e.kind) {
            .name => {
                const sym = e.sym.?;
                if (sym.mutable) return true;
                try c.diags.err(e.span, "cannot " ++ action ++ " '{s}', which was declared with 'let'", .{sym.name});
                try c.diags.add(.note, sym.span, "use 'var' here to make it a variable", .{});
                return false;
            },
            // An element of an array is part of the array; through a
            // pointer, it is somewhere else.
            .index => |ix| return ix.base.type != .array or try c.checkPlace(ix.base, action),
            .unary => |u| if (u.op == .deref) return true,
            else => {},
        }
        try c.diags.err(e.span, "cannot " ++ action ++ " this expression", .{});
        return false;
    }
```

- A name is a place if it was declared with `var`.
- `a[i]` on an array is part of `a`, so it is a place if `a` is: `table[r][c]` asks about
  `table[r]`, which asks about `table`.
- `p[i]` on a pointer, and `*p`, are always places: the memory is somewhere else, and `let p`
  only promises that `p` keeps pointing at the same address, not that the memory there
  never changes. `run/pointers.peb` relies on that: `let pp = &p; **pp = 42;` writes through
  a `let`. (C spells the same promise `int *const p`.)
- Anything else, like `&5` or `&f()`, has no address.

Why may you not take the address of a `let`? Because then `*p = 2` would change something
declared unchangeable. So assignment and `&` share one function, and `action` (a `comptime`
string, glued into the message with `++` at compile time) is the only difference:

```
errors/pointers.peb:15:14: error: cannot take the address of 'x', which was declared with 'let'
    var p = &x;
             ^
errors/pointers.peb:14:9: note: use 'var' here to make it a variable
    let x = 1;
        ^
```

The typing rules for the three operators, in `typeOf`, are short. `&e` checks its operand,
then `checkPlace(u.operand, "take the address of")`, and returns `pointerTo(t)`; `*p`
reports `'*' needs a pointer, not 'i64'` for anything else; and `a[i]` checks that the index
is an integer and switches on the base type:

| Expression | Rule | Type |
|---|---|---|
| `&e` | `e` is a place of type `T` | `*T` |
| `*p` | `p` is a `*T` | `T` |
| `a[i]` | `a` is a `[N]T` or a `*T`; `i` is any integer type | `T` |

The index may be any integer type, `i64`, `i32` or `u8`, so `buf[c]` works for a `u8 c`
without a cast. Pointers can be compared with `==` and `!=` (Chapter 5 allowed it already),
which is how `run/pointers.peb` prints `p == &x: 1`. In the `.index` case, the base's type
decides: `.array => |a| a.elem.*`, `.pointer => |p| p.*`, and anything else is
`cannot index a value of type 'i64'`.

Note that `&` checks its operand with `checkExpr`, not `checkValue`, and so does `.index` for
its base. Those are the two places where an array may appear whole. Everywhere else, it may
not.

## Arrays are not values

What should `let d = b;` do, for an array `b`? Or `printf("%ld", b)`? A value in pebc lives in
a QBE temporary, a `w` or an `l`, and a `[100]i64` is 800 bytes. Languages give one of three
answers:

1. **Copy it.** Zig and Rust treat an array as a value like any other: assigning or passing it
   copies every element. The compiler emits a loop or a `memcpy` behind your back.
2. **Use its address instead.** C's rule: in an expression, an array "decays" to a pointer to
   its first element. `printf("%ld", b)` prints an address; passing `b` to a function passes
   a pointer; `b = c` is an error, because an address is not a place.
3. **Refuse.** Pebble's rule, for now. `checkValue`, the wrapper around `checkExpr` for every
   place that needs a value, reports `an array cannot be used as a value; use its elements,
   or a pointer such as '&a[0]'` when the type is `.array`.

To pass an array to a function, pass `&a[0]`, a pointer to its first element, and the length
if the callee needs it. That is what C does implicitly; Pebble makes you write it. Array
parameters and array return types are refused in `declareFunction` with their own messages,
and `b = c` for two arrays gets `cannot assign a whole array; assign its elements one by one`.
Chapter 7 makes structs copyable with QBE's `blit` instruction; arrays could get the same
treatment, but a program that needs to copy an array can write the loop.

The second thing Pebble refuses is **pointer arithmetic**. In C, `p + 1` is the address of
the next element: the compiler multiplies the 1 by the element size, so `int *p` advances by 4
bytes and `char *p` by 1. Pebble has one way to name an element, `p[i]`, and one way to take
its address, `&p[i]`. `checkBinary` points there when it sees the C way:

```
errors/pointers.peb:25:13: error: '+' cannot be used on '*i64'
    let g = q + 1;
            ^
errors/pointers.peb:25:13: note: Pebble has no pointer arithmetic; for the address of element i, write '&p[i]'
    let g = q + 1;
            ^~~~~
```

Exercise 2 adds it, with C's scaling, and you will see that it is not much code. Leaving it
out keeps one way of doing each thing.

`errors/pointers.peb` collects the mistakes of this chapter. Here is some more of its golden
output:

```console
$ ../zig-out/bin/pebc check errors/pointers.peb
errors/pointers.peb:5:13: error: the value of a global variable must be a constant
var start = total;
            ^~~~~
...
errors/pointers.peb:7:14: error: an array needs at least one element
var nothing: [0]i64;
             ^~~~~~
errors/pointers.peb:9:11: error: an array cannot be passed to a function; pass a pointer to its first element
fn sum(a: [4]i64) i64 {
          ^~~~~~
...
errors/pointers.peb:21:5: error: cannot assign a whole array; assign its elements one by one
    b = c;
    ^
errors/pointers.peb:22:13: error: an array cannot be used as a value; use its elements, or a pointer such as '&a[0]'
    let d = b;
            ^
...
errors/pointers.peb:26:14: error: cannot take the address of this expression
    let h = &5;
             ^
errors/pointers.peb:27:9: error: a 'let' needs a value
    let k: i64;
        ^
errors/pointers.peb:28:21: error: an array cannot be used as a value; use its elements, or a pointer such as '&a[0]'
    printf("%ld\n", b);
                    ^
```

A `let` without a value is a parse-able but pointless thing (it would be zero forever), so the
checker rejects it, at the top level and in functions alike. A `[0]i64` is rejected because a
zero-sized slot would give two variables the same address. Chapter 5's
`errors/pointer.peb`, which tested "pebc cannot compile pointers yet", is gone.

## Generating addresses

The code generator's `Value`, the operand of a QBE instruction, gains a fourth kind:

```zig
    /// The address of a variable: its stack slot %name.id, or $name for a
    /// global.
    slot: *const Symbol,
```

It prints as `%x.3` for a local and `$x` for a global (Chapter 5 had a separate `Slot` type
that knew only locals). Either way it is an `l` holding an address, and the code that uses it
doesn't care which.

Then the new function. `genAddr` emits the instructions that compute the address of a place,
and returns it:

```zig
    /// Emits the instructions that compute the address of a place: a
    /// variable, `*p` or `a[i]`.
    fn genAddr(g: *CodeGen, e: *const Expr) Error!Value {
        switch (e.kind) {
            .name => return .{ .slot = e.sym.? },
            // The address in p is the address of *p.
            .unary => |u| return g.genExpr(u.operand),
            .index => |ix| {
                // An array is the elements themselves, so its address is
                // the address of element 0. A pointer holds that address.
                const base = if (ix.base.type == .array) try g.genAddr(ix.base) else try g.genExpr(ix.base);
                const size: i64 = @intCast(e.type.size());
                const index = try g.genExpr(ix.index);
                if (index == .int) {
                    if (index.int == 0) return base;
                    return g.result(.i64, "add {f}, {d}", .{ base, index.int * size });
                }
                // Addresses are 64 bits; widen an i32 or u8 index first.
                var offset = switch (ix.index.type) {
                    .i64 => index,
                    .i32 => try g.result(.i64, "extsw {f}", .{index}),
                    else => try g.result(.i64, "extuw {f}", .{index}),
                };
                if (size != 1) offset = try g.result(.i64, "mul {f}, {d}", .{ offset, size });
                return g.result(.i64, "add {f}, {f}", .{ base, offset });
            },
            else => unreachable, // the checker only allows places
        }
    }
```

- **A name** is its slot. No instructions at all.
- **`*p`**: the address of `*p` is the value of `p`. Computing it means evaluating `p`.
- **`a[i]`** is `base + i * size`, where `size` is the element's size (`e.type` is the element
  type). The base differs for the two kinds of thing you can index. An array *is* its
  elements, so its address is the address of element 0, found by a recursive `genAddr`. A
  pointer *holds* that address, so its value is the base: `genExpr`. That one line is the
  whole difference between `a[i]` on a `[N]T` and on a `*T`.
- A constant index is multiplied at compile time, and index 0 adds nothing.
- A variable index is widened to 64 bits first, since addresses are `l`s: `extsw` for an
  `i32` (so -1 stays -1), `extuw` for a `u8`. For bytes the `mul` is skipped.

With `genAddr` in place, the rest is a few lines. Reading a variable, `*p` or `a[i]` is a load
from its address; `&e` *is* its address:

```zig
            // A variable, `*p` and `a[i]` are all places in memory: work
            // out the address, then load from it.
            .name, .index => return g.result(t, "{s} {f}", .{ loadOp(t), try g.genAddr(e) }),
            .unary => |u| switch (u.op) {
                ...
                .addr => return g.genAddr(u.operand),
                .deref => return g.result(t, "{s} {f}", .{ loadOp(t), try g.genExpr(u.operand) }),
            },
```

and assignment stores to it:

```zig
            .assign => |a| {
                // Where first, then what: in `a[f()] = g()`, f runs first.
                const addr = try g.genAddr(a.target);
                const value = try g.genExpr(a.value);
                try g.emit("store{s} {f}, {f}", .{ storeSuffix(a.target.type), value, addr });
            },
```

The order of those two lines is a language decision. Pebble evaluates left to right, so in
`a[f()] = g()` the call `f()` comes first. C leaves the order unspecified: a C compiler may
call `g` first, and different compilers do different things.

Here is `examples/ch06/swap.peb`, which uses all of it:

```
extern fn printf(format: *u8, ...) i32;

var counter = 0;
var table: [4]i32;

fn swap(a: *i64, b: *i64) {
    let t = *a;
    *a = *b;
    *b = t;
}

fn get(i: i32) i32 {
    return table[i];
}

fn main() {
    var x = 1;
    var y = 2;
    swap(&x, &y);
    var buf: [16]u8;
    buf[3] = 'z';
    counter = counter + get(2) as i64;
    printf("%ld %ld %d\n", x, y, buf[3]);
}
```

```console
$ ../../project/ch06/zig-out/bin/pebc ir swap.peb
data $counter = { l 0 }

data $table = { z 16 }

function $swap(l %a, l %b) {
@start
	%a.1 =l alloc8 8
	%b.2 =l alloc8 8
	%t.3 =l alloc8 8
	storel %a, %a.1
	storel %b, %b.2
	%.1 =l loadl %a.1
	%.2 =l loadl %.1
	storel %.2, %t.3
	%.3 =l loadl %a.1
	%.4 =l loadl %b.2
	%.5 =l loadl %.4
	storel %.5, %.3
	%.6 =l loadl %b.2
	%.7 =l loadl %t.3
	storel %.7, %.6
	ret
}

function w $get(w %i) {
@start
	%i.1 =l alloc4 4
	storew %i, %i.1
	%.1 =w loadw %i.1
	%.2 =l extsw %.1
	%.3 =l mul %.2, 4
	%.4 =l add $table, %.3
	%.5 =w loadw %.4
	ret %.5
}

export function w $main() {
@start
	%x.1 =l alloc8 8
	%y.2 =l alloc8 8
	%buf.3 =l alloc4 16
	storel 1, %x.1
	storel 2, %y.2
	call $swap(l %x.1, l %y.2)
	call $memset(l %buf.3, w 0, l 16)
	%.1 =l add %buf.3, 3
	storeb 122, %.1
	...
```

Read `swap` with the rules above. `let t = *a;` is `%.1 = loadl %a.1` (the value of `a`, which
is the address of `*a`) and `%.2 = loadl %.1` (the value of `*a`). Two loads for one `*`: one
to read the pointer out of its slot, one to read what it points at. `*a = *b;` computes the
address first (`%.3`), then the value (`%.4`, `%.5`), then stores. In `get`, `table[i]` is the
full recipe: `extsw` the `i32` index, `mul` by 4, `add` to `$table`. In `main`, `&x` is just
`%x.1`, passed straight to `swap`, and `buf[3]` with its constant index is `add %buf.3, 3`.

Nested indexing needs nothing new. `table[r][c] = r * 10 + c` in `run/arrays.peb`, with
`var table: [3][4]i32;` and `i32` counters, becomes two rounds of the same recipe, 16 bytes per
row and 4 per element:

```
	%.32 =w loadw %r.5
	%.33 =l extsw %.32
	%.34 =l mul %.33, 16
	%.35 =l add %table.4, %.34
	%.36 =w loadw %c.6
	%.37 =l extsw %.36
	%.38 =l mul %.37, 4
	%.39 =l add %.35, %.38
```

and the constant `table[2][3]` becomes `add %table.4, 32` and then `add %.24, 12`. pebc adds
twice where it could add 44 once. QBE fixes that, as we'll see; Chapter 9's constant folding
is about doing such things in pebc itself.

## Zero values and global variables

A `let` statement now has three cases in the code generator. With a value, it stores the
value, as before. Without one, a scalar `var r: i64;` gets a `storel 0` into its slot, and
an array is cleared with C's `memset(address, 0, size)`:

```zig
                    // A variable without a value starts as all zeros.
                    try g.emit("call $memset(l {f}, w 0, l {d})", .{ try g.declare(l.sym), t.size() });
```


Notice that nothing declared `memset`: QBE IL calls any symbol by name, and the linker finds
it in libc. Only Pebble's checker insists on `extern fn` declarations, and the code generator
is past the checker. (A side effect: a Pebble program that defines its own `fn memset` gets
*its* function called here. One that prints `not the real memset` and leaves the array
alone will then print garbage for `a[0]`. Real compilers have the same issue with the helper
functions they call, which is why C reserves the names of its library functions.)

Why zero, rather than whatever was on the stack, as in C? Because the cost is small and an
uninitialized variable is a classic source of bugs that appear and vanish with unrelated
changes. Zig makes you write `= undefined` to get garbage; Pebble doesn't offer garbage at all.

`declare`, which makes the stack slot, now takes the type's alignment into account:

```zig
        try g.allocs.writer.print("\t{f} =l alloc{d} {d}\n", .{ slot, @max(t.alignment(), 4), t.size() });
```

So `[4]i64` gets `alloc8 32` and `[16]u8` gets `alloc4 16` (4 being QBE's smallest).

**Globals** take two new steps. The checker declares them in pass 1, with the functions, so a
function may use a global declared below it. Functions and globals share one map, `globals`,
because they share one namespace in the end: both become linker symbols `$name`, and a global
`var main = 0;` next to `fn main` would be two definitions of `main` in the assembly. `lookup`
searches the scope stack first and falls back to `globals`, so a local hides a global of the
same name.

A global's value must be a **constant**: it is written into the executable, so it must be
known before the program runs. For now, `isConstant` accepts integer literals, negated
literals, `true`, `false` and strings. `var start = total;` gets `the value of a global
variable must be a constant` (Chapter 9's constant folding widens this to any expression it
can compute).

The code generator's `genGlobal` turns each global into a `data` definition. With a value,
the item is `b`, `w` or `l`, chosen by the type's size (1, 4 or 8 bytes); without one, it is
`z N`, which is N zero bytes. The globals of `run/globals.peb`:

```
var calls = 0;
let limit: i32 = -3;
let greeting = "hello";
var letter: u8 = 'A';
var ready = true;
var history: [4]i64;
```

become:

```console
$ ../zig-out/bin/pebc ir run/globals.peb | grep data
data $calls = { l 0 }
data $limit = { w -3 }
data $greeting = { l $str.0 }
data $letter = { b 65 }
data $ready = { w 1 }
data $history = { z 32 }
data $str.0 = { b "hello", b 0 }
...
```

`greeting` is a pointer, so its data is the *address* of the string, `l $str.0`, which the
linker fills in. In code, a global is used exactly like a local, through its address:
`calls = calls + 1` is `loadl $calls`, `add`, `storel %.2, $calls`. And
`history[calls % 4] = calls * 100` is `add $history, %.5` after the usual `mul 8`.

```console
$ ../zig-out/bin/pebc build run/globals.peb -o globals && ./globals
calls = 3, limit = -3, hello A 1
history: 0 100 200 300
letter = C
```

`count()` ran three times, writing `history[1]`, `[2]` and `[3]`; `history[0]` was never
written and is 0. QBE places each data definition in a section of the executable. In
`swap.peb`'s assembly, `counter` (initial value 0, but written as a value) is in `.data`, while
`table`, written with `z`, goes into `.bss`, the section of all-zero data that takes no space
in the file:

```
.data
.balign 8
counter:
	.quad 0
/* end data */

.bss
.balign 8
table:
	.fill 16,1,0
```

Pebble's globals are not `export`ed in the IL, so they get no `.globl` and are private to the
file, like `static` variables in C. Only `main` is exported.

## Strings are arrays of bytes

A string literal has type `*u8`: the address of its first byte. The bytes end with a 0, which
is how code finds the end. Ritchie puts it this way: "C treats strings as arrays of characters
conventionally terminated by a marker." With indexing, Pebble can now walk one. From
`run/strings.peb`:

```
fn length(s: *u8) i64 {
    var n = 0;
    while s[n] != 0 {
        n = n + 1;
    }
    return n;
}
```

`s[n]` on a `*u8` is a byte at `s + n`. The element size is 1, so there is no `mul`:

```
@while.1.cond
	%.1 =l loadl %s.1
	%.2 =l loadl %n.2
	%.3 =l add %.1, %.2
	%.4 =w loadub %.3
	%.5 =w cnew %.4, 0
	jnz %.5, @while.1.body, @while.1.end
```

The same file has `copy(to, from)`, `reverse(s)` and `upper(s)`, all loops over `s[i]`, and a
`main` that copies `"Hello, pebble"` into a `var buf: [32]u8;`, reverses it, uppercases it, and
prints it once more without spaces, one `putchar(buf[i] as i32)` at a time:

```console
$ ../zig-out/bin/pebc build run/strings.peb -o strings && ./strings
length = 13
elbbep ,olleH
ELBBEP ,OLLEH
ELBBEP,OLLEH
```

`printf("%s\n", &buf[0])` passes the address of the first byte, which is what `%s` wants. The
32-byte buffer is big enough for 13 bytes and the 0; nothing checks that, and writing a
33rd byte would overwrite whatever lies next to `buf` (see "Undefined behaviour" below).

One difference from C. QBE puts string literals in `.data`, which is writable, so
`let s = "hello"; s[0] = 'j'; printf("%s\n", s);` works and prints `jello`. A C compiler
puts literals in `.rodata`, read-only memory, and the same program in C crashes. Every use of
the literal shares the same bytes, so changing one is rarely what you want, even when it
works.

The other classic program that needs arrays is the sieve of Eratosthenes.
`samples/sieve.peb` keeps a global `var composite: [1000]bool;`. For each `n` from 2 up, if
`!composite[n]`, it prints `n` and marks every multiple from `n * n` on with
`composite[m] = true` in an inner `while` loop:

```console
$ cd project/ch06
$ zig build demo -Dsample=samples/sieve.peb
    2    3    5    7   11   13   17   19   23   29
   31   37   41   43   47   53   59   61   67   71
...
  947  953  967  971  977  983  991  997
168 primes below 1000
```

The global needs no initialization code at all: it is 4000 bytes of `.bss`, which the
operating system hands over zeroed. (A `bool` is 4 bytes in Pebble; a `[1000]u8` would do the
same job in a quarter of the space.)

## What QBE did with it

Chapter 4 promised that putting every variable in a stack slot costs nothing, because QBE
moves slots into registers. That is only possible when nothing else can see the slot. Now
that `&x` exists, some slots *can* be seen. Here is the assembly for `swap.peb`:

```console
$ ../../project/ch06/zig-out/bin/pebc ir swap.peb > swap.ssa && qbe swap.ssa
...
swap:
	pushq %rbp
	movq %rsp, %rbp
	movq (%rdi), %rax
	movq (%rsi), %rcx
	movq %rcx, (%rdi)
	movq %rax, (%rsi)
	leave
	ret
...
get:
	pushq %rbp
	movq %rsp, %rbp
	movslq %edi, %rcx
	leaq table(%rip), %rax
	movl (%rax, %rcx, 4), %eax
	leave
	ret
...
main:
	pushq %rbp
	movq %rsp, %rbp
	subq $40, %rsp
	pushq %rbx
	movq $1, -16(%rbp)
	movq $2, -8(%rbp)
	leaq -8(%rbp), %rsi
	leaq -16(%rbp), %rdi
	callq swap
	movl $16, %edx
	movl $0, %esi
	leaq -32(%rbp), %rdi
	callq memset
	movb $122, -29(%rbp)
...
```

- **`swap`'s slots are gone.** `a`, `b` and `t` had slots, but no `&a` ever appeared, so QBE
  kept them in registers. What remains is the essence of swapping through pointers: two
  loads, two stores. `(%rdi)` means "the memory at the address in `%rdi`".
- **`get`** became three instructions. `movslq` is `extsw` ("move, sign-extending long to
  quad"). Then `movl (%rax, %rcx, 4)` loads from `%rax + %rcx * 4`: x86-64 can scale an
  index by 1, 2, 4 or 8 and add it to a base inside a single memory operand, so the `mul`
  and `add` of the IL disappeared into the addressing mode.
- **`main`'s `x` and `y` stayed in memory**, at `-16(%rbp)` and `-8(%rbp)`, because their
  addresses were passed to `swap` (`leaq` = "load effective address", which computes an
  address without reading memory). Once an address escapes into a call, QBE can't know who
  reads or writes the slot, so the slot must be real memory. `buf` is at `-32(%rbp)`, and
  `buf[3] = 'z'` became one `movb $122, -29(%rbp)`: QBE folded `add %buf.3, 3` into the
  offset.

![main's stack frame for swap.peb: y at -8(%rbp), x at -16(%rbp), buf from -32 to -17 with buf[3] at -29, and above them the saved %rbp and the return address; %rdi and %rsi hold &x and &y for the call to swap. Next to it, oob2.peb's frame with a [4]i64 from -32 to -1 and a[4] landing on the saved %rbp.](images/ch06-memory.png)

The two adds for `table[2][3]` in `run/arrays.peb` were folded the same way. `table` sits at
`-112(%rbp)`, and the load is `movl -68(%rbp), %esi`: -112 + 44. Even `(*pt)[1][2]`, through
the `let pt = &table;` pointer, became `movl -88(%rbp), %esi`, because QBE could see which
address `pt` held.

## Undefined behaviour, for real

Here is a loop with an off-by-one error: `<=` where `<` was meant.

```console
$ cat oob2.peb
extern fn printf(format: *u8, ...) i32;

fn main() {
    var guard = 7;
    var a: [4]i64;
    var i = 0;
    while i <= 4 {
        a[i] = 100 + i;
        i = i + 1;
    }
    printf("guard = %ld\n", guard);
}
$ ../../project/ch06/zig-out/bin/pebc build oob2.peb && ./oob2; echo "exit $?"
guard = 7
exit 0
```

No error at compile time, none at run time, and the right output. The last iteration wrote
`a[4]`, 8 bytes past the end of `a`. Where did they go? The loop in the assembly:

```
	movl $0, %eax
.Lbb2:
	cmpq $4, %rax
	jg .Lbb4
	movl $100, %ecx
	addq %rax, %rcx
	movq %rcx, -32(%rbp, %rax, 8)
	addq $1, %rax
	jmp .Lbb2
.Lbb4:
	movl $7, %esi
```

`a` occupies `-32(%rbp)` to `-1(%rbp)`, so `a[4]` is `-32 + 4 * 8 = 0(%rbp)`: the slot where
`main` saved its caller's `%rbp` (the right half of the figure above). The program
overwrote it with 104. Then `leave` restored the caller's `%rbp` from that slot, so the C
library code that called `main` got 104 back as its frame pointer. It happened not to use it
before calling `exit`, so nothing visible went wrong. `guard` was never in danger:
QBE saw that it stays 7 and passed the constant straight to printf (`movl $7, %esi`).

This is the worst kind of bug: the program corrupts memory and still prints the right thing.
Change the function that calls this one, or the optimizer's choices, and the same bug
crashes, or prints garbage, or does nothing at all. C calls this **undefined behaviour**: the
language definition says nothing about what happens, so anything may. Pebble has inherited
it, because `a[i]` compiles to one unchecked memory access.

The other classic is a pointer that points nowhere. A `var p: *i64;` without a value starts as
0, the null pointer, and address 0 is deliberately left unmapped by the operating system:

```console
$ cat null.peb
extern fn printf(format: *u8, ...) i32;

fn main() {
    var p: *i64;
    printf("about to write through p\n");
    *p = 1;
    printf("done\n");
}
$ ../../project/ch06/zig-out/bin/pebc build null.peb && ./null; echo "exit $?"
about to write through p
bash: line 1: 1225132 Segmentation fault      (core dumped) ./null
exit 139
```

The CPU raised a fault, the kernel sent the process `SIGSEGV`, and the shell reported it:
exit status 139 is 128 + 11, the signal's number. QBE knew `p` was 0 and wrote the store as
`movq $1, 0`. This bug at least makes noise. But run it with its output piped (`./null |
cat`) and even the first line is gone: when stdout is not a terminal, printf collects output in
a buffer that is written out at exit, and a killed process never reaches exit. A crash that
erases the evidence printed before it is a debugging trap worth knowing about.

Both problems have the same fix: check. Exercise 1 makes pebc check every array index, at
compile time when the index is a constant and at run time when it isn't. Chapter 9 goes
further with constant indexes. A null check before every `*p` is the other half; Zig and Rust
avoid it with types instead (a pointer that may be null has a different type from one that
can't).

## History: arrays and pointers from B to C

Ritchie's "The Development of the C Language" (the paper Chapter 5 quoted on types) begins
its critique of C with this chapter's subject: "Two ideas are most characteristic of C among
languages of its class: the relationship between arrays and pointers, and the way in which
declaration syntax mimics expression syntax." The array half of that has a precise history.

- **In B, an array name was a pointer variable.** "When in BCPL one writes `let V = vec 10`
  or in B, `auto V[10];` the effect is the same: a cell named V is allocated, then another
  group of 10 contiguous cells is set aside, and the memory index of the first of these is
  placed into V." Indexing was pointer arithmetic: "By a general rule, in B the expression
  `*(V+i)` adds V and i, and refers to the i-th location after V." `V[i]` was notation for
  the same thing. In a word-addressed machine, adding `i` moved `i` words, so no scaling was
  needed.
- **NB scaled by the type.** On the byte-addressed PDP-11, "the machine code for array
  subscripting and pointer arithmetic now depended on the type of the array or the pointer:
  to compute `iarray[i]` or `ipointer+i` implied scaling the addend i by the size of the
  object referred to". That is the `mul` in `genAddr`.
- **Structs killed the pointer cell.** Ritchie wanted a struct to describe bytes on disk, such
  as a Unix directory entry, `struct { int inumber; char name[14]; };`. But if `name` were a
  pointer cell, as in B, "Where could the compiler hide the pointer to name that the semantics
  demanded?" His answer "constituted the crucial jump in the evolutionary chain between
  typeless BCPL and typed C. It eliminated the materialization of the pointer in storage, and
  instead caused the creation of the pointer when the array name is mentioned in an
  expression. The rule, which survives in today's C, is that values of array type are
  converted, when they appear in expressions, into pointers to the first of the objects
  making up the array."

That rule is the "decay" of the previous sections. It let most B code keep working, and it is
why a C array is a block of elements with no pointer stored anywhere: exactly what pebc
allocates. Pebble keeps the storage and drops the conversion: where C silently creates
`&a[0]`, Pebble asks you to write it.

Ritchie is candid about the costs. `int f(a) int a[];`, a parameter declared as an array that
is really a pointer, is "a living fossil, a remnant of NB's way of declaring a pointer"
(Pebble refuses array parameters for exactly this reason). And on optimization: "The
prevalence of pointers in C programs, whether those declared explicitly or arising from
arrays, means that optimizers must be cautious". You have just watched that happen: QBE
removed `swap`'s slots but had to leave `main`'s `x` and `y` in memory once their addresses
escaped.

**In the wild: checking indexes.** C does not check array indexes, and modern languages
mostly do. Here is the same off-by-one bug in Zig, run with `zig run oob.zig`:

```zig
    var a: [5]i64 = @splat(0);
    var i: usize = 0;
    while (i <= 5) : (i += 1) {
        a[i] = @intCast(i * i);
    }
```

```
thread 1225375 panic: index out of bounds: index 5, len 5
.../oob.zig:7:10: 0x11ea604 in main (oob.zig)
        a[i] = @intCast(i * i);
         ^
```

The Zig compiler inserted a check before the store, much like exercise 1's. The Zig manual
lists "Index out of Bounds" among the kinds of Illegal Behavior that are safety-checked: if a
check fails at run time, the program panics. In the build modes that turn safety off,
`zig run -Ofast oob.zig` prints `{ 0, 1, 4, 9, 16 }` and exits 0: no check, and the same
silent overwrite as `oob2.peb`.

And in C, compiled with GCC 11 with `-Wall -O0` (no warning) and run:

```
*** stack smashing detected ***: terminated
```

then `Aborted (core dumped)`, exit 134. That is not a bounds check. GCC's stack protector
(Ubuntu's GCC turns it on by default: `gcc -Q --help=common` lists `-fstack-protector-strong`
as `[enabled]`) put a guard value, a *canary*, next to the array and checked it when `main`
returned. The write happened, and was noticed afterwards, because it happened to hit the
canary. With `-fsanitize=address`, AddressSanitizer instruments every access and reports the
bad one as it happens:
`ERROR: AddressSanitizer: stack-buffer-overflow ... WRITE of size 8 ... in main oob.c:6`.
Checking every access is slower (the Clang manual gives a typical slowdown of 2x for
AddressSanitizer), which is why C made it optional and Zig turns it off in its fast mode.

## The project at the end of the chapter

```
project/ch06/src/
  types.zig    114 lines  + array, alignment
  ast.zig      203        + Decl.global, TypeExpr.array, optional let value
  parser.zig   569        + [N]T, letStatement, globals, recovery at let/var
  check.zig    614        + checkPlace, &, *, a[i], globals, arrays are not values
  codegen.zig  506        + genAddr, genGlobal, memset for arrays
  print.zig    183        prints array types and globals
```

The tests gain `run/pointers`, `run/arrays`, `run/globals`, `run/strings`, `run/sieve`,
`errors/pointers` (replacing `errors/pointer`) and `ast/pointers`, and `samples/` gains
`sieve.peb` and `strings.peb` (which reverses each word of a sentence in place). No earlier
golden file changed.

```console
$ cd project/ch06
$ zig build test --summary all
...
golden: 30 passed, 0 failed
Build Summary: 6/6 steps succeeded; 18/18 tests passed
...
```

`run/pointers.peb` exercises everything about pointers: `swap` through two of them, a
`divmod` that returns the remainder through a `rem: *i64` parameter (an "out parameter", the
C way to return two values), a pointer to a pointer, and a `u8` changed through a `*u8`, which
still wraps at 8 bits (200 + 100 is 44):

```console
$ cd tests
$ ../zig-out/bin/pebc build run/pointers.peb -o pointers && ./pointers
x = 2, y = 1
17 = 3 * 5 + 2
x = 42, p == &x: 1
small = 44
$ ../zig-out/bin/pebc build run/arrays.peb -o arrays && ./arrays
3 0 5 2 7 4 1 6 
0 1 2 3 4 5 6 7 
sum = 28
table[2][3] = 0
table[2][3] = 23, table[1][0] = 10
(*pt)[1][2] = 12
```

`run/arrays.peb` fills a `[8]i64`, bubble-sorts it through a `*i64` (`sort(&a[0], 8)`), and
fills the `[3][4]i32` table, which starts as zeros. Its last line indexes through a pointer to
the whole table, `let pt = &table;`, a `*[3][4]i32`. Writing `pt[1]` would treat `pt` as a
pointer to the *first of many tables*; `(*pt)[1]` first dereferences to the one table.
Exercise 3 lets `pt[1]` mean the row instead, as Zig does.

## Summary

- Every variable already had an address, its stack slot; QBE's `alloc4/8/16` takes an
  alignment in its name and a size as its operand. A `$name` in the IL is an address.
- New syntax: array types `[N]T` (length first, read left to right), globals, and
  `var x: T;` with no value, which starts as zero (`store 0`, or `memset` for an array).
- A **place** (an lvalue) is a `var`, an element of a place array, or anything through a
  pointer. `checkPlace` decides both "can I assign to it?" and "can I take its address?".
- **Arrays are not values** in Pebble: no copying, no passing, no decay. Write `&a[0]` where
  C would decay. There is no pointer arithmetic either; write `&p[i]`.
- **`genAddr`** computes the address of a place: a slot, the value of a pointer, or
  `base + i * size` with the index widened to 64 bits. Loads, stores and `&` all use it.
  Assignment computes the address before the value.
- **Globals** are `data` definitions (`{ l 0 }`, `{ z 32 }`), declared in the checker's first
  pass, in one namespace with functions. Their values must be constants for now.
- **Strings** are `*u8` pointing at bytes that end in 0; `s[i]` walks them.
- QBE keeps slots in registers until their address escapes; then they must live in memory.
  x86-64 addressing does `base + index * 1/2/4/8` in one operand.
- An unchecked index or a null pointer is **undefined behaviour**: an out-of-bounds write can
  corrupt the stack silently, and a crash can lose buffered output.
- C's array-to-pointer rule came from B, where an array name was a pointer cell; structs made
  Ritchie drop the cell and create the pointer on use instead.

## Exercises

1. **Bounds checks.** Make an out-of-range index an error. If the base is an array and the
   index is an integer literal, report it at compile time: `index 5 is out of bounds for
   '[5]i64'`. Otherwise, check at run time: print `index 5 is out of bounds (length 5)` to
   stderr and stop the program with C's `abort()`. Can you check an index through a pointer?

<details><summary>Solution</summary>

The compile-time half is three lines in the `.index` case of `typeOf`, before the `switch`:

```zig
                if (base == .array and ix.index.kind == .int and ix.index.kind.int >= base.array.len) {
                    return c.fail(ix.index.span, "index {d} is out of bounds for '{f}'", .{ ix.index.kind.int, base });
                }
```

```console
$ zig-out/bin/pebc check bad.peb
bad.peb:3:7: error: index 5 is out of bounds for '[5]i64'
    a[5] = 1;
      ^
```

(A negative literal like `a[-1]` is a negation node, not an `.int`, so it gets the run-time
check below. Chapter 9's constant folding catches it at compile time.)

The run-time half goes in `genAddr`, after the index has been widened to `offset` and before
the `mul`: `if (ix.base.type == .array) try g.checkBounds(offset, ix.base.type.array.len);`.

```zig
    /// Stops the program unless 0 <= index < len. Compared as unsigned
    /// numbers, a negative index is huge, so one comparison does both.
    fn checkBounds(g: *CodeGen, index: Value, len: u64) Error!void {
        const id = g.nextId();
        const ok = try g.result(.bool, "cultl {f}, {d}", .{ index, len });
        try g.emit("jnz {f}, @bounds.{d}.ok, @bounds.{d}.fail", .{ ok, id, id });
        try g.label("@bounds.{d}.fail", .{id});
        try g.strings.append(g.arena, "index %ld is out of bounds (length %ld)\n");
        const stderr = try g.result(.i64, "loadl $stderr", .{});
        try g.emit("call $fprintf(l {f}, l $str.{d}, ..., l {f}, l {d})", .{ stderr, g.strings.items.len - 1, index, len });
        try g.emit("call $abort()", .{});
        try g.emit("hlt", .{});
        try g.label("@bounds.{d}.ok", .{id});
    }
```

The trick is in the comparison. `cultl` compares as *unsigned* 64-bit numbers, and as an
unsigned number -1 is 2^64 - 1, far above any length. So one comparison rejects both
`i < 0` and `i >= len`. `stderr` is a global variable in the C library, a pointer to its
`FILE`. Like a Pebble global it is a `$` symbol, so `loadl $stderr` reads it. `hlt` ends the
failing block (QBE needs a jump, `ret` or `hlt` there), and the code continues at
`@bounds.N.ok`. In the IL for one `a[i]`, that is `%.4 =w cultl %.3, 5`, a `jnz`, the
failing block, and `%.6 =l mul %.3, 8` after `@bounds.2.ok`.

The test program is the off-by-one loop again, `while i <= 5`, on a `[5]i64`, printing each
element as it goes. Run in a terminal:

```console
$ zig-out/bin/pebc build oob.peb && ./oob; echo "exit $?"
a[0] = 0
a[1] = 1
a[2] = 4
a[3] = 9
a[4] = 16
index 5 is out of bounds (length 5)
bash: line 1: 1227942 Aborted                 (core dumped) ./oob
exit 134
```

134 is 128 + 6, `SIGABRT`. A program with `var i = -1; a[i] = 1;` prints `index -1 is out of
bounds (length 5)`: `%ld` prints the same 64 bits as signed. Why `abort()` and not
`exit(1)`? It is how C's `assert` stops a program, it leaves a core dump for a debugger, and
it can't be mistaken for a normal exit. (Like `null.peb`, a piped run loses the `a[0] = ...`
lines that were still in printf's buffer; stderr is not buffered, so the error line survives.)

All 30 golden tests still pass: no test program indexes out of bounds. Through a pointer
there is nothing to check against: a `*i64` doesn't say how many `i64`s follow it. That is
why Zig and Rust have a second kind of pointer, the *slice* (`[]T`, `&[T]`), which is an
address and a length together, and why C's `char *` strings carry their length as the 0 at
the end.

</details>

2. **Pointer arithmetic.** Add C's pointer arithmetic: `p + n` and `p - n` for a pointer `p`
   and any integer `n` move by `n` elements, and `p - q` for two pointers of the same type is
   the number of elements between them, an `i64`. With `a[i] = i * i` for a `[6]i64`, `let p =
   &a[1];` and `let q = &a[1] + 3;`, print `*q`, `q - p` and `*(q - 1)`. What does
   `printf("%s\n", "pebble" + 2)` print?

<details><summary>Solution</summary>

In `checkBinary`, after both operands are checked and before the "is this operator allowed"
test, accept the three new forms; the note about `&p[i]` goes away:

```zig
        // p + n and p - n move a pointer by n elements; p - q counts the
        // elements between two pointers.
        if (lhs == .pointer and (b.op == .add or b.op == .sub)) {
            if (rhs.isInteger()) return lhs;
            if (b.op == .sub and lhs.eql(rhs)) return .i64;
        }
```

In `genBinary`, where `t` is the type of the left operand (`const t = b.lhs.type;`), hand
pointer `+` and `-` to a new function:
`if (t == .pointer and (b.op == .add or b.op == .sub)) return g.genPointerArith(e, b);`.
The function:

```zig
    /// p + n, p - n and p - q, counted in elements, not bytes.
    fn genPointerArith(g: *CodeGen, e: *const Expr, b: Expr.Binary) Error!Value {
        const size: i64 = @intCast(b.lhs.type.pointer.size());
        const lhs = try g.genExpr(b.lhs);
        const rhs = try g.genExpr(b.rhs);
        if (b.rhs.type == .pointer) {
            const bytes = try g.result(.i64, "sub {f}, {f}", .{ lhs, rhs });
            if (size == 1) return bytes;
            return g.result(.i64, "div {f}, {d}", .{ bytes, size });
        }
        var offset = rhs;
        if (rhs == .int) {
            offset = .{ .int = rhs.int * size };
        } else {
            offset = switch (b.rhs.type) {
                .i64 => rhs,
                .i32 => try g.result(.i64, "extsw {f}", .{rhs}),
                else => try g.result(.i64, "extuw {f}", .{rhs}),
            };
            if (size != 1) offset = try g.result(.i64, "mul {f}, {d}", .{ offset, size });
        }
        return g.result(e.type, "{s} {f}, {f}", .{ if (b.op == .add) "add" else "sub", lhs, offset });
    }
```

It is `genAddr`'s index recipe again, plus the reverse for a difference: subtract the
addresses, then divide the byte count by the element size.

```console
$ zig-out/bin/pebc build arith.peb && ./arith
*q = 16, q - p = 3, *(q - 1) = 9
bble
```

`q` is `&a[4]`, so `*q` is 16 and `*(q - 1)` is `a[3]` = 9. In the IL, `&a[1] + 3` is
`add %.12, 24`, `q - 1` is `sub %.20, 8`, and `q - p` is `sub %.16, %.17` followed by
`div %.18, 8`. `"pebble" + 2` is a `*u8` two bytes in, so printf starts at `b`: `bble`.
That is C's idiom for skipping a prefix.

One golden test changes: `errors/pointers.peb` had `let g = q + 1;` as an error, which is now
legal, so its `.err` file loses that error and its note. Regenerate it with
`../zig-out/bin/pebc check errors/pointers.peb 2> errors/pointers.err` (from `tests/`) and
check that the diff removes exactly those six lines. Then all 30 golden and 18 unit tests
pass.

</details>

3. **Indexing through a pointer to an array.** `let pa = &a;` for a `var a: [4]i64;` has type
   `*[4]i64`. Make `pa[2]` mean `(*pa)[2]`, as it does in Zig. What error does the unchanged
   pebc give for `pa[2]`, and why that one?

<details><summary>Solution</summary>

Today, `pa[2]` indexes a pointer, so its type is the pointed-to type, `[4]i64`: element 2 of
an imagined array of arrays. Using that as a printf argument is using an array as a value:

```console
$ ../../project/ch06/zig-out/bin/pebc check pa.peb
pa.peb:7:35: error: an array cannot be used as a value; use its elements, or a pointer such as '&a[0]'
    printf("%ld %ld\n", (*pa)[2], pa[2]);
                                  ^~~~~
```

The fix is one line in the `.index` case of `typeOf`:

```zig
                    // p[i] on a *[N]T is (*p)[i].
                    .pointer => |p| if (p.* == .array) p.array.elem.* else p.*,
```

`genAddr` needs no change. For a pointer base it uses the pointer's value, which for a
`*[4]i64` is the address of the array, which is the address of element 0. And the element
size comes from `e.type`, which is now `i64`, so the offset is `2 * 8`.

```console
$ zig-out/bin/pebc build pa.peb && ./pa
4 4
```

`checkPlace` needs nothing either: `pa[2]` has a pointer base, so it is a place, and
`pa[2] = 5` works. All tests still pass. The price is that a `*[4]i64` can no longer point
into an array of `[4]i64` rows and step over them with `pa[1]`; with this rule, a pointer to
the first row of a `[3][4]i64` should be written `*i64` (`&m[0][0]`) or the table indexed
directly.

</details>

4. **`len(a)`.** Add a built-in `len(a)` that gives the length of an array as an `i64`, known
   at compile time. For `var m: [2][3]i32;`, `len(m)` is 2 and `len(m[0])` is 3. `len(3)`
   should be an error. Do it without touching the code generator.

<details><summary>Solution</summary>

The checker handles the call before looking up a function, unless the program defines its own
`len`:

```zig
        if (std.mem.eql(u8, name, "len") and !c.globals.contains("len")) return c.checkLen(e, call);
```

and `checkLen` *rewrites the call node* into an integer literal:

```zig
    /// `len(a)` is the length of the array `a`, known at compile time, so
    /// the call becomes an integer literal and codegen never sees it.
    fn checkLen(c: *Checker, e: *Expr, call: Expr.Call) Error!Type {
        if (call.args.len != 1) return c.fail(e.span, "'len' takes 1 argument, but {d} were given", .{call.args.len});
        const t = try c.checkExpr(call.args[0], null);
        if (t == .invalid) return .invalid;
        if (t != .array) return c.fail(call.args[0].span, "'len' needs an array, not '{f}'", .{t});
        e.kind = .{ .int = t.array.len };
        return .i64;
    }
```

The argument goes through `checkExpr`, not `checkValue`, because an array is exactly what
`checkValue` rejects. After checking, the tree holds `2` where the source said `len(m)`, so
the code generator emits a constant, and `pebc ir` shows `call $printf(l $str.0, ..., l 2, l 3)`.
This is the first time the checker changes the tree instead of annotating it. Chapter 9's
constant folding does the same on a larger scale.

The test program prints `len(m)` and `len(m[0])`, then sets the last element of every row with
`while i < len(m) { m[i][len(m[0]) - 1] = 7; ... }` and prints `m[1][2]`:

```console
$ zig-out/bin/pebc build len.peb && ./len
2 3
7
$ zig-out/bin/pebc check len2.peb
len2.peb:2:17: error: 'len' needs an array, not 'i64'
    let n = len(3);
                ^
```

The IL for `len(m[0]) - 1` is `sub 3, 1`: pebc computes nothing at compile time yet. QBE folds
it. All tests still pass.

</details>

Sources for this chapter: [REFERENCES.md](REFERENCES.md#chapter-6--pointers-and-arrays)
