# panic 栈：读懂崩溃现场

**panic 栈最上面那几帧讲的是内核怎么死的，不是为什么死的。原因在中间的异常帧，来路在它下面。**

打开 `null` 那份 dump，直接跑 `bt`：

```
crash> bt
PID: 581      TASK: ffff88807db98000  CPU/NUMA:    1/0    COMMAND: "bash"
 #0 [ffffc90000e6bb98] machine_kexec at ffffffff810e5a8d
 #1 [ffffc90000e6bba8] __crash_kexec at ffffffff81191acc
 #2 [ffffc90000e6bc60] crash_kexec at ffffffff81191ffb
 #3 [ffffc90000e6bc70] oops_end at ffffffff810c4973
 #4 [ffffc90000e6bc90] page_fault_oops at ffffffff810ecdc7
 #5 [ffffc90000e6bd10] exc_page_fault at ffffffff8166d18c
 #6 [ffffc90000e6bd60] asm_exc_page_fault at ffffffff810011b6
    [exception RIP: crashlab_trigger_write.cold+63]
    RIP: ffffffffa00000a2  RSP: ffffc90000e6be18  RFLAGS: 00010286
    RAX: 0000000000000005  RBX: 0000000000000005  RCX: ffffffff81bfbff8
    RDX: ffffc9000003f1c8  RSI: 0000000000000001  RDI: ffffc9000003d2c0
    RBP: ffff888002ec6180   R8: 3fffffffffffbfff   R9: ffffffff81b87288
    R10: bfffffffffffc000  R11: 3fffffffffffc000  R12: 000055698282ffa0
    R13: 0000000000000005  R14: ffffc90000e6bf00  R15: ffff88800331d300
    ORIG_RAX: ffffffffffffffff  CS: 0010  SS: 0018
 #7 [ffffc90000e6be30] full_proxy_write at ffffffff8136ec89
 #8 [ffffc90000e6be68] vfs_write at ffffffff81250f1d
 #9 [ffffc90000e6bee8] ksys_write at ffffffff812513e6
#10 [ffffc90000e6bf18] do_syscall_64 at ffffffff816690c6
#11 [ffffc90000e6bf40] entry_SYSCALL_64_after_hwframe at ffffffff810000b0
    RIP: 00007f2e8955022e  RSP: 00007ffe3f258bf0  RFLAGS: 00000202
    ORIG_RAX: 0000000000000001  CS: 0033  SS: 002b
```

0 到 6 帧都不是故障本身，而是内核的死法：缺页被报告，oops 处理程序判定这次必须停机，`kexec` 把机器交给 crash 内核。任何一次 panic 都会有类似的一串，NULL 解引用、`BUG()`、主动 `panic()` 长得差不多。

原因在异常帧里：内核当时正在执行 `crashlab_trigger_write.cold+63`，动了一块不该动的内存。7 到 11 帧则是来路——一次 `write(2)` 经过通用写路径进了模块。

## 先从 log 看起

banner 只给一行摘要，全文在 `log` 里，而且以它为准：

```
crash> log -T | grep -E 'BUG:|#PF|Oops:|RIP: 0010|CR2|CPU:' | head
[...] BUG: kernel NULL pointer dereference, address: 0000000000000000
[...] #PF: supervisor write access in kernel mode
[...] #PF: error_code(0x0002) - not-present page
[...] Oops: Oops: 0002 [#1] SMP
[...] CPU: 1 UID: 0 PID: 581 Comm: bash Kdump: loaded Tainted: G           O         7.3.0+ #16 PREEMPT(full)
[...] RIP: 0010:crashlab_trigger_write.cold+0x3f/0x5d [crashlab]
[...] CR2: 0000000000000000 CR3: 000000007dae6006 CR4: 0000000000172eb0
```

四条事实已经够描述这次崩溃：这是一次写、发生在进程上下文（`Comm: bash`，不是中断）、在 CPU 1 上、出错地址是零。`Kdump: loaded` 说明 crash 内核已经武装好，否则根本不会有这份 dump。

`CR2` 是出错的地址，`RIP` 是执行那次访问的指令。两个别混：前者说指针指到了哪儿，后者说是哪条指令动的。

## 找到 panic 任务

`bt -p` 直接要 panic 任务，是最省事的入口：

```
crash> bt -p
PID: 581      TASK: ffff88807db98000  CPU/NUMA:    1/0    COMMAND: "bash"
```

它不奏效的时候——比如没有 panic notes 的 QEMU monitor dump——就退到 `bt -a`。哪条栈上有 oops 的痕迹，哪个 CPU 就是肇事者：

```
crash> bt -a
PID: 581      TASK: ffff88807db98000  CPU/NUMA:    1/0    COMMAND: "bash"
 #0 [ffffc90000e6bb98] machine_kexec at ffffffff810e5a8d
 [...]
PID: 0        TASK: ffffffff81a0a680  CPU/NUMA:    0/0    COMMAND: "swapper/0"
 #0 [fffffe000000dea8] crash_nmi_callback at ffffffff810dd0ef
 #1 [fffffe000000deb0] default_do_nmi at ffffffff8166bff9
 [...]
```

