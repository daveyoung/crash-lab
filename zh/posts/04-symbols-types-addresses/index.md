# 查看符号、类型与地址

**crash 有两类信息：符号表给出名字和对应的地址，DWARF 给出类型和成员布局。**

先看一个裸地址，这是十进制打印的指针数值：

```
crash> p 0xffffffffa0201020
$1 = 18446744072101040160
```

换成用struct命令，同时带类型和地址：

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

同一个地址，一个是数，一个是对象。

## 符号表

`sym` 双向查询，并给出符号类型字母：

```
crash> sym crashlab_trigger_write.cold
ffffffffa00000bd (t) crashlab_trigger_write.cold [crashlab]
```

`t`/`T` 是文本（局部/全局），`d`/`D` 数据，`b`/`B` bss，`r`/`R` 只读数据。sym命令会按子串查：

```
crash> sym -q crashlab
ffffffffa0000000 (t) crashlab_trigger_write [crashlab]
ffffffffa0000070 (t) crashlab_free_list [crashlab]
ffffffffa00000bd (t) crashlab_trigger_write.cold [crashlab]
ffffffffa0000110 (t) crashlab_exit [crashlab]
```

地址夹在两个符号之间时，`-p` 和 `-n` 分别给出前后邻居：

```
crash> sym -p crashlab_trigger_write.cold
ffffffffa0000070 (t) crashlab_free_list [crashlab]
ffffffffa00000bd (t) crashlab_trigger_write.cold [crashlab]
```

`whatis` 也能查符号的类型：

```
crash> whatis init_task
struct task_struct init_task;

crash> p init_task.pid
$1 = 0
```

`CONFIG_KALLSYMS_ALL` 决定内核符号表里是否包含数据符号。关掉时只有函数符号，所以 `sym crashlab_root` 查不到模块的全局变量。本实验中模块在加载时打印自己的链表头，我们可以用来遍历链表：

```
CRASHLAB: loaded 4 objects; list head at ffffffffa02010e0 (node offset 32)
```

## 模块类型：mod -S

`struct crashlab_obj` 的定义在模块里，加载之前：

```
crash> whatis struct crashlab_obj
whatis: cannot resolve: struct crashlab_obj
```

用 `mod -S` 指向模块：

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

加载后 `crash` 认得类型，但模块数据符号的地址并不可靠：

```
crash> p &crashlab_root
$1 = (struct crashlab_obj *) 0x1c0
```

`0x1c0` 是符号在目标文件里的偏移，不是内核地址。模块数据的地址我们会用内核加载模块时打印的那个，或者从别的结构体里读。

## 按类型读内存

三种写法，打印的内容不同：

```
crash> struct crashlab_obj 0xffffffffa0201020        # 整个对象
crash> p ((struct crashlab_obj *)0xffffffffa0201020)->magic
$1 = 1129070914
crash> px ((struct crashlab_obj *)0xffffffffa0201020)->value
$2 = 0x1000
```

`1129070914` 是 `0x434c4142`，读出来是 `"CLAB"`。

没有对象也能查成员偏移：

```
crash> p &((struct crashlab_obj *)0)->node
$1 = (struct list_head *) 0x20
```

## 遍历链表

模块加载时建了一条环形链表：头嵌在 root 对象里，后面是 `alpha`、`beta`、`gamma`，链接成员 `node` 在对象末尾。

`list` 需要两个参数：哪个成员是链接（`-s struct.member`），链接到对象差多少（`-l struct.member`）：

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

打印的是 `list_head` 地址，不是对象地址。第一个是头，走完 `gamma` 回到它。

链接可以直接当结构体读：

```
crash> p *(struct list_head *)0xffffffffa0201040
$1 = {
  next = 0xffffffffa0201070 <_MODULE_DATA_START_crashlab+112>,
  prev = 0xffffffffa02010e0 <_MODULE_DATA_START_crashlab+224>
}
```

反着走用 `-r`，从头的 `prev` 开始：

```
crash> list -r -s crashlab_obj.node -l crashlab_obj.node 0xffffffffa02010e0
ffffffffa02010e0
  node = {
[...]
ffffffffa02010a0
```

`-l` 写成 `struct.member` 时，类型必须已经加载。`mod -S` 没成功就会报
`list: invalid -l option: crashlab_obj.node`，而不是去猜偏移。

对象地址是链接地址减偏移。`gamma` 的 node 在 `0xffffffffa02010a0`：

```
crash> eval (0xffffffffa02010a0 - 0x20)
hexadecimal: ffffffffa0201080
    decimal: 18446744072101040256  (-1608511360)

crash> struct crashlab_obj 0xffffffffa0201080
...
  name = "gamma\000\000\000\000\000\000\000\000\000\000",
  value = 12288,
```

这就是 `container_of(node, struct crashlab_obj, node)`。

## 内核的进程链表

