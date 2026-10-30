# 认识 crash：怎样调用crash

**一次 crash 会话需要用户提供两个文件：一个提供内存dump数据（vmcore），一个提供调试信息（vmlinux）。**

例如以下测试中同一份 dump，两个不同的 vmlinux。第一个直接报错被拒：

```
WARNING: could not find MAGIC_START!
crash: ~/crash-lab/build-shift/vmlinux and ~/crash-lab/vmcore do not match!
```

第二个有一行警告但能打开正常工作：

```
WARNING: kernel version inconsistency between vmlinux and dumpfile

      KERNEL: ~/crash-lab/build-2/vmlinux
    DUMPFILE: ~/crash-lab/vmcore  [PARTIAL DUMP]
        CPUS: 4
        DATE: Mon Oct 26 18:58:21 CST 2026
      UPTIME: 00:03:58
LOAD AVERAGE: 0.72, 0.21, 0.07
       TASKS: 94
    NODENAME: localhost.localdomain
     RELEASE: 7.3.0+
     VERSION: #16 SMP PREEMPT_DYNAMIC Mon Oct 26 14:48:51 CST 2026
     MACHINE: x86_64  (2693 Mhz)
      MEMORY: 2 GB
       PANIC: "Oops: Oops: 0002 [#1] SMP" (check log for details)
```

`bt` 对，`sys` 对，oops 也讲得通。可这个 namelist 仍然不是崩掉的那个内核：它是另一次构建生成的vmlinux。

第一个在 `.config` 里多开了 `CONFIG_IKCONFIG=y`；第二个用与崩溃内核完全相同的 `.config`、在同一份干净的源码副本里重新编译的。

![crash 的三个输入：vmlinux 提供符号与类型，vmcore 提供内存与 notes，模块 .ko 提供模块调试信息。下方是 vmcore 的 ELF 布局](assets/crash-inputs.svg)

## 三个参数输入，其中一个是可选的

`crash` 打开一份 dump 需要两样东西：

- **namelist**，也就是构建目录里的 `vmlinux`。符号、结构体布局、枚举值、源码行号，都从这里来。
- **内存镜像**，也就是 `vmcore`。寄存器状态、task 结构、slab 页、日志缓冲区，都从这里来。

第三样输入是带调试信息的内核模块ko文件，只要栈里出现模块就变得很关键，`vmlinux` 只知道模块的基地址和少量模块文本符号，不知道 `struct crashlab_dir` 长什么样，也不知道 `crashlab.c` 的哪一行崩了。第 17 篇会涉及到这个主题。

另外还有**内核源码树**。如果它还留在 DWARF 记录的路径上，`bt -l` 和 `--src` 就能给出源码行。

另外需要注意：`bzImage`是压缩过的启动镜像，不是 namelist。如果用它替代vmlinux，crash会报错：

```
crash: ~/crash-lab/bzImage: not a supported file format
```

`System.map` 也不是 namelist，它只有地址到名字的映射：

```
crash: namelist argument required
```

因为它只有符号没有类型，例如得不到 `struct task_struct`。

## vmcore 里到底有什么

vmcore 分为两种格式　(kdump压缩格式和ELF格式)。

本实验里的 dump 是 **kdump 压缩格式**：`makedumpfile` 过滤并压缩了页面，不是能直接丢给 `readelf` 的 ELF。`file` 说得最清楚：

```
vmcore: Kdump compressed dump v6, system Linux, node localhost.localdomain,
release 7.3.0+, version #16 SMP PREEMPT_DYNAMIC Mon Oct 26 14:48:51 CST 2026,
machine x86_64, domain (none)
```

另一种是普通 **ELF core 文件**，`makedumpfile -E` 和 QEMU monitor 的 `dump-guest-memory` 都产出这种。信息一样，不压缩，`readelf` 能直接看。下面是对同一台 guest 用 monitor 抓的一份：

```
Elf file type is CORE (Core file)
Entry point 0x0
There are 8 program headers, starting at offset 192

Program Headers:
  Type           Offset             VirtAddr           PhysAddr
                 FileSiz            MemSiz              Flags  Align
  NOTE           0x0000000000000280 0x0000000000000000 0x0000000000000000
                 0x0000000000000cc0 0x0000000000000cc0         0x0
  LOAD           0x0000000000000f40 0x0000000000000000 0x0000000000000000
                 0x0000000000030000 0x0000000000030000         0x0
  LOAD           0x0000000000030f40 0x0000000000050000 0x0000000000050000
                 0x0000000000050000 0x0000000000050000         0x0
[...]
```

一个 `NOTE` 段，七个 `LOAD` 段。`LOAD` 段是物理内存：第一段是 1MB 之前的空洞，第二段是 VGA/BIOS 区，剩下的段摊开 2GB 的 guest 内存。

真正有意思的是 `NOTE` 段。`readelf -n` 能看到四个 `NT_PRSTATUS`，每个 vCPU 一个，各自带着那一刻的寄存器。`bt -a` 的四条栈就是从这里来的；另外还有 `NT_PRPSINFO` 和辅助向量。

kdump 的 dump 比 monitor dump 多一样东西：**`VMCOREINFO`**，由崩溃时的内核写入。`crash` 从里面读出 release、build ID、页大小、`phys_base`，以及把虚拟地址换算成 dump 偏移所需的那些值。少了它，`crash` 会直接告诉你：

```
crash: cannot read vmcoreinfo_data
      KERNEL: ~/crash-lab/linux/vmlinux
    DUMPFILE: [...]
       PANIC: ""
```

后果不难想：没有 panic task，会话只能落在 `swapper/0` 上。dump 本身仍然有用——它是一份完整的内存快照——但得用户告诉 `crash` 相关信息，这正是 `--no_panic` 和 `--machdep` 的用武之地。

