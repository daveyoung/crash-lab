# 答案：符号、类型与地址

## 1. 第二个普通对象

链表头地址来自 `dmesg`，因为模块的数据符号不在 kallsyms 里：

```
CRASHLAB: loaded 4 objects; list head at ffffffffa02010e0 (node offset 32)
```

走一遍：

```
crash> mod -S ~/crash-lab/crashlab
crash> list -s crashlab_obj.node -l crashlab_obj.node 0xffffffffa02010e0
```

条目依次是 `root`（头的容器）、`alpha`、`beta`、`gamma`。打出来的是 `list_head` 地址，减掉偏移 `0x20` 才是对象地址：

| 条目 | node 地址 | 对象地址 | 名字 |
| --- | --- | --- | --- |
| root | `ffffffffa02010e0` | `ffffffffa02010c0` | `root` |
| alpha | `ffffffffa0201040` | `ffffffffa0201020` | `alpha` |
| beta | `ffffffffa0201070` | `ffffffffa0201050` | `beta` |
| gamma | `ffffffffa02010a0` | `ffffffffa0201080` | `gamma` |

**第二个普通对象**是 `beta`：

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

`magic = 1129070914` 就是 `0x434c4142`，四个字节 `"CLAB"`。偏移可以从 `list -l crashlab_obj.node` 来，也可以用 `p &((struct crashlab_obj *)0)->node` 读到，两个都是 `0x20`，只是问法不同。

## 2. 虚拟地址与物理地址来回翻译

```
crash> vtop 0xffffffffa0201020
VIRTUAL           PHYSICAL
ffffffffa0201020  30ee020

      PTE         PHYSICAL  FLAGS
80000000030ee163   30ee000  (PRESENT|RW|ACCESSED|DIRTY|GLOBAL|NX)
```

**标志位：** `PRESENT`（映射存在）、`RW`（可写）、`ACCESSED`、`DIRTY`、`GLOBAL`（上下文切换时不被刷掉，内核映射通常这么标）、`NX`（不可执行——这是数据页）。

反着走：

```
crash> ptov 0x30ee020
ffff8880030ee020
```

**为什么不是你出发的那个地址：** 模块地址 `ffffffffa0201020` 和直接映射地址 `ffff8880030ee020` 是同一个物理页的两个虚拟映射。`ptov` 按定义返回直接映射别名；模块映射在 vmalloc 区。想拿回模块自己的地址，就得自己留着，或者用模块基址加偏移重新算——`ptov` 不会帮你还原。

`pte 80000000030ee163` 用原始 PTE 值打出同样的标志位，所以 PTE 如果不是从 `vtop` 得来的，就用它来核对。

## 3. 定义与内容

- **定义：** `whatis struct kmem_cache`，打出类型、成员及其类型、大小：

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

- **某个地址上的内容：** `struct kmem_cache <地址>`。

这正是全篇的分界：`whatis` 回答"这个类型长什么样"，`struct` 回答"这个对象里是什么"。

这个内核上还有一个枝节：`kmem -s` 拒绝遍历 slab 链表，因为编译时没开 `CONFIG_SLUB_DEBUG`：

```
crash> kmem -s
kmem: option requires kmem_cache_node.nr_slabs member!
(the kernel must be built with CONFIG_SLUB_DEBUG)
```

这是配置限制，不是符号问题。缓存地址仍然可以从指向它的结构体字段读出来，`whatis struct kmem_cache` 也照常可用。