另外三个 CPU 停在 `pv_native_safe_halt` 里，它们的"栈"其实是 NMI 回溯——crash 路径用 NMI 把它们按住了。一个 CPU 有 oops 路径、其余在 idle，这正是进程上下文单线程故障该有的样子。

## 栈要顺着读，也要倒着读

从上往下，数字告诉你死法；从下往上，帧讲述来路。

- **#11 `entry_SYSCALL_64_after_hwframe`**：系统调用入口，再往下就是用户态（`CS: 0033`）。
- **#10 `do_syscall_64` → #9 `ksys_write` → #8 `vfs_write`**：通用写路径，任务确实调了 `write()`。
- **#7 `full_proxy_write`**：debugfs 的代理层，把写转发给文件自己的 `write`。
- **#6 `asm_exc_page_fault` → #4 `page_fault_oops` → #3 `oops_end`**：缺页被接手，并判定为致命。
- **#2 `crash_kexec` → #1 `__crash_kexec` → #0 `machine_kexec`**：内核退场。

异常帧夹在 #6 和 #7 之间，它的 `RIP` 就是失败的指令：

```
crash> dis ffffffffa00000a2
0xffffffffa00000a2 <crashlab_trigger_write.cold+63>:	movl   $0xdeadbeef,0x0
```

整次崩溃就在这一行里：把 `0xdeadbeef` 写到绝对地址 0。`$0x0` 是 32 位绝对寻址形式，所以出错地址是 `CR2 = 0`，不是什么"恰好为空"的变量。

注意符号后缀：`crashlab_trigger_write.cold`。GCC 会把函数拆成热路径和一段外置的冷路径，NULL 这次落在冷段里，冷段从函数起点后 0xbd 字节开始。`bt` 打出 `.cold` 很正常，不是符号坏了。机制在第 4 篇的 `dis` 里讲过。

## 寄存器里的五个字节

异常帧里的寄存器不是摆设。`RAX` 和 `RBX` 都是 `5`，正好是这次写入的长度：`echo null` 送出的是 `"null\n"`，五个字节。写路径把这五个字节拷进模块 16 字节的缓冲区，字符串比较相等，然后就是那一写。

```
crash> px ((struct pt_regs *)0xffffc90000e6bbb8)->ax
$3 = 0x5
```

寄存器里的值能对上一个明显的用户输入，是把内核帧和"有人敲了什么"对起来的最便宜办法。它也顺便提醒：模块完全信任输入，五个字节就够了。

## 栈本身也是数据

`bt -f` 会把每帧旁边的原始字一起打出来，其中一个就是保存的返回地址：

```
crash> bt -f
 #0 [ffffc90000e6bb98] machine_kexec at ffffffff810e5a8d
    ffffc90000e6bba0: ffffc90000e6bd68 ffffffff81191acc
 [...]
    ffffc90000e6bc30: ffffffffffffffff ffffffffa00000a2
```

栈上的 `ffffffffa00000a2` 和异常 `RIP` 是同一个值；`ffffffff81191acc` 是 `__crash_kexec`，返回给调用者的地址。符号缺失或者不可靠时，这些原始字就是最后的依据：`sym <地址>` 能还原名字，一串返回地址的排布仍然勾出调用链。

## 源码行

`bt -l` 会给每帧插上源码位置：

```
crash> bt -l
 #0 [ffffc90000e6bb98] machine_kexec at ffffffff810e5a8d
    /home/you/git/private/ai/linux/arch/x86/kernel/machine_kexec_64.c: 454
 #1 [ffffc90000e6bba8] __crash_kexec at ffffffff81191acc
    /home/you/git/private/ai/linux/kernel/crash_core.c: 145
```

模块帧要有行号，得先把模块调试信息加载进来（`mod -S`）；没有的话拿到符号加偏移，也足够反汇编了。

## 日志里的 `?` 帧

内核自己那份 Call Trace 和 `crash bt` 不是同一个列表。这次 oops 里有这样的行：

```
 ? filp_flush+0x4b/0x80
 ? filp_close+0x20/0x30
 ? do_dup2+0xa9/0x140
 ? ksys_dup3+0x62/0xe0
```

前面的 `?` 表示展开器不确定这一帧。它们其实是更早调用留在栈上的返回地址——shell 刚做过文件描述符操作——不在这条调用链上。当噪声处理就好：确认过的链路很短，入口、系统调用、写、代理、模块。

## 异常帧可以直接当结构体读

`bt -e` 把展开器能找到的异常帧都打出来：

```
crash> bt -e
  KERNEL-MODE EXCEPTION FRAME AT: ffffc90000e6bbb8
    [exception RIP: crashlab_trigger_write.cold+63]
    RIP: ffffffffa00000a2  RSP: ffffc90000e6be18  RFLAGS: 00010286
    RAX: 0000000000000005  RBX: 0000000000000005  [...]
    ORIG_RAX: ffffffffffffffff  CS: 0010  SS: 0018

  KERNEL-MODE EXCEPTION FRAME AT: ffffc90000e6bd68
    [exception RIP: crashlab_trigger_write.cold+63]
    [...]

  USER-MODE EXCEPTION FRAME AT: ffffc90000e6bf48
    [...]
```