## banner 是一张核对表

每次打开会话都会先从上到下过一遍。

- **`KERNEL`**：你给的 namelist，外加 `[TAINTED]`，因为内核装了树外模块。
- **`DUMPFILE`**：内存镜像，外加 `[PARTIAL DUMP]`，因为这次用 `makedumpfile -d 31` 过滤过。free、cache、cache-private、user 页都没写进去。
- **`CPUS`、`DATE`、`UPTIME`**：4 个 CPU、崩溃时间、以及 guest 只跑了三分五十八秒。
- **`LOAD AVERAGE`、`TASKS`、`NODENAME`**：0.72/0.21/0.07、94 个任务、`localhost.localdomain`。
- **`RELEASE` 与 `VERSION`**：`7.3.0+`、`#16 SMP PREEMPT_DYNAMIC Mon Oct 26 14:48:51 CST 2026`。
- **`MACHINE`**：`x86_64 (2693 Mhz)`。
- **`MEMORY`**：2 GB。
- **`PANIC`**：`"Oops: Oops: 0002 [#1] SMP" (check log for details)`，内核dmesg全文可用 `log` 命令查看。

## 检查两个文件是否配套的简洁命令

```sh
crash --osrelease <vmcore>     # dump 记录的 release 字符串
crash --build-id <vmcore>      # dump 记录的 build ID
crash -g <vmlinux>             # 这个 namelist 里有没有 DWARF
crash -t <vmlinux> <vmcore>    # dump 是什么时候抓的
```

在本实验的 dump 上：

```
$ crash --osrelease ~/crash-lab/vmcore
7.3.0+

$ crash --build-id ~/crash-lab/vmcore
6460abf30df798ec67d2db4aae0d9a1fcdfb9f63

$ crash -g ~/crash-lab/linux/vmlinux
[... gdb banner ...]
crash: /home/you/crash-lab/linux/vmlinux: contains debugging data

$ crash -t ~/crash-lab/linux/vmlinux ~/crash-lab/vmcore
Mon Oct 26 18:58:21 CST 2026
```

前两条读的是 dump 里的 `VMCOREINFO`，它们只说明 dump 是什么，不说明 namelist 是什么。namelist 那一侧则要看 ELF note：

```sh
readelf -n ~/crash-lab/linux/vmlinux | grep -A1 'Build ID'
```

开篇那三个 namelist 和 dump 的 build ID ：

| 文件 | build ID | 版本串 |
| --- | --- | --- |
| 这份 dump | `6460abf3…` | `7.3.0+ #16 SMP PREEMPT_DYNAMIC Mon Oct 26 14:48:51 CST 2026` |
| 匹配的 `vmlinux` | `6460abf3…` | 同上 |
| 同配置重编 | `0a649fbb…` | `7.3.0+ #2 …` |
| 移位构建（`IKCONFIG=y`） | `5d2a2a5a…` | `7.3.0+ #1 …` |

## 内核模块

栈里一出现 `[module]` 后缀，就是内核在加载时建的表。本实验的 `CONFIG_KALLSYMS_ALL` 是关的，于是：

```
crash> sym crashlab_trigger_write.cold
ffffffffa00000bd (t) crashlab_trigger_write.cold [crashlab]

crash> sym crashlab_dir
symbol not found: crashlab_dir
possible alternatives:
  (none found)
```

因为它在文本段所以函数能解析；模块的全局变量 `crashlab_dir` 不能，因为它是数据：

```
     MODULE       NAME         TEXT_BASE       SIZE  OBJECT FILE
ffffffffa0201100  crashlab  ffffffffa0000000  12288  (not loaded)  [CONFIG_KALLSYMS]
```

这个模块确实加载了、确实触发了故障，它的 `struct module` 在 `0xffffffffa0201100` 处读出来是 `MODULE_STATE_LIVE`。这里的 `(not loaded)` 是 `crash` 在说：因为没有数据符号所以它无法完成这个关联。

## 练习

1. 一份 `vmcore`、三个候选 `vmlinux`，哪个是对的？用哪两条命令证明？
2. 会话打开时只有 `WARNING: kernel version inconsistency between vmlinux and dumpfile`，之后每条命令看着都对。为什么这次会话仍不可信？在发布任何结论前你会做什么？
3. 类型由哪个输入提供，内存内容由哪个提供？如果只有 `System.map`，你失去了什么？

答案与推理见 [`answers.md`](answers.md)。

## 本篇用到的命令

| 命令 | 回答什么问题 |
| --- | --- |
| `crash --version`、`crash --buildinfo` | 这是哪个 crash，怎么编出来的 |
| `crash --osrelease <vmcore>` | dump 自称是哪个 release |
| `crash --build-id <vmcore>` | dump 自称是哪次构建 |
| `crash -g <vmlinux>` | 这个 namelist 里有没有 DWARF |
| `crash -t <vmlinux> <vmcore>` | dump 是什么时候抓的 |
| `sys` | 以命令形式打印 banner |
| `sym <name>` | 这个符号在哪个地址，来自哪里 |
| `mod` | 哪些模块加载过，crash 能不能给它们的符号 |

---

**版本。** 内核 `7be4bc52fd9e`（`7.3.0+` #16，x86_64，无 KASLR，DWARF5，
`UNWINDER_ORC=y`，`KALLSYMS_ALL=n`）；dump `vmcore`（kdump compressed v6，
`makedumpfile -l -d 31`）；`crash 9.0.3++`；QEMU 10.1.2。地址和 build ID 随构建
与运行变化。

下一篇：[搭一个能崩的内核](../02-the-lab/index.html) · 目录：[全部文章](../../index.html)