同样的方法可以遍历内核链表。进程链表是 `task_struct` 里的 `tasks` 成员，头是 `init_task` 内嵌的那个：

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
```

container_of偏移是 `936`（`0x3a8`）。链表走回 `init_task` 结束。

## 反汇编

`dis` 打印符号对应的指令：

```
crash> dis crashlab_trigger_write
0xffffffffa0000000 <crashlab_trigger_write>:	endbr64
0xffffffffa0000004 <crashlab_trigger_write+4>:	xor    %eax,%eax
0xffffffffa0000006 <crashlab_trigger_write+6>:	test   %rdx,%rdx
0xffffffffa0000009 <crashlab_trigger_write+9>:	je     0xffffffffa0000062 <crashlab_trigger_write+98>
[...]
```

给一个地址时只反汇编一条，可以指定数量：`dis <address> <count>`。

`-l` 带源码行：

```
crash> dis -l crashlab_trigger_write
~/crash-lab/crashlab/crashlab.c: 90
0xffffffffa0000000 <crashlab_trigger_write>:	endbr64
~/crash-lab/crashlab/crashlab.c: 93
0xffffffffa0000004 <crashlab_trigger_write+4>:	xor    %eax,%eax
```

源码树路径如果失效，行号就无法显示。可用`crash --src ~/crash-lab/linux ...` 指向新的位置。

## 地址翻译

`vtop` 走页表：

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

`pte` 用 PTE 值查标志：

```
crash> pte 80000000030ee163
      PTE         PHYSICAL  FLAGS
80000000030ee163   30ee000  (PRESENT|RW|ACCESSED|DIRTY|GLOBAL|NX)
```

`ptov` 反过来，从物理地址到直接映射地址：

```
crash> ptov 0x30ee020
ffff8880030ee020
```

返回的不是模块地址，而是同一个物理页的直接映射别名。两个虚拟地址指向同一个页。

页号换算：

```
crash> btop 0x30ee020
30ee020: 30ee
crash> ptob 30ee
30ee: 30ee000
```

## KASLR

这个内核 `CONFIG_RANDOMIZE_BASE=n`，文件里的符号地址就是运行地址。开了 KASLR 时，地址整体偏移：notes 还在就用 `--kaslr auto`，notes 丢了就从 panic 日志的 `Kernel Offset:` 取 `--kaslr <offset>`。

## 需要额外配置的命令

- `rustfilt <symbol>`：还原 Rust 符号（`_RNv...`），需要 `CONFIG_RUST=y`。本实验的内核没有开，所以没有输出。
- `tree -t xarray|maple|rbtree <root>`：走树而不是链表，根地址从owner的结构体取，例如 `p &<task>->mm->mm_mt`。`-s`/`-l` 的用法和 `list` 一样。
- `kmem -s`：需要 `CONFIG_SLUB_DEBUG=y`，否则会报：

  ```
  crash> kmem -s
  kmem: option requires kmem_cache_node.nr_slabs member!
  (the kernel must be built with CONFIG_SLUB_DEBUG)
  ```

## 练习

1. 遍历模块的链表，打出第二个普通对象的 `magic` 和 `name`。对象地址从哪来，偏移是多少？
2. 把一个 `crashlab_obj` 的虚拟地址翻成物理地址再翻回来。PTE 里哪些标志置位？为什么 `ptov` 的结果和出发地址不同？
3. 哪条命令给出 `struct kmem_cache` 的定义，哪条打印某个地址上的内容？

答案见 [`answers.md`](answers.md)。

## 速查

| 想做的事 | 命令 |
| --- | --- |
| 符号的地址 | `sym <name>` |
| 地址对应的符号 | `sym <address>` |
| 类型定义 | `whatis struct <type>` |
| 地址上的对象 | `struct <type> <address>` |
| 单个成员 | `p ((struct <type> *)<address>)-><member>` |
| 十六进制输出 | `px <expr>` |
| 成员偏移 | `p &((struct <type> *)0)-><member>` |
| 加载模块类型 | `mod -S <dir>` |
| 遍历链表 | `list -s <type>.<member> -l <type>.<member> <head>` |
| 地址算术 | `eval (<a> - <b>)` |
| 反汇编 | `dis <symbol>`，`dis <address> <count>` |
| 带源码行 | `dis -l <symbol>` |
| 虚拟转物理 | `vtop <address>` |
| 物理转虚拟 | `ptov <physical>` |
| 解 PTE | `pte <value>` |
| 页号换算 | `btop <address>`、`ptob <page>` |

---

**版本。** `crash 9.0.3++`（gdb 16.2）；内核 `7.3.0+`（x86_64，DWARF5，
`UNWINDER_ORC=y`，`KALLSYMS_ALL=n`，无 KASLR）；dump `vmcore-raw`，
`makedumpfile -l -d 31`。地址每次运行都会变，链表头从 `dmesg` 取。

上一篇：[命令语言](../03-the-command-language/index.html) · 下一篇：[panic 栈](../05-the-panic-stack/index.html) · 目录：[全部文章](../../index.html)