两个内核态帧、`RIP` 相同，这里是正常的：oops 路径在栈上不止一处留下了同一份寄存器，展开器把每一处都报了出来。最下面的用户态帧是系统调用的返回帧，不是第二次故障。

这个帧就是内存里的 `struct pt_regs`，可以当普通结构体读：

```
crash> px ((struct pt_regs *)0xffffc90000e6bbb8)->ip
$1 = 0xffffffffa00000a2
crash> px ((struct pt_regs *)0xffffc90000e6bbb8)->sp
$2 = 0xffffc90000e6be18
```

`ip` 和出错指令一致，`sp` 和帧里的 `RSP` 一致。这样就能确认展开器指的是你以为的那一帧，而不是某份过期的副本。

## 进程上下文，还是中断上下文

栈的形状先于推理给出答案：

- 最下面是 `entry_SYSCALL_64_after_hwframe`，`CS: 0033`，任务从用户态进来；
- 出故障的帧是普通函数，不是 `irqentry_*`，也不是异常栈；
- panic 任务是 `bash`，那个 CPU 上的 `current` 也是它。

中断上下文出错长得不一样：栈从入口代码开始，可能根本没有来自用户态的 `pt_regs`，`current` 只是"当时恰好在跑的那个任务"。两者一混，就会怪错人。

任务本身要确认，不能想当然：

```
crash> set -p
crash> task
    PID: 581
COMMAND: "bash"
   TASK: ffff88807db98000  [THREAD_INFO: ffff88807db98000]
    CPU/NUMA:    1/0
  STATE: TASK_RUNNING (PANIC)
```

`STATE: TASK_RUNNING (PANIC)` 是 `crash` 在和栈对口径：这是内核选中的 panic 任务，它当时正跑在出故障的 CPU 上。

## 症状和原因

动笔之前，把帧分成两堆。

| 帧 | 归类 | 说明 |
| --- | --- | --- |
| `asm_exc_page_fault` | 怎么死的 | 缺页进了入口代码 |
| `page_fault_oops` | 怎么死的 | 内核态缺页且致命 |
| `oops_end` | 怎么死的 | 内核决定停机 |
| `crash_kexec`、`machine_kexec` | 怎么死的 | crash 内核接手 |
| `full_proxy_write` | 为什么死的 | debugfs 把写转发给了模块 |
| `crashlab_trigger_write.cold+63` | 为什么死的 | 模块往地址 0 写了数据 |

一个简单的检验：把模块那一帧换个别的 bug，如果"原因"这一堆不变，那你还在读死法。

## 易错点

- 最上面那帧是死的地方，不一定死因。要越过 `oops_end` 和 `crash_kexec` 往下看。
- `bt -p` 依赖 panic notes。QEMU monitor 的 dump 没有，说明情况并改用 `bt -a`。
- 栈里带 `?` 的帧表示展开不确定，别拿它下结论。
- 内联和优化会搬代码：`crashlab_trigger_write.cold` 还是同一个函数，不是另一个。
- `CR2` 是被访问的地址，`RIP` 是执行访问的指令；把两者当同一件事是常见错误。
- 中断上下文出错时栈形状不同，`current` 未必是受害者。
- panic 字符串可能描述的是次生故障（锁检查报错后 panic、链表损坏后 `BUG()`），不是第一个错误。

## 练习

1. 哪个 CPU 崩了，当时在跑哪个任务？要给出证据，而不只是结论。
2. 出错地址是多少，哪条指令解引用了它？用命令把两件事都证明出来。
3. 这次故障在进程上下文还是中断上下文？哪几帧能证明？

答案见 [`answers.md`](answers.md)。

## 速查

| 想做的事 | 命令 |
| --- | --- |
| 只看 panic 任务 | `bt -p` |
| 所有 CPU | `bt -a` |
| 某个 CPU | `bt -c N` |
| 栈加原始字 | `bt -f` |
| 带源码行 | `bt -l` |
| 异常帧 | `bt -e` |
| panic 全文 | `log -T`（或 `log`） |
| oops 头 | `log` 里 `BUG:` / `RIP:` 附近 |
| 地址上的指令 | `dis <address> [count]`（只给地址只反汇编一条） |
| 读保存的寄存器 | `p *(struct pt_regs *)<addr>` |
| 选中 panic 任务 | `set -p` |
| 这是哪个任务 | `task` |

---

**版本。** `crash 9.0.3++`（gdb 16.2）；内核 `7.3.0+`（x86_64，DWARF5，
`UNWINDER_ORC=y`，`KALLSYMS_ALL=n`，无 KASLR）；dump `vmcore`，
`makedumpfile -l -d 31`；panic 由一次 NULL 写触发，`panic_on_oops=1`。地址和
PID 来自某一次运行。

上一篇：[符号、类型与地址](../04-symbols-types-addresses/index.html) · 目录：[全部文章](../../index.html)
