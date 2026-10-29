# Symbols, types, addresses

**`crash` reads two tables: one maps names to addresses, the other maps addresses to meaning. Most of the confusion in postmortem work comes from asking one table a question that belongs to the other.**

Start with a bare address:

```
crash> p 0xffffffffa0201020
$1 = 18446744072101040160
```

That is the pointer's value, printed in decimal, and it tells you nothing. Now ask the same address a typed question:

```
crash> struct crashlab_obj 0xffffffffa0201020
struct crashlab_obj {
  magic = 1129070914,
  name = "alpha\000\000\000\000\000\000\000\000\000\000",
  value = 4096,
  node = {
    next = 0xffffffffa0201070 <_MODULE_DATA_START_crashlab+112>,
    prev = 0xffffffffa02010e0 <_MODULE_DATA_START_crashlab+224>
  }
}
```

Same address. One answer is a number; the other is an object in a list. The difference is the type system, and using it deliberately is what this post is about.

## Two tables, and what each one knows

- **The symbol table** answers *where*: a name in, an address out, or the reverse. On x86_64 with `CONFIG_KALLSYMS` it is built into the kernel, and `crash` also reads the ELF symbol table from `vmlinux`.
- **DWARF** answers *what*: given a type name, it gives you the layout; given an address and a type, `crash` can read fields. DWARF is what `whatis` and `struct` use.

The symbol side is easy to see:

```
crash> sym crashlab_trigger_write.cold
ffffffffa00000bd (t) crashlab_trigger_write.cold [crashlab]
```

Function symbols like that one come from the kernel's kallsyms, which is why they resolve even for a module whose debug info has not been loaded. Data is different. This kernel runs with `CONFIG_KALLSYMS_ALL=n`, so module *data* symbols are not in the table — `sym crashlab_root` fails. That is why the module prints its own list address at load time:

```
CRASHLAB: loaded 4 objects; list head at ffffffffa02010e0 (node offset 32)
```

An address from `dmesg` is a perfectly good starting point. From here on, the type system does the work.

### Reading the symbol table

`sym` prints a type letter with every hit, and the letter is worth knowing:

```
crash> sym -q crashlab
ffffffffa0000000 (t) crashlab_trigger_write [crashlab]
ffffffffa0000070 (t) crashlab_free_list [crashlab]
ffffffffa00000bd (t) crashlab_trigger_write.cold [crashlab]
ffffffffa0000110 (t) crashlab_exit [crashlab]
```

`t`/`T` is text (local/global), `d`/`D` data, `b`/`B` bss, `r`/`R` read-only data, `A` absolute. `-q` filters by substring, which beats paging through `sym -l`. When you have an address that falls *between* two symbols, `-p` and `-n` show the neighbours:

```
crash> sym -p crashlab_trigger_write.cold
ffffffffa0000070 (t) crashlab_free_list [crashlab]
ffffffffa00000bd (t) crashlab_trigger_write.cold [crashlab]
```

That is often the fastest answer to "what is this address near?" before you commit to a disassembly.

### Type names that are not structs

`whatis` resolves typedefs and unions as well as structs:

```
crash> whatis slab_flags_t
typedef unsigned int slab_flags_t;
SIZE: 4
```

Worth doing when a member prints as a bare number and you are about to mask or shift it: the width is part of the type, not the value.

## `mod -S`: teaching `crash` about a module's types

The module defines `struct crashlab_obj`, so its layout is in `crashlab.ko`, not in `vmlinux`. Before you point `crash` at the module, it cannot resolve the type:

```
crash> whatis struct crashlab_obj
whatis: cannot resolve: struct crashlab_obj
```

`mod -S` loads the module's debug info and relocates it against the module's load address in the dump:

```
crash> mod -S ~/crash-lab/crashlab
     MODULE       NAME         TEXT_BASE       SIZE  OBJECT FILE
ffffffffa0201100  crashlab  ffffffffa0000000  12288  ~/crash-lab/crashlab/crashlab.ko

crash> whatis struct crashlab_obj
struct crashlab_obj {
    u32 magic;
    char name[16];
    unsigned long value;
    struct list_head node;
}
SIZE: 48
```

One trap comes with this, and it is a quiet one. After `mod -S`, `crash` knows the name `crashlab_root` but not where it was relocated to:

