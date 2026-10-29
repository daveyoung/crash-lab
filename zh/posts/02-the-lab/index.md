# 搭一个能崩的内核，也搭一个看得懂的 dump

**事后分析能走多远，取决于产出这份 dump 的内核。第一次崩之前，你需要三件事：带结构体布局的调试信息、能解析故障代码的符号、以及一个愿意把内存交给第二个内核的内核。之后，崩溃本身只是四条命令。**

本实验的第一次尝试只得到一行：

```
$ crash -s ~/crash-lab/linux/arch/x86/boot/bzImage ~/crash-lab/vmcore
crash: /home/you/crash-lab/linux/arch/x86/boot/bzImage: not a supported file format
```

机器启动要用 `bzImage`，`crash` 读的是 `vmlinux`。下面这套流程，先把这一个坑之外的都铺平。

文中路径缩写为 `~/crash-lab`。地址、构建号和大小都来自某一次具体构建，你的会不一样。

## 内核必须有什么

一个内核可以很健康，却完全没法做事后分析。关键的选项：

| 选项 | 值 | 作用 |
| --- | --- | --- |
| `CONFIG_DEBUG_INFO` | `y` | `crash` 读取类型的 DWARF 来源 |
| `CONFIG_DEBUG_INFO_DWARF5` | `y` | 现代默认；工具不认时退到 `DWARF4` |
| `CONFIG_DEBUG_INFO_REDUCED` | `n` | 精简 DWARF 会丢结构体成员，`ps`、`struct` 直接失效 |
| `CONFIG_DEBUG_INFO_SPLIT` | `n` | 类型被拆到 `.dwo`，`vmlinux` 里就没有了 |
| `CONFIG_KALLSYMS` | `y` | 符号表，含模块文本符号 |
| `CONFIG_KALLSYMS_ALL` | `n` | 数据符号；这里关着，代价看得见 |
| `CONFIG_UNWINDER_ORC` | `y` | 没有帧指针，`bt` 靠它 |
| `CONFIG_RANDOMIZE_BASE` | `n` | 无 KASLR，运行地址与文件一致 |
| `CONFIG_KEXEC`、`CONFIG_CRASH_DUMP`、`CONFIG_PROC_VMCORE` | `y` | kdump 通路 |
| `CONFIG_DEBUG_FS` | `y` | 模块的触发文件 |
| `CONFIG_MODULES` | `y` | `crashlab.ko` |

最容易看错的是 `REDUCED` 和 `SPLIT`：名字都像"调试信息"，实际不是。两个都必须关。一个能打印任务名却走不进 `task_struct` 的 `ps`，比明确失败更糟。

`KALLSYMS_ALL` 更有意思。关掉时函数符号照常解析，数据符号不行；本实验故意关着它，好让这个限制成为你看得见的东西，而不只是书上一句话。第 17 篇会回头处理它。

调试信息是真的，不是空壳：

```
$ readelf -S vmlinux | grep -E 'debug_info|debug_abbrev|debug_line'
  [41] .debug_info       PROGBITS         0000000000000000  011acac0
  [42] .debug_abbrev     PROGBITS         0000000000000000  077525b5
  [43] .debug_line       PROGBITS         0000000000000000  07abb198
```

## 编译

```sh
cd ~/crash-lab/linux
make -j"$(nproc)" bzImage modules
```

有三个产物，其中只有一个是 namelist：

| 文件 | 是什么 |
| --- | --- |
| `vmlinux` | 带 DWARF 的 ELF —— namelist |
| `arch/x86/boot/bzImage` | 压缩启动镜像 —— 机器启动用 |
| `System.map` | 文本：地址与名字，没有类型 |

构建会报出自己的身份，后面要用：

```
Kernel: arch/x86/boot/bzImage is ready  (#16)
```

`#16 SMP PREEMPT_DYNAMIC ...` 就是 crash banner 里那行版本串。它不是 build ID；两者为什么不能混用，第 1 篇讲过。

## 导出符号的坑

模块第一次链接失败：

```
ERROR: modpost: crashlab.ko: symbol 'debugfs_create_dir' undefined!
ERROR: modpost: crashlab.ko: symbol 'debugfs_create_file_full' undefined!
ERROR: modpost: crashlab.ko: symbol 'debugfs_remove' undefined!
ERROR: modpost: crashlab.ko: symbol 'strim' undefined!
ERROR: modpost: crashlab.ko: symbol 'sysfs_streq' undefined!
make[4]: *** [scripts/Makefile.modpost:147: Module.symvers] Error 1
```

