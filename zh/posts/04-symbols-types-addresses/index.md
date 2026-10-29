# 符号、类型与地址

**crash 手里有两张表：一张把名字换成地址，另一张把地址换成含义。事后分析里的大部分糊涂，都是拿一张表去回答另一张表的问题。**

先给一个裸地址：

```
crash> p 0xffffffffa0201020
$1 = 18446744072101040160
```

这是指针的数值，十进制打印，等于什么都没说。换一个带类型的问题：

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

同一个地址：一个答案是个数，另一个是一个链表里的对象。差别就在类型系统，这篇讲的就是怎么有意识地用它。

## 两张表，各管一摊

- **符号表**回答"在哪"：给名字出地址，给地址出名字。x86_64 上它由 `CONFIG_KALLSYMS` 编进内核，`crash` 同时也会读 `vmlinux` 里的 ELF 符号表。
- **DWARF** 回答"是什么"：给类型名出布局，给地址和类型就能读出字段。`whatis` 和 `struct` 用的就是它。

符号这一侧很直观：

```
crash> sym crashlab_trigger_write.cold
ffffffffa00000bd (t) crashlab_trigger_write.cold [crashlab]
```

这种函数符号来自内核的 kallsyms，所以模块的调试信息还没加载，它照样能解析。数据不一样。这个内核是 `CONFIG_KALLSYMS_ALL=n`，模块的**数据**符号不在表里——`sym crashlab_root` 查不到。所以模块在加载时自己把链表头打出来：

```
CRASHLAB: loaded 4 objects; list head at ffffffffa02010e0 (node offset 32)
```

从 `dmesg` 里拿到一个地址，照样能开工。往后就交给类型系统。

### 顺手把符号表读明白

`sym` 每命中一条都会带上类型字母，字母有用：

```
crash> sym -q crashlab
ffffffffa0000000 (t) crashlab_trigger_write [crashlab]
ffffffffa0000070 (t) crashlab_free_list [crashlab]
ffffffffa00000bd (t) crashlab_trigger_write.cold [crashlab]
ffffffffa0000110 (t) crashlab_exit [crashlab]
```

`t`/`T` 是文本（局部/全局），`d`/`D` 数据，`b`/`B` bss，`r`/`R` 只读数据，`A` 绝对地址。`-q` 按子串过滤，比 `sym -l` 一页页翻强。手上有个夹在两个符号之间的地址时，`-p` 和 `-n` 给出前后邻居：

```
crash> sym -p crashlab_trigger_write.cold
ffffffffa0000070 (t) crashlab_free_list [crashlab]
ffffffffa00000bd (t) crashlab_trigger_write.cold [crashlab]
```

在决定反汇编之前，这往往是最快的一句"这地址大概在哪儿"。

### 不叫 struct 的类型

`whatis` 除了结构体，也认 typedef 和 union：

```
crash> whatis slab_flags_t
typedef unsigned int slab_flags_t;
SIZE: 4
```

一个成员只打出裸数字、你准备开始掩码和移位之前，值得先问一句：宽度是类型的一部分，不是值的一部分。

## mod -S：把模块的类型教给 crash

`struct crashlab_obj` 定义在模块里，布局在 `crashlab.ko`，不在 `vmlinux`。没告诉 `crash` 之前，它认不出这个类型：

```
crash> whatis struct crashlab_obj
whatis: cannot resolve: struct crashlab_obj
```

`mod -S` 把模块的调试信息读进来，并按模块在 dump 里的加载地址做重定位：

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

这一步顺手带出一个很安静的坑。`mod -S` 之后 `crash` 知道 `crashlab_root` 这个名字，却不知道它被搬到了哪里：

```
crash> p &crashlab_root
$1 = (struct crashlab_obj *) 0x1c0
```

`0x1c0` 是符号在目标文件里的偏移，不是内核地址。要么用模块自己打出来的地址，要么从别的结构体里读；模块数据符号的重定位结果别轻信。第 17 篇会回头算这笔账。

## 从地址到对象

类型在手，地址就能读了。三种写法等价，区别只在打印多少：

```
crash> struct crashlab_obj 0xffffffffa0201020        # 整个对象
crash> p ((struct crashlab_obj *)0xffffffffa0201020)->magic
$1 = 1129070914
crash> px ((struct crashlab_obj *)0xffffffffa0201020)->value
$2 = 0x1000
```

`struct` 最好读，`p` 加强转最好放进脚本，`px` 是十六进制的 `p`——这个会话默认十进制，所以这条差别很实在。`1129070914` 就是 `0x434c4142`，四个字节读出来是 `"CLAB"`，模块给每个对象写的魔数。

就算手上没有对象，也能问成员的偏移：

```
crash> p &((struct crashlab_obj *)0)->node
$1 = (struct list_head *) 0x20
```

地址 0 是合法的偏移算术起点，这是从 dump 里取 `offsetof()` 的标准手法。

`whatis` 也吃符号名，两张表在这里碰头：

