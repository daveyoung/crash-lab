# 认识 crash：怎样调用crash

**一次 crash 调试会话需要用户准备两个文件：一个提供内存dump数据（vmcore），一个提供调试信息（vmlinux）。**

下面是同一份转储文件搭配两份不同 vmlinux 的测试示例。第一份直接报错，无法加载：

```
WARNING: could not find MAGIC_START!
crash: ~/crash-lab/build-shift/vmlinux and ~/crash-lab/vmcore do not match!
```

第二份仅输出一行警告，但可以正常打开、执行调试命令：

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

执行 `bt`、`sys` 命令输出看起来正常，Oops 信息也符合预期。但要注意：这份 namelist 并不是崩溃现场对应的内核，而是基于同一配置、重新编译得到的另一份 vmlinux。

第一份 vmlinux 的差异是在 `.config` 中开启了 `CONFIG_IKCONFIG=y`；第二份则使用和崩溃内核完全一致的 `.config`，在同一份干净源码目录下重新编译。。

![crash 的三个输入：vmlinux 提供符号与类型，vmcore 提供内存与 notes，模块 .ko 提供模块调试信息。下方是 vmcore 的 ELF 布局](assets/crash-inputs.svg)

## 三类输入参数，其中一类可选

使用 crash 打开转储文件，至少需要两份文件：

- **namelist**，也就是`vmlinux`。符号、结构体布局、枚举值、源码行号等信息，都来源于此。
- **内存镜像**，也就是 `vmcore`。寄存器现场、任务（task）结构、slab 页面、内核日志缓冲区等运行时内存数据，都保存在这里。

第三样输入是带调试信息的内核模块ko文件，一旦调用栈出现内核模块代码，它就至关重要：vmlinux 仅记录模块加载基地址和少量文本段符号，无法识别 `struct crashlab_dir` 这类自定义结构体，也无法定位 `crashlab.c` 中引发崩溃的具体代码行。该内容会在第 17 篇展开讲解。

另外还有**内核源码树**。如果源码路径和 DWARF 调试信息里记录的路径保持一致，`bt -l` 和 `--src` 参数就可以打印出对应的源码行。

重点区分：`bzImage`是压缩过的启动镜像，不是 namelist。如果用它替代vmlinux，crash会报错：

```
crash: ~/crash-lab/bzImage: not a supported file format
```

`System.map` 同样不等于 namelist，它只包含地址到符号名的映射：

```
crash: namelist argument required
```

它只有符号名称，缺少类型信息，因此无法解析 `struct task_struct` 这类结构体。

## vmcore 内部包含哪些内容

vmcore 分为两种格式　(kdump压缩格式和ELF原始格式)。

本文实验中的转储文件是 **kdump 压缩格式**：由 `makedumpfile` 对内存页面做过滤 + 压缩处理，不能直接交给 `readelf` 解析。通过 `file` 命令可以清晰识别：

```
vmcore: Kdump compressed dump v6, system Linux, node localhost.localdomain,
release 7.3.0+, version #16 SMP PREEMPT_DYNAMIC Mon Oct 26 14:48:51 CST 2026,
machine x86_64, domain (none)
```

另一种是 **ELF core 文件**，`makedumpfile -E` 和 QEMU monitor 的 `dump-guest-memory` 都可以生成。两类转储承载的信息一致，ELF 格式未做压缩，可直接用 `readelf` 解析。下面是通过 QEMU monitor 对同一虚拟机抓取的示例：

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

该文件包含 1 个 NOTE 段、7 个 LOAD 段。LOAD 段对应物理内存：第一段是 1MB 以内的内存空洞，第二段对应 VGA/BIOS 区域，其余段共同映射虚拟机 2GB 的物理内存。

其中 NOTE 段是调试的关键。执行 `readelf -n` 可以看到 4 个 `NT_PRSTATUS` 条目，每个条目对应一个 vCPU，保存了崩溃瞬间的寄存器上下文；`bt -a` 输出的全部 CPU 调用栈，就来源于这里。除此之外还有 `NT_PRPSINFO` 与辅助向量信息。

kdump 生成的转储，相比 QEMU monitor 转储多了一项关键数据：**`VMCOREINFO`**，由内核在崩溃时写入。crash 会从中读取内核版本、Build ID、页大小、`phys_base`，以及虚拟地址转译为转储文件偏移所需的各项参数。如果缺失该信息，crash 会直接报错：

```
crash: cannot read vmcoreinfo_data
      KERNEL: ~/crash-lab/linux/vmlinux
    DUMPFILE: [...]
       PANIC: ""
```

带来的后果很直观：无法定位发生 panic 的任务，调试会话默认落在 `swapper/0` 进程上。转储文件本身仍是一份完整内存快照，依然可用，但需要手动向 crash 补充内核信息，这就是 `--no_panic` 和 `--machdep` 参数的用途。

## banner信息: 一份核对清单

每次打开 crash 会话时，首页 banner 信息自上而下逐项校验：