符号明明在 `vmlinux` 里，所以这事看着奇怪，直到你意识到 `CONFIG_TRIM_UNUSED_KSYMS=y` 会把没有被树内模块使用的导出删掉。树内只有极少数 `=m` 时，几乎什么都留不下，树外模块自然解析不了。

两种解法：关掉裁剪，或者保留裁剪并显式列出例外。保留裁剪更合理——`vmlinux` 瘦身正是这个选项的意义——所以实验室里放一个白名单：

```
debugfs_create_dir
debugfs_create_file_full
debugfs_remove
strim
sysfs_streq
```

配置里指过去（这里不展开 `~`，要写绝对路径或相对内核树的路径）：

```
CONFIG_TRIM_UNUSED_KSYMS=y
CONFIG_UNUSED_KSYMS_WHITELIST="/home/you/crash-lab/ksym-whitelist.txt"
```

`make olddefconfig` 加重编之后，导出回来了：

```
$ nm vmlinux | grep __ksymtab_debugfs_create_dir
ffffffff819c71f4 r __ksymtab_debugfs_create_dir
```

白名单属于实验室，后续文章每加一个模式都可能要加一行。每加一次意味着重编和新的 dump。

## 编译模块

`crashlab.ko` 就是 [`crashlab/`](../../../crashlab/index.html) 里那个故意写坏的模块。它的 `null` 模式在 debugfs 的写路径上写地址 0，于是出故障的任务就是你的 shell，栈很短：

```c
if (sysfs_streq(buf, "null")) {
	volatile u32 *p = (volatile u32 *)0;

	pr_info("CRASHLAB: null deref triggered by pid %d (%s)\n",
		current->pid, current->comm);

	*p = 0xdeadbeef;
	return count;	/* not reached */
}
```

对着刚编好的树编译：

```sh
cd ~/crash-lab/crashlab
make KDIR=~/crash-lab/linux
```

在 `7.3.0+` 上第一次编译失败在一行：

```
crashlab.c:54:19: error: ‘no_llseek’ undeclared here (not in a function); did you mean ‘noop_llseek’?
   54 |         .llseek = no_llseek,
```

`no_llseek` 已经从内核里移除，模块改用 `noop_llseek`，这也是它唯一需要改的地方。产物是一个普通的外部模块：

```
$ modinfo crashlab.ko
author:         Crash Lab
description:    Crash Lab deliberately buggy test module
license:        GPL
name:           crashlab
vermagic:       7.3.0+ SMP preempt mod_unload
```

## 启动，拿到一个 shell

把编好的内核启动起来——虚拟机，或者一台你愿意弄坏的机器。记住你在哪个控制台拿到 shell，并确认 `debugfs` 挂上了：

```
# mount -t debugfs none /sys/kernel/debug
```

从这里开始都在 guest 里操作。它需要这个模块和同一份 `bzImage`；怎么放进去随你：共享目录、scp、initramfs、磁盘镜像都行。只有一条规则要注意，见下。

## 武装 crash 内核

命令行上的 `crashkernel=` 为第二个内核预留内存，`--reuse-cmdline` 把这笔预留带过去：

```
# grep -i crash /proc/iomem
  6a000000-79ffffff : Crash kernel

# kexec -p /path/to/bzImage --reuse-cmdline; echo "kexec rc=$?"
kexec rc=0

# cat /sys/kernel/kexec_crash_loaded
1
# cat /sys/kernel/kexec_crash_size
268435456
```

`kexec -p` 吃的是 `bzImage`，不是 `vmlinux`，而且必须是**当前运行的这次构建**。两者不一致时，crash 内核就是另一个内核，dump 会丢符号。核对一下：

```sh
sha256sum bzImage            # 机器启动用的那份
sha256sum /path/to/bzImage   # kexec 将加载的那份
```

每次都要看 `kexec_crash_loaded`。`kexec -p` 返回 0 和"crash 内核真的已经武装"是两件事，只有后者在 panic 之后救得了你。

## 故意死一次

内核里的空指针解引用默认只 oops，机器继续跑。这正是本实验不需要的，所以先让 oops 致命：

```
# echo 1 > /proc/sys/kernel/panic_on_oops
# insmod crashlab.ko
crashlab: loading out-of-tree module taints kernel.
CRASHLAB: loaded; write 'null' to /sys/kernel/debug/crashlab/trigger
```

然后触发：

```
# echo null > /sys/kernel/debug/crashlab/trigger
```

内核的遗言：