```
crash> whatis init_task
struct task_struct init_task;

crash> p init_task.pid
$1 = 0
```

符号表给地址，类型给布局，值从 dump 里读。

## 走一遍链表

模块建了一条四节点的环形链表：头嵌在 root 对象里，后面是 `alpha`、`beta`、`gamma`。`list` 要两件事才肯走：哪个成员是链接（`-s struct.member`），以及从链接回到对象差多少（`-l`）。

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

打出来的地址是 **list_head 地址**，不是对象地址：第一个是头本身，走完 `gamma` 又回到它。`-r` 顺着 `prev` 反着走；`-o <offset>` 是 `-l` 的另一种写法，给固定字节偏移。

链表的头如果是独立的 `LIST_HEAD()`、而不是嵌在对象里，就去掉 `-l`，把头一个对象地址和 `-o` 一起给 `list`，其余一样。

## 手算 container_of

`list` 给你的是链接，对象是"链接地址减偏移"。这个减法自己算一次，后面的链表都会看得更踏实。`gamma` 的 node 在 `0xffffffffa02010a0`，偏移 `0x20`：

```
crash> eval (0xffffffffa02010a0 - 0x20)
hexadecimal: ffffffffa0201080
    decimal: 18446744072101040256  (-1608511360)
```

`struct crashlab_obj 0xffffffffa0201080` 打出来是 `name = "gamma"`、`value = 12288`。这就是 `container_of(node, struct crashlab_obj, node)`，手算版；模块把 `node` 放在最后，正是为了不让这个偏移等于零——等于零的话算术没了，课也白上了。

## 同一个手法，换成内核的链表

模块的链表是故意做小的，但上面这些不是模块专属。进程链表就是 `task_struct` 里的一个 `list_head`，头是 `init_task` 内嵌的 `tasks`：

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

`init_task` 走符号表就能解析，这条不需要 `dmesg`；容器偏移是 `936`（`0x3a8`）。链表是环形的，走回 `init_task` 就停。把任意一个 `tasks` 地址减去这个偏移，得到的就是可以丢给 `struct` 的 `task_struct`，后面大多数和任务相关的文章都从这里起步。

## 反汇编，以及有源码的时候

`dis` 把符号背后的指令摊开：

```
crash> dis crashlab_trigger_write
0xffffffffa0000000 <crashlab_trigger_write>:	endbr64
0xffffffffa0000004 <crashlab_trigger_write+4>:	xor    %eax,%eax
0xffffffffa0000006 <crashlab_trigger_write+6>:	test   %rdx,%rdx
0xffffffffa0000009 <crashlab_trigger_write+9>:	je     0xffffffffa0000062 <crashlab_trigger_write+98>
[...]
0xffffffffa0000024 <crashlab_trigger_write+36>:	jne    0xffffffffa000004e <crashlab_trigger_write+78>
```

加 `-l` 会把源码行插进来，因为 DWARF 记下了构建路径：

```
crash> dis -l crashlab_trigger_write
~/crash-lab/crashlab/crashlab.c: 90
0xffffffffa0000000 <crashlab_trigger_write>:	endbr64
~/crash-lab/crashlab/crashlab.c: 93
0xffffffffa0000004 <crashlab_trigger_write+4>:	xor    %eax,%eax
```

源码树后来搬过家，记录里的路径就失效，行号也就没了。`crash --src ~/crash-lab/linux ...` 把内核符号指到新位置；模块的路径跟着模块自己的 DWARF 走。

## 地址翻译，一页一页来

`vtop` 走页表。模块数据页：

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

这个 PTE 值可以再交回给 `crash`：

```
crash> pte 80000000030ee163
      PTE         PHYSICAL  FLAGS
80000000030ee163   30ee000  (PRESENT|RW|ACCESSED|DIRTY|GLOBAL|NX)
```

`pte` 要的是 PTE，不是虚拟地址；给错了不会报错，只会得到一段看不懂的查找。`ptov` 反着走，从物理到虚拟，但它给的是**直接映射**地址，不是你出发的那个模块地址：

```
crash> ptov 0x30ee020
ffff8880030ee020
```

两个虚拟地址指向同一个物理页。这不是工具出错：模块页和它的直接映射别名是两个映射，读内存时得清楚自己在看哪一个。

页粒度的换算是同一套算术：`btop <addr>` 得页号，`ptob <page>` 得页对齐地址。

```
crash> btop 0x30ee020
30ee020: 30ee
crash> ptob 30ee
30ee: 30ee000
```

## KASLR，以及两张表何时对不上

这个内核 `CONFIG_RANDOMIZE_BASE=n`，`vmlinux` 里的符号地址就是 dump 里的运行地址，上面这些一次都没用到偏移。开了 KASLR，所有地址按每次启动的偏移移动，文件里的符号对不上内存，`crash` 得从 dump 的 notes 里拿偏移：notes 还在就用 `--kaslr auto`，notes 丢了就从 panic 日志的 `Kernel Offset:` 取 `--kaslr <offset>`。类型系统不受影响——偏移移动的是地址，不是布局——但每一条 `sym` 的答案都受影响。