```
crash> p &crashlab_root
$1 = (struct crashlab_obj *) 0x1c0
```

`0x1c0` is an offset inside the object file, not a kernel address. Use the address the module printed, or an address you read out of another structure; do not trust a module data symbol to be relocated. Post 17 comes back to this.

## Address to object

With the type known, an address becomes readable. The three forms are equivalent, and differ only in how much they print:

```
crash> struct crashlab_obj 0xffffffffa0201020        # the whole object
crash> p ((struct crashlab_obj *)0xffffffffa0201020)->magic
$1 = 1129070914
crash> px ((struct crashlab_obj *)0xffffffffa0201020)->value
$2 = 0x1000
```

`struct` is the readable one; `p` with a cast is the scriptable one; `px` is `p` in hexadecimal, which matters because the default radix here is decimal. `1129070914` is `0x434c4142`, four bytes that read `"CLAB"` — the magic the module writes into every object.

You can ask for the offset of a member the same way, without an object at all:

```
crash> p &((struct crashlab_obj *)0)->node
$1 = (struct list_head *) 0x20
```

Zero is a legal "address" for offset arithmetic, and this is the standard trick for getting `offsetof()` out of a dump.

`whatis` also accepts a symbol, which is where the two tables meet:

```
crash> whatis init_task
struct task_struct init_task;

crash> p init_task.pid
$1 = 0
```

The symbol table supplied the address, the type supplied the layout, and the
value came out of the dump.

## Walking the list

The module built a four-entry circular list: a head embedded in a root object, then `alpha`, `beta`, `gamma`. `list` walks it if you tell it two things: which member is the linkage (`-s struct.member`) and what the offset is from that linkage back to the object (`-l`).

```
crash> list -s crashlab_obj.node -l crashlab_obj.node 0xffffffffa02010e0
ffffffffa02010e0
  node = {
    next = 0xffffffffa0201040 <_MODULE_DATA_START_crashlab+64>,
    prev = 0xffffffffa02010a0 <_MODULE_DATA_START_crashlab+160>
  },
ffffffffa0201040
  node = {
    next = 0xffffffffa0201070 <_MODULE_DATA_START_crashlab+112>,
    prev = 0xffffffffa02010e0 <_MODULE_DATA_START_crashlab+224>
  },
ffffffffa0201070
  node = {
    next = 0xffffffffa02010a0 <_MODULE_DATA_START_crashlab+160>,
    prev = 0xffffffffa0201040 <_MODULE_DATA_START_crashlab+64>
  },
ffffffffa02010a0
  node = {
    next = 0xffffffffa02010e0 <_MODULE_DATA_START_crashlab+224>,
    prev = 0xffffffffa0201070 <_MODULE_DATA_START_crashlab+112>
  },
```

The addresses printed are **list_head addresses**, not object addresses: the first is the head itself, and the walk returns to it after `gamma`. `-r` walks backwards through `prev`, and `-o <offset>` is the other spelling of `-l` for lists whose linkage is at a fixed byte offset.

If the list is headed by a standalone `LIST_HEAD()` rather than an embedded head, drop `-l` and give `list` the first object address with `-o`; the rest is the same.

## `container_of`, by hand

The list gives you the linkage. The object is `node - offset`, and doing that arithmetic once makes every later list easier to trust. `gamma`'s node is at `0xffffffffa02010a0`, and the offset is `0x20`:

```
crash> eval (0xffffffffa02010a0 - 0x20)
hexadecimal: ffffffffa0201080
    decimal: 18446744072101040256  (-1608511360)
```

`struct crashlab_obj 0xffffffffa0201080` prints `name = "gamma"` and `value = 12288`. That is `container_of(node, struct crashlab_obj, node)`, done by hand, and it is why the module puts `node` last: with the linkage at offset zero, the arithmetic would be free and the lesson invisible.

## The same walk on a real kernel list

The module's list is small on purpose, but nothing above is module-specific. The
process list is a `list_head` in `task_struct`, headed by the embedded
`tasks` member of `init_task`:

```
crash> p &init_task.tasks
$1 = (struct list_head *) 0xffffffff81a0aa28 <init_task+936>

crash> list -s task_struct.tasks -l task_struct.tasks 0xffffffff81a0aa28
ffffffff81a0aa28
  tasks = {
    next = 0xffff888002949fa8,
    prev = 0xffff88807def83a8
  },
ffff888002949fa8
  tasks = {
    next = 0xffff8880029491a8,
    prev = 0xffffffff81a0aa28 <init_task+936>
  },
[...]
```