```
BUG: kernel NULL pointer dereference, address: 0000000000000000
#PF: supervisor write access in kernel mode
#PF: error_code(0x0002) - not-present page
PGD 0 P4D 0
Oops: Oops: 0002 [#1] SMP
CPU: 1 UID: 0 PID: 581 Comm: bash Kdump: loaded Tainted: G           O         7.3.0+ #16 PREEMPT(full)
Tainted: [O]=OOT_MODULE
```

要看的是 `Kdump: loaded`：这是内核在确认，它死的时候 crash 内核是武装好的。没有这行，机器只会重启，你什么都拿不到。

## kdump 启动与抓取

crash 内核带着一个额外参数启动，指向死掉的内核留下的状态：

```
Command line: elfcorehdr=0x6a000000 rw ... console=ttyS0 crashkernel=256M
```

并且它知道自己面对的是什么：

```
vmcore: dump is from kernel 7.3.0+
```

登录，然后把 dump 从 `/proc/vmcore` 写出来：

```
# makedumpfile -l -d 31 /proc/vmcore /root/vmcore
The kernel version is not supported.
The makedumpfile operation may be incomplete.
[... progress bars ...]

The dumpfile is saved to /root/vmcore.

makedumpfile Completed.
```

这段输出里藏着两个细节。

`The kernel version is not supported` 是 `makedumpfile 1.7.9++` 不认识 `7.3.0+`。dump 本身没问题——kdump 内核已经说了版本，`crash` 读它也不抱怨。这是版本表滞后，不用追。

`-d 31` 会过滤页类型：zero、cache、cache-private、user、free 都不写。所以每份 dump 都是 `[PARTIAL DUMP]`。栈、任务、slab、日志够用；需要用户页的时候换 `-d 17` 或更完整的级别，并记住第 1 篇说过的：部分 dump 能支撑什么。

把文件拿到跑 `crash` 的机器上。

## 打开它

配上匹配的 `vmlinux`：

```sh
crash -s --no_scroll ~/crash-lab/linux/vmlinux ~/crash-lab/vmcore
```

banner 见第 1 篇。冒烟测试才是这篇的重点：

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
    [...]
 #7 [ffffc90000e6be30] full_proxy_write at ffffffff8136ec89
 #8 [ffffc90000e6be68] vfs_write at ffffffff81250f1d
 #9 [ffffc90000e6bee8] ksys_write at ffffffff812513e6
#10 [ffffc90000e6bf18] do_syscall_64 at ffffffff816690c6
#11 [ffffc90000e6bf40] entry_SYSCALL_64_after_hwframe at ffffffff810000b0
```

```
crash> kmem -i
                 PAGES        TOTAL      PERCENTAGE
    TOTAL MEM   440931       1.7 GB         ----
         FREE   409488       1.6 GB   92% of TOTAL MEM
         USED    31443     122.8 MB    7% of TOTAL MEM
      BUFFERS        0            0    0% of TOTAL MEM
       CACHED    16567      64.7 MB    3% of TOTAL MEM
         SLAB     3365      13.1 MB    0% of TOTAL MEM
```

这些数字是从 `-d 31` 之后残余的页结构算出来的，不是机器真实的用量：一份启动过 systemd 的 guest 报 92% free 已经够可疑，同一份文件在 `crash 9.0.2` 上还报过 97%。部分 dump 上的 `kmem -i` 看形状就好，别当账本；`kmem -s` 列的是 slab 缓存和对象数，是另一个问题。

ORC 展开、没有帧指针，栈是完整的，这对第 6 篇很重要；模块那一帧有符号，虽然模块的数据符号没有。`-s` 让输出可脚本化：不加它，分页器会停下来等你。

## QEMU monitor 兜底

kdump 会失败：没武装、没预留、crash 内核自己也崩。在 QEMU 里总有另一条路，而且值得知道它给的是什么：

```
(qemu) stop
(qemu) dump-guest-memory /path/vmcore.elf
warning: guest note is not present
(qemu) cont
```

`warning: guest note is not present` 是这句命令诚实的部分。这份 dump 有 `NOTE` 和 `LOAD` 段、有每个 CPU 的寄存器，但没有 `VMCOREINFO`，因为活着的 guest 没写过它。`crash` 打开后会说：

```
crash: cannot read vmcoreinfo_data
       PANIC: ""