## 当"链表"其实是棵树

`list` 顺着 `next`/`prev` 走。内核里还有 radix tree、XArray、maple tree、rbtree，这些不是链表：`crash` 用 `tree -t xarray|maple|rbtree <root>` 走，`-s`/`-l` 的思路一样。某个结构体明明有 `list_head` 却怎么都找不到你的对象，先怀疑拿错了成员：`whatis struct <type>` 会把成员列全，你想要的那个可能是个树节点。

## 配置不够时，这些命令怎么用

本篇有几样工具要内核选项配合，本实验没有开。命令形式仍然值得知道，重编一次就能用：

- **`rustfilt <symbol>`**：把 Rust 符号（`_RNv...`）还原成人能读的 `crate::module::function`。需要 `CONFIG_RUST=y`；Rust 关着就没有可还原的名字，所以这篇没有它的输出。真用得上时，`sym` 和 `bt` 给的是名字，`rustfilt` 给的是能读的名字。
- **`tree -t xarray|maple|rbtree <root>`**：走树，不走 `list_head`。根地址从拥有它的结构体里取，比如 VMA 的 maple tree 是 `p &<task>->mm->mm_mt`；`-s`/`-l` 描述条目的方式和 `list` 一样。发现自己拿到的是树节点而不是链表链接时，换它。
- **`kmem -s`**：走 slab 需要 `CONFIG_SLUB_DEBUG=y`。没有时 `crash` 会直说：

  ```
  crash> kmem -s
  kmem: option requires kmem_cache_node.nr_slabs member!
  (the kernel must be built with CONFIG_SLUB_DEBUG)
  ```

  `whatis struct kmem_cache` 照常可用，所以类型这一侧不受影响。

规律是一样的：哪条命令报出它要的 `CONFIG_` 选项，那就是重编清单；加上、重编、重抓 dump。

## 易错点

- `p <地址>` 打的是指针的数值。要读对象，用 `struct <type> <地址>` 或加强转。
- `struct` 要的是**对象**地址，不是它 `list_head` 的地址。
- `list` 配 `-l` 要给链接地址，配 `-o` 要给对象地址；混着来会得到看着像样、其实全错的输出。
- 模块类型要 `mod -S`；模块数据符号要 `CONFIG_KALLSYMS_ALL`。本实验两样都没开。
- 模块数据符号解析出一个小数值（比如 `0x1c0`），那是文件内偏移，不是地址。
- `vtop` 翻用户地址用的是当前上下文，先 `set` 到那个任务。
- `pte` 要 PTE 值，不是虚拟地址；值从 `vtop` 来。
- `dis -l` 和 `--src` 需要 DWARF 记录里的源码树；引用行号之前先确认。
- KASLR 破坏的是文件到内存的地址映射，不是类型。

## 练习

1. 走一遍模块的链表，打出第二个普通对象的 `magic` 和 `name`。对象地址从哪条命令来，偏移是多少？
2. 把一个 `crashlab_obj` 的虚拟地址翻成物理地址再翻回来。它的 PTE 里哪些标志置位？为什么 `ptov` 的结果不是你出发的那个地址？
3. 哪条命令给出 `struct kmem_cache` 的定义，哪条打印某个具体地址上的内容？

答案见 [`answers.md`](answers.md)。

## 速查

| 想做的事 | 命令 |
| --- | --- |
| 符号的地址 | `sym <name>` |
| 地址对应的符号 | `sym <address>` |
| 类型长什么样 | `whatis struct <type>` |
| 地址上的对象 | `struct <type> <address>` |
| 单个成员 | `p ((struct <type> *)<address>)-><member>` |
| 十六进制输出 | `px <expr>` |
| 成员偏移 | `p &((struct <type> *)0)-><member>` |
| 加载模块类型 | `mod -S <dir>` |
| 走链表 | `list -s <type>.<member> -l <type>.<member> <head>` |
| 反着走 | `list -r ...` |
| 地址算术 | `eval (<a> - <b>)` |
| 指令 | `dis <symbol>` |
| 指令加行号 | `dis -l <symbol>` |
| 虚拟转物理 | `vtop <address>` |
| 物理转虚拟 | `ptov <physical>` |
| 解 PTE | `pte <value>` |
| 页号换算 | `btop <address>`、`ptob <page>` |

---

**版本。** `crash 9.0.3++`（gdb 16.2）；内核 `7.3.0+`（x86_64，DWARF5，
`UNWINDER_ORC=y`，`KALLSYMS_ALL=n`，无 KASLR）；模块 `crashlab.ko` 与同一棵树
编译；dump `vmcore-raw`，`makedumpfile -l -d 31`。模块地址和堆地址每次运行都会
变，链表头从 `dmesg` 取。

上一篇：[命令语言](../03-the-command-language/index.html) · 下一篇：待发布
