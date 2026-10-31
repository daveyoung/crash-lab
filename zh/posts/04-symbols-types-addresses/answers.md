# 答案：查看符号、类型与地址

## 1. 第二个普通对象

链表头地址来自 `dmesg`：

```
CRASHLAB: loaded 4 objects; list head at ffffffffa02010e0 (node offset 32)
```

加载模块类型后遍历链表：

```
crash> mod -S ~/crash-lab/crashlab
crash> list -s crashlab_obj.node -l crashlab_obj.node 0xffffffffa02010e0
```

条目依次是 `root`、`alpha`、`beta`、`gamma`。打印的是 `list_head` 地址，减掉偏移 `0x20` 才是对象地址：

| 条目 | node 地址 | 对象地址 | 名字 |
| --- | --- | --- | --- |
| root | `ffffffffa02010e0` | `ffffffffa02010c0` | `root` |
| alpha | `ffffffffa0201040` | `ffffffffa0201020` | `alpha` |
| beta | `ffffffffa0201070` | `ffffffffa0201050` | `beta` |
| gamma | `ffffffffa02010a0` | `ffffffffa0201080` | `gamma` |

第二个普通对象是 `beta`：

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

`1129070914` 是 `0x434c4142`，也就是 `"CLAB"`。偏移可以从 `list -l` 得到，也可以用 `p &((struct crashlab_obj *)0)->node` 查，都是 `0x20`。

## 2. 虚拟地址与物理地址

```
crash> vtop 0xffffffffa0201020
VIRTUAL           PHYSICAL
ffffffffa0201020  30ee020

      PTE         PHYSICAL  FLAGS
80000000030ee163   30ee000  (PRESENT|RW|ACCESSED|DIRTY|GLOBAL|NX)
```

标志位：`PRESENT` 映射存在，`RW` 可写，`ACCESSED`、`DIRTY` 已访问已修改，`GLOBAL` 上下文切换时不刷掉，`NX` 不可执行。

反着走：

```
crash> ptov 0x30ee020
ffff8880030ee020
```

`ffffffffa0201020` 和 `ffff8880030ee020` 是同一个物理页的两个映射：前者是模块在 vmalloc 区的地址，后者是直接映射别名。`ptov` 返回的永远是直接映射地址，原来的模块地址要自己保留。

`pte 80000000030ee163` 用 PTE 值打印同样的标志，可以从这里核对。

## 3. 定义与内容

- 定义：`whatis struct kmem_cache`
- 某个地址上的内容：`struct kmem_cache <地址>`

`whatis` 回答类型长什么样，`struct` 回答这个对象里是什么。

这个内核没有开 `CONFIG_SLUB_DEBUG`，所以 `kmem -s` 会拒绝：

```
crash> kmem -s
kmem: option requires kmem_cache_node.nr_slabs member!
(the kernel must be built with CONFIG_SLUB_DEBUG)
```

缓存地址可以从指向它的结构体字段读出来，`whatis struct kmem_cache` 仍然可用。
