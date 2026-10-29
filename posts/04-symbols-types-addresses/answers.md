# Answers — Symbols, types, addresses

## 1. The second ordinary object

The head address comes from `dmesg`, because the module's data symbols are not
in kallsyms:

```
CRASHLAB: loaded 4 objects; list head at ffffffffa02010e0 (node offset 32)
```

Walk it:

```
crash> mod -S ~/crash-lab/crashlab
crash> list -s crashlab_obj.node -l crashlab_obj.node 0xffffffffa02010e0
```

The entries are `root` (the head's container), `alpha`, `beta`, `gamma`. The
addresses printed are `list_head` addresses; subtract the offset `0x20` to get
object addresses:

| entry | node address | object address | name |
| --- | --- | --- | --- |
| root | `ffffffffa02010e0` | `ffffffffa02010c0` | `root` |
| alpha | `ffffffffa0201040` | `ffffffffa0201020` | `alpha` |
| beta | `ffffffffa0201070` | `ffffffffa0201050` | `beta` |
| gamma | `ffffffffa02010a0` | `ffffffffa0201080` | `gamma` |

The **second ordinary object** is `beta`:

```
crash> struct crashlab_obj 0xffffffffa0201050
struct crashlab_obj {
  magic = 1129070914,
  name = "beta\000\000\000\000\000\000\000\000\000\000\000",
  value = 8192,
  node = {
    next = 0xffffffffa02010a0 <_MODULE_DATA_START_crashlab+160>,
    prev = 0xffffffffa0201040 <_MODULE_DATA_START_crashlab+64>
  }
}
```

`magic = 1129070914` is `0x434c4142`, the four bytes `"CLAB"`. The offset came
from either `-l crashlab_obj.node` in the list command or from
`p &((struct crashlab_obj *)0)->node` (`0x20`), which is the same number read a
different way.

## 2. Virtual to physical and back

```
crash> vtop 0xffffffffa0201020
VIRTUAL           PHYSICAL
ffffffffa0201020  30ee020

      PTE         PHYSICAL  FLAGS
80000000030ee163   30ee000  (PRESENT|RW|ACCESSED|DIRTY|GLOBAL|NX)
```

**Flags:** `PRESENT` (the mapping exists), `RW` (writable), `ACCESSED`, `DIRTY`,
`GLOBAL` (not flushed on a context switch, which is why kernel mappings are
tagged this way), `NX` (not executable — data page).

Going back:

```
crash> ptov 0x30ee020
ffff8880030ee020
```

**Why it is not the address you started from:** the module address
`ffffffffa0201020` and the direct-map address `ffff8880030ee020` are two
different virtual mappings of the same physical page. `ptov` returns the
direct-map alias by construction; the module mapping lives in the vmalloc
region. If you need the module's own address again, you keep it, or you rebuild
it from the module base plus the offset — you do not get it back from `ptov`.

`pte 80000000030ee163` prints the same flags from the raw PTE value, which is
the way to check a PTE you found somewhere other than `vtop`.

## 3. Definition versus contents

- **Definition:** `whatis struct kmem_cache` prints the type, its members and
  their types, and the size:

  ```
  crash> whatis struct kmem_cache
  struct kmem_cache {
      struct slub_percpu_sheaves *cpu_sheaves;
      slab_flags_t flags;
      unsigned long min_partial;
      unsigned int size;
      ...
  }
  ```

- **Contents at a specific address:** `struct kmem_cache <address>`.

The distinction is the one the post is built on: `whatis` answers *what the
type looks like*, `struct` answers *what is in this object*. On this kernel
there is a wrinkle when looking for a cache address: `kmem -s` refuses to walk
the slab list because the kernel was built without `CONFIG_SLUB_DEBUG`:

```
crash> kmem -s
kmem: option requires kmem_cache_node.nr_slabs member!
(the kernel must be built with CONFIG_SLUB_DEBUG)
```

That is a config limitation, not a symbol problem. The address can still come
from a structure that points at a cache (`p` on the right field), and
`whatis struct kmem_cache` works either way.