`init_task` resolves through the symbol table, so you do not need `dmesg` for
this one, and the container offset is `936` (`0x3a8`). The list is circular, so
the walk ends when it gets back to `init_task`. Subtracting it from any
`tasks` address gives a `task_struct` you can hand to `struct`, which is the
first step of most of the task-oriented posts that follow.

## Disassembly, and source when you have it

`dis` shows the instructions behind a symbol:

```
crash> dis crashlab_trigger_write
0xffffffffa0000000 <crashlab_trigger_write>:	endbr64
0xffffffffa0000004 <crashlab_trigger_write+4>:	xor    %eax,%eax
0xffffffffa0000006 <crashlab_trigger_write+6>:	test   %rdx,%rdx
0xffffffffa0000009 <crashlab_trigger_write+9>:	je     0xffffffffa0000062 <crashlab_trigger_write+98>
[...]
0xffffffffa0000021 <crashlab_trigger_write+33>:	test   %rax,%rax
0xffffffffa0000024 <crashlab_trigger_write+36>:	jne    0xffffffffa000004e <crashlab_trigger_write+78>
```

and `-l` interleaves source lines, because the DWARF records the build path:

```
crash> dis -l crashlab_trigger_write
~/crash-lab/crashlab/crashlab.c: 90
0xffffffffa0000000 <crashlab_trigger_write>:	endbr64
~/crash-lab/crashlab/crashlab.c: 93
0xffffffffa0000004 <crashlab_trigger_write+4>:	xor    %eax,%eax
```

If the build tree has moved since the dump, the recorded path is wrong and the lines are missing. `crash --src ~/crash-lab/linux ...` points it at the new location for kernel symbols; module paths follow the module's own DWARF.

## Address translation, one page at a time

`vtop` walks the page tables for a virtual address. For the module's data page:

```
crash> vtop 0xffffffffa0201020
VIRTUAL           PHYSICAL
ffffffffa0201020  30ee020

PGD DIRECTORY: ffffffff81a18000
PAGE DIRECTORY: 201a067
   PUD: 201aff0 => 201b063
   PMD: 201b808 => 46ac067
   PTE: 46ac008 => 80000000030ee163
  PAGE: 30ee000

      PTE         PHYSICAL  FLAGS
80000000030ee163   30ee000  (PRESENT|RW|ACCESSED|DIRTY|GLOBAL|NX)
```

That PTE value is a thing you can hand back to `crash`:

```
crash> pte 80000000030ee163
      PTE         PHYSICAL  FLAGS
80000000030ee163   30ee000  (PRESENT|RW|ACCESSED|DIRTY|GLOBAL|NX)
```

`pte` takes the PTE, not the virtual address; getting that wrong produces a confusing lookup rather than an error. `ptov` goes the other way, from physical to virtual, and it returns the **direct-map** address, not the module address you started from:

```
crash> ptov 0x30ee020
ffff8880030ee020
```

Both virtual addresses name the same physical page. That is not a bug in the tool: a module page and its direct-map alias are two mappings, and knowing which one you are looking at matters when you read memory.

The page-granularity helpers are the same arithmetic: `btop <addr>` gives the page number, `ptob <page>` gives the page-aligned byte address.

```
crash> btop 0x30ee020
30ee020: 30ee
crash> ptob 30ee
30ee: 30ee000
```

## KASLR, and when the two tables disagree

This kernel has `CONFIG_RANDOMIZE_BASE=n`, so symbol addresses in `vmlinux` are the runtime addresses in the dump, and none of the above needed a slide. With KASLR on, every address shifts by a per-boot offset, the file's symbols no longer match memory, and `crash` needs the offset from the dump's notes: `--kaslr auto` when the notes survived, `--kaslr <offset>` from the panic log's `Kernel Offset:` line when they did not. The type system is unaffected — the offset moves addresses, not layouts — but every `sym` answer is.

## When the "list" is a tree