```

没有 panic 任务，没有 panic 字符串，得到的是一台运行中机器的快照，而不是一台正在死的机器。有用，但严格少于 kdump。要这么抓就先停住 guest，否则页是不一致的。

## KASLR，简单说

本实验的 `CONFIG_RANDOMIZE_BASE` 是关的，`vmlinux` 里的地址就是 dump 里的地址，不需要碰 `--kaslr`。如果某份 dump 开了 KASLR，加载偏移就在 notes 里，`crash` 用 `--kaslr auto` 自己找；notes 丢了的 dump 需要从 panic 日志的 `Kernel Offset:` 里取 `--kaslr <offset>`。KASLR 开着时，你读到的每个地址都是相对基址的，第一件事是确认 `crash` 找到了偏移。

## 配置不够时会怎样

本实验有意的取舍，遇到时知道往哪改：

- `CONFIG_KALLSYMS_ALL=n`：模块数据符号解析不了，模块里只能看到文本符号。第 4 篇用手工地址绕过，第 17 篇正面处理。
- `CONFIG_SLUB_DEBUG=n`：`kmem -s` 会直接拒绝（`kmem: option requires kmem_cache_node.nr_slabs member!`）。要看 slab 细节就得重编。
- `CONFIG_RUST=n`：`rustfilt` 没有可反解的名字，命令形式仍然可用，只是这份 dump 里没东西可试。

规律是一样的：某条命令报出它需要的 `CONFIG_` 选项，那就是重编清单，加上、重编、重抓。

## 易错点

- `bzImage` 不是 namelist，构建目录的 `vmlinux` 才是。
- `CONFIG_TRIM_UNUSED_KSYMS` 会悄悄撤掉模块需要的导出，白名单要跟实验室一起存。
- `DEBUG_INFO_REDUCED` 和 `DEBUG_INFO_SPLIT` 编出来的内核能启动、不能好好调试。
- 配置改过之后重编，即使 release 相同，也是另一个 namelist。
- 机器启动的 `bzImage` 和 `kexec -p` 加载的必须逐字节一致。
- 先 `kexec -p` 再崩溃，之后核对 `/sys/kernel/kexec_crash_loaded`。
- 普通空指针只 oops；没有 `panic_on_oops=1`，guest 活下来，kdump 永远不会启动。
- `--reuse-cmdline` 必须带上 `crashkernel=256M`，没有预留就没有地方放 crash 内核。
- `makedumpfile -d 31` 丢用户页和页缓存，级别要按你打算问的问题选。
- `makedumpfile` 对新内核报版本警告是表面问题，kdump 启动日志才是 dump 有效与否的权威。
- 如果 `make defconfig` 报 `gcc: unknown assembler invoked`，先看编译器包装器：写不了缓存目录的 ccache 就会产出这句。

## 练习

1. 为什么 `kexec -p` 加载的 `bzImage` 必须和机器启动的那份一致？
2. 哪些配置让 `struct task_struct` 在 `crash` 里可用，尽管内核"有调试信息"？
3. `--no_panic` 改变了什么，什么时候该用？
4. `kexec -p` 返回 0，你崩了机器，结果它重启而不是进入 kdump。先查哪两件事？

答案与推理见 [`answers.md`](answers.md)。

## 本篇用到的命令

| 位置 | 命令 | 证明什么 |
| --- | --- | --- |
| 构建 | `make -j"$(nproc)" bzImage modules` | 产物存在且与配置一致 |
| 构建 | `modinfo crashlab.ko` | vermagic 与内核匹配 |
| 宿主 | 两份 `bzImage` 各跑 `sha256sum` | 启动镜像与 kexec 镜像是同一次构建 |
| guest | `insmod`、`echo 1 > /proc/sys/kernel/panic_on_oops` | 触发器已就位且会导致 panic |
| guest | `kexec -p`、`cat /sys/kernel/kexec_crash_loaded` | crash 内核真的武装好了 |
| guest | `echo null > /sys/kernel/debug/crashlab/trigger` | oops |
| kdump | `makedumpfile -l -d 31 /proc/vmcore /root/vmcore` | 过滤后的 dump |
| 宿主 | `crash -s vmlinux vmcore` | 会话 |
| 宿主 | monitor `dump-guest-memory` | 不走 kdump 的兜底 dump |

---

**版本。** 内核 `7.3.0+`（x86_64，无 KASLR，DWARF5，`UNWINDER_ORC=y`，
`KALLSYMS_ALL=n`）；`crash 9.0.3++`；`makedumpfile 1.7.9++`；QEMU 10.1.2；
GCC 15.2.1。地址与构建号随构建和运行变化。

上一篇：[认识 crash](../01-what-crash-is/index.html) · 下一篇：[命令语言](../03-the-command-language/index.html) · 目录：[全部文章](../../index.html)