- **`KERNEL`**：你给的 namelist，外加 `[TAINTED]`，因为内核装了树外模块。
- **`DUMPFILE`**：内存镜像，外加 `[PARTIAL DUMP]`，因为这次用 `makedumpfile -d 31` 过滤过。free、cache、cache-private、user 页都没写进去。
- **`CPUS`、`DATE`、`UPTIME`**：4 个 CPU、崩溃时间、以及 guest 只跑了三分五十八秒。
- **`LOAD AVERAGE`、`TASKS`、`NODENAME`**：0.72/0.21/0.07、94 个任务、`localhost.localdomain`。
- **`RELEASE` 与 `VERSION`**：`7.3.0+`、`#16 SMP PREEMPT_DYNAMIC Mon Oct 26 14:48:51 CST 2026`。
- **`MACHINE`**：`x86_64 (2693 Mhz)`。
- **`MEMORY`**：2 GB。
- **`PANIC`**：`"Oops: Oops: 0002 [#1] SMP" (check log for details)`，内核dmesg全文可用 `log` 命令查看。

## 快速校验文件匹配关系的常用命令

```sh
crash --osrelease <vmcore>     # dump 记录的 release 字符串
crash --build-id <vmcore>      # dump 记录的 build ID
crash -g <vmlinux>             # 这个 namelist 里有没有 DWARF
crash -t <vmlinux> <vmcore>    # dump 是什么时候抓的
```

在本实验的 dump 上执行效果：

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

前两条命令读取的是 vmcore 内的 `VMCOREINFO`，只能说明这份转储对应的内核信息，**不能用来验证 namelist 是否匹配**。而 namelist 的 Build ID 需要读取 ELF Note：

```sh
readelf -n ~/crash-lab/linux/vmlinux | grep -A1 'Build ID'
```

开篇几份 namelist 和转储的 Build ID 对照：

| 文件 | build ID | 版本串 |
| --- | --- | --- |
| 这份 dump | `6460abf3…` | `7.3.0+ #16 SMP PREEMPT_DYNAMIC Mon Oct 26 14:48:51 CST 2026` |
| 匹配的 `vmlinux` | `6460abf3…` | 同上 |
| 同配置重编 | `0a649fbb…` | `7.3.0+ #2 …` |
| 移位构建（`IKCONFIG=y`） | `5d2a2a5a…` | `7.3.0+ #1 …` |

## 内核模块

调用栈中出现 `[module]` 后缀，代表对应代码属于内核模块，相关记录保存在内核加载模块时维护的表中。本次实验内核关闭了 `CONFIG_KALLSYMS_ALL`，现象如下：

```
crash> sym crashlab_trigger_write.cold
ffffffffa00000bd (t) crashlab_trigger_write.cold [crashlab]

crash> sym crashlab_dir
symbol not found: crashlab_dir
possible alternatives:
  (none found)
```

函数属于文本段，符号可以正常解析；但模块全局变量 `crashlab_dir` 在数据段，因此无法找到：

```
     MODULE       NAME         TEXT_BASE       SIZE  OBJECT FILE
ffffffffa0201100  crashlab  ffffffffa0000000  12288  (not loaded)  [CONFIG_KALLSYMS]
```

这个模块确实已经加载、并且触发了崩溃，从地址 `0xffffffffa0201100` 读出的 `struct module` 状态为 `MODULE_STATE_LIVE`。这里的 `(not loaded)` 是 crash 的提示：缺少模块数据段符号，无法完成完整符号关联。

## 练习

1. 一份 `vmcore`搭配三个候选 `vmlinux`，哪个是对的？用哪两条命令证明？
2. 会话打开时只有 `WARNING: kernel version inconsistency between vmlinux and dumpfile`，后续所有调试命令输出看起来都正常，为什么这个会话依然不可信？在输出任何结论前，你会做哪些校验？
3. 类型信息由哪一份输入提供？内存内容由哪一份输入提供？如果只有 `System.map`，会缺失哪些能力？

答案与推理见 [`answers.md`](answers.md)。

## 本篇用到的命令

| 命令 | 回答什么问题 |
| --- | --- |
| `crash --version`、`crash --buildinfo` | 查看 crash 工具版本与编译信息 |
| `crash --osrelease <vmcore>` | 查询转储记录的内核版本 |
| `crash --build-id <vmcore>` | 查询转储记录的构建 ID |
| `crash -g <vmlinux>` | 检查 vmlinux 是否包含 DWARF 调试信息 |
| `crash -t <vmlinux> <vmcore>` | 获取转储捕获时间 |
| `sys` | 在命令行重新打印 banner 信息 |
| `sym <name>` | 查询指定符号的地址与归属 |
| `mod` | 查看已加载模块，以及 crash 是否可以解析模块符号 |

---

**版本。** 内核 `7be4bc52fd9e`（`7.3.0+` #16，x86_64，无 KASLR，DWARF5，
`UNWINDER_ORC=y`，`KALLSYMS_ALL=n`）；dump `vmcore`（kdump compressed v6，
`makedumpfile -l -d 31`）；`crash 9.0.3++`；QEMU 10.1.2。地址和 build ID 随构建
与运行变化。

下一篇：[搭一个能崩的内核](../02-the-lab/index.html) · 目录：[全部文章](../../index.html)