`list` follows `next`/`prev`. Kernel code also threads structures through radix trees, XArrays, maple trees, and rbtrees, and those are not linked lists: `crash` walks them with `tree -t xarray|maple|rbtree <root>` and the same `-s`/`-l` idea for the entry type. If a structure has a `list_head` and you cannot find your object in it, check whether you are looking at the wrong member: `whatis struct <type>` lists all of them, and the one you want may be a tree node.

## Commands that need a config option this lab does not have

Some of the toolset only pays off with kernel options this lab leaves off. The
command shapes are still worth knowing, because a rebuild is all that stands
between you and using them:

- **`rustfilt <symbol>`** — demangles Rust symbols (`_RNv...`) into
  `crate::module::function`. It needs `CONFIG_RUST=y`; with Rust off there is
  nothing mangled to translate, which is why this post has no transcript for it.
  When it does apply, `sym` and `bt` show the mangled name and `rustfilt` gives
  you the readable one.
- **`tree -t xarray|maple|rbtree <root>`** — walks a tree instead of a
  `list_head`. The root address comes from the structure that owns it, for
  example `p &<task>->mm->mm_mt` for the maple tree of VMAs, and `-s`/`-l`
  describe entries the same way `list` does. Reach for it when the member you
  found is a tree node rather than a list linkage.
- **`kmem -s`** — the slab walk requires `CONFIG_SLUB_DEBUG=y`. Without it,
  `crash` says exactly that:

  ```
  crash> kmem -s
  kmem: option requires kmem_cache_node.nr_slabs member!
  (the kernel must be built with CONFIG_SLUB_DEBUG)
  ```

  `whatis struct kmem_cache` still works, so the type side is available even
  when the walk is not.

The general rule: when a command fails with a message naming a `CONFIG_`
option, that message is the rebuild recipe. Add the option, rebuild, retake the
dump — the post that needs it will say which one.

## Traps

- `p <address>` prints the pointer's value. Use `struct <type> <address>` or a cast.
- `struct` wants the address of the **object**, not the address of its `list_head`.
- `list` wants the linkage address with `-l`, or the object address with `-o`; mixing them gives plausible nonsense.
- Module types need `mod -S`; module data symbols need `CONFIG_KALLSYMS_ALL`. Neither is on by default in this lab.
- A module data symbol that resolves to a small value like `0x1c0` is an unrelocated file offset, not an address.
- `vtop` on a user address uses the current context; `set` to the task first.
- `pte` takes a PTE value, not a virtual address. Get the value from `vtop`.
- `dis -l` and `--src` need the build tree where the DWARF says it was; check before quoting line numbers.
- KASLR invalidates the file-to-memory address mapping, not the types.

## Exercises

1. Walk the module's list and print the second ordinary object's `magic` and `name`. Which command gives you the object address, and what is the offset?
2. Translate a `crashlab_obj` virtual address to physical and back. Which flags are set in its PTE, and why is the `ptov` result not the address you started from?
3. Which command shows the definition of `struct kmem_cache`, and which prints the contents at a specific address of one?

Answers are in [`answers.md`](answers.md).

## Cheat sheet

| question | command |
| --- | --- |
| address of a symbol | `sym <name>` |
| symbol at an address | `sym <address>` |
| what is this type | `whatis struct <type>` |
| object at an address | `struct <type> <address>` |
| one member | `p ((struct <type> *)<address>)-><member>` |
| hex output | `px <expr>` |
| member offset | `p &((struct <type> *)0)-><member>` |
| load module types | `mod -S <dir>` |
| walk a list | `list -s <type>.<member> -l <type>.<member> <head>` |
| reverse | `list -r ...` |
| address arithmetic | `eval (<a> - <b>)` |
| instructions | `dis <symbol>` |
| instructions with lines | `dis -l <symbol>` |
| virtual to physical | `vtop <address>` |
| physical to virtual | `ptov <physical>` |
| decode a PTE | `pte <value>` |
| page numbers | `btop <address>`, `ptob <page>` |

---

**Versions.** `crash 9.0.3++` (gdb 16.2); kernel `7.3.0+` (x86_64, DWARF5,
`UNWINDER_ORC=y`, `KALLSYMS_ALL=n`, no KASLR); module `crashlab.ko` built
against the same tree; dump `vmcore-raw` from `makedumpfile -l -d 31`. Module
and heap addresses differ between runs; take the list head from `dmesg`.

Previous: [Post 3 — The command language](../03-the-command-language/).
