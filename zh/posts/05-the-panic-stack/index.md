# panic 栈：读懂崩溃现场

**panic 栈最上面几帧不是内核panic的原因。真正原因在中间的异常帧**

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

0 到 6 帧：报告缺页，oops 处理程序，`kexec` 切换到 crash 内核。

异常帧：内核当时在执行 `crashlab_trigger_write.cold+63`。7 到 11 帧：一次 `write(2)` 经过通用写路径调用了该模块函数。

## 先看 log

banner 只有一行摘要，全文在 `log` 里：

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

从这几行能直接读出：这是一次写操作，在进程上下文（`Comm: bash`），CPU 1，出错地址是零。`Kdump: loaded` 说明 crash 内核已经加载。

`CR2` 是出错的地址，`RIP` 是执行访问的指令。

## 找 panic 任务

```
crash> bt -p
PID: 581      TASK: ffff88807db98000  CPU/NUMA:    1/0    COMMAND: "bash"
```

`bt -p` 直接给 panic 任务。没有 panic notes 的 dump（比如 QEMU monitor 抓的）会失败，这时用 `bt -a`：

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

栈里有 `page_fault_oops`/`oops_end` 的那个 CPU 就是panic cpu。另外三个停在 `pv_native_safe_halt`，那是 crash 路径用 NMI 打出来的回溯。

## 异常帧

`bt -e` 打印所有异常帧：

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

两个内核态帧的 `RIP` 相同，因为 oops 路径在栈上不止一处留下了同一份寄存器。最下面的用户态帧是系统调用的返回帧，不是第二次故障。

这个帧是内存里的 `struct pt_regs`，可以直接读：

```
crash> px ((struct pt_regs *)0xffffc90000e6bbb8)->ip
$1 = 0xffffffffa00000a2
crash> px ((struct pt_regs *)0xffffc90000e6bbb8)->sp
$2 = 0xffffc90000e6be18
```

`ip` 和出错指令一致，`sp` 和帧里的 `RSP` 一致。

失败的那条指令：

```
crash> dis ffffffffa00000a2
0xffffffffa00000a2 <crashlab_trigger_write.cold+63>:	movl   $0xdeadbeef,0x0
```

把 `0xdeadbeef` 写到绝对地址 0。`.cold` 是这个函数的冷路径段，符号名带 `.cold` 是正常的。

## 寄存器里的五个字节

`RAX` 和 `RBX` 都是 `5`，正好是 `echo null` 写出的字节数（`"null\n"`）：

```
crash> px ((struct pt_regs *)0xffffc90000e6bbb8)->ax
$3 = 0x5
```

写调用把这五个字节拷进模块 16 字节的缓冲区，字符串比较相等，随后发生空指针写。

## 栈上的返回地址

`bt -f` 把每帧旁边的raw 数据一起打出来：

```
crash> bt -f
 #0 [ffffc90000e6bb98] machine_kexec at ffffffff810e5a8d
    ffffc90000e6bba0: ffffc90000e6bd68 ffffffff81191acc
 [...]
    ffffc90000e6bc30: ffffffffffffffff ffffffffa00000a2
```

栈上的 `ffffffffa00000a2` 和异常 `RIP` 相同；`ffffffff81191acc` 是 `__crash_kexec`。符号不可靠时，用这些raw数据核对。

## 源码行

`bt -l` 给每帧加上源码位置：

```
crash> bt -l
 #0 [ffffc90000e6bb98] machine_kexec at ffffffff810e5a8d
    /home/you/git/private/ai/linux/arch/x86/kernel/machine_kexec_64.c: 454
 #1 [ffffc90000e6bba8] __crash_kexec at ffffffff81191acc
    /home/you/git/private/ai/linux/kernel/crash_core.c: 145
```

模块帧要有行号，得先用 `mod -S` 加载模块调试信息。

内核自己那份 Call Trace 里有 `?` 开头的行：

```
 ? filp_flush+0x4b/0x80
 ? filp_close+0x20/0x30
```

`?` 表示展开不确定。它们是更早调用留在栈上的返回地址，不在这条调用链上。

## 进程上下文还是中断上下文

- 栈底是 `entry_SYSCALL_64_after_hwframe`，`CS: 0033`，任务从用户态进来；
- 出错帧是普通函数，不是 `irqentry_*`；
- panic 任务是 `bash`，那个 CPU 上的 `current` 也是它。

中断上下文出错时栈从入口代码开始，可能没有来自用户态的 `pt_regs`，`current` 也未必是出错的任务。

确认任务本身：

```
crash> set -p
crash> task
    PID: 581
COMMAND: "bash"
   TASK: ffff88807db98000  [THREAD_INFO: ffff88807db98000]
    CPU/NUMA:    1/0
  STATE: TASK_RUNNING (PANIC)
```

## 症状和原因

| 帧 | 归类 | 说明 |
| --- | --- | --- |
| `asm_exc_page_fault` | 怎么死的 | 缺页进了入口代码 |
| `page_fault_oops` | 怎么死的 | 内核态缺页且致命 |
| `oops_end` | 怎么死的 | 内核决定停机 |
| `crash_kexec`、`machine_kexec` | 怎么死的 | crash 内核接手 |
| `full_proxy_write` | 为什么死的 | debugfs 把写转发给模块 |
| `crashlab_trigger_write.cold+63` | 为什么死的 | 模块往地址 0 写数据 |

## 练习

1. 哪个 CPU 崩了，当时在跑哪个任务？给出证据。
2. 出错地址是多少，哪条指令访问了它？用命令把两件事都证明出来。
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
| panic 全文 | `log -T` |
| 地址上的指令 | `dis <address>` |
| 读保存的寄存器 | `p *(struct pt_regs *)<addr>` |
| 选中 panic 任务 | `set -p` |
| 这是哪个任务 | `task` |

---

**版本。** `crash 9.0.3++`（gdb 16.2）；内核 `7.3.0+`（x86_64，DWARF5，
`UNWINDER_ORC=y`，`KALLSYMS_ALL=n`，无 KASLR）；dump `vmcore`，
`makedumpfile -l -d 31`；panic 由一次 NULL 写触发。

上一篇：[查看符号、类型与地址](../04-symbols-types-addresses/index.html) · 目录：[全部文章](../../index.html)
