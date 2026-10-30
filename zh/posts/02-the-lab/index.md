# 编译内核，生成vmcore

**编译内核：编译一个带结构体布局的调试信息、能解析故障代码的符号、以及支持crashdump的内核。**

## 内核必须有什么

关键的选项：

| 选项 | 值 | 作用 |
| --- | --- | --- |
| `CONFIG_DEBUG_INFO` | `y` | `crash` 读取类型的 DWARF 来源 |
| `CONFIG_DEBUG_INFO_DWARF5` | `y` | 默认格式 |
| `CONFIG_DEBUG_INFO_REDUCED` | `n` | 精简 DWARF 会丢结构体成员，crash目前还不支持 |
| `CONFIG_DEBUG_INFO_SPLIT` | `n` | crash目前还不支持  |
| `CONFIG_KALLSYMS` | `y` | 符号表，含模块文本符号 |
| `CONFIG_KALLSYMS_ALL` | `n` | 数据符号；建议打开，笔者实验中是关闭的 |
| `CONFIG_UNWINDER_ORC` | `y` | 没有帧指针，`bt` 靠它 |
| `CONFIG_RANDOMIZE_BASE` | `n` | 无 KASLR，运行地址与文件一致 |
| `CONFIG_KEXEC`、`CONFIG_CRASH_DUMP`、`CONFIG_PROC_VMCORE` | `y` | kdump 需要的config选项 |
| `CONFIG_DEBUG_FS` | `y` | 模块的触发文件 |
| `CONFIG_MODULES` | `y` | `crashlab.ko` |

最容易看错的是 `REDUCED` 和 `SPLIT`：名字都像"调试信息"，实际不是。两个都必须关。

`KALLSYMS_ALL` 关掉时函数符号照常解析，数据符号不行；第 17 篇会回头处理它。

用readelf读取elf信息：

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

编译出的文件：

| 文件 | 是什么 |
| --- | --- |
| `vmlinux` | 带 DWARF 的 ELF —— namelist |
| `arch/x86/boot/bzImage` | 压缩启动镜像 —— 机器启动用 |
| `System.map` | 文本：地址与名字，没有类型 |

编译信息，后面要用：

```
Kernel: arch/x86/boot/bzImage is ready  (#16)
```

`#16 SMP PREEMPT_DYNAMIC ...` 就是 crash banner 里那行版本串。

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

符号明明在 `vmlinux` 里，所以这事看着奇怪，事实上 `CONFIG_TRIM_UNUSED_KSYMS=y` 会把没有被树内模块使用的导出删掉。树内只有极少数 `=m` 时，几乎什么都留不下，树外模块自然解析不了。

两种解决方法：关掉CONFIG_TRIM_UNUSED_KSYMS，或者显式列出例外。本实验采用一个白名单：

```
debugfs_create_dir
debugfs_create_file_full
debugfs_remove
strim
sysfs_streq
```

配置：

```
CONFIG_TRIM_UNUSED_KSYMS=y
CONFIG_UNUSED_KSYMS_WHITELIST="/home/you/crash-lab/ksym-whitelist.txt"
```

`make olddefconfig` 加重编之后，导出回来了：

```
$ nm vmlinux | grep __ksymtab_debugfs_create_dir
ffffffff819c71f4 r __ksymtab_debugfs_create_dir
```

后续文章每加一个模式都可能要加一行白名单。每加一次意味着重编和新的 dump。

## 编译模块

`crashlab.ko` 就是 [`crashlab/`](../../../crashlab/index.html) 里那个模块。它的 `null` 模式在 debugfs 写地址 0：

```c
if (sysfs_streq(buf, "null")) {
	volatile u32 *p = (volatile u32 *)0;

	pr_info("CRASHLAB: null deref triggered by pid %d (%s)\n",
		current->pid, current->comm);

	*p = 0xdeadbeef;
	return count;	/* not reached */
}
```

编译：

```sh
cd ~/crash-lab/crashlab
make KDIR=~/crash-lab/linux
```

```
$ modinfo crashlab.ko
author:         Crash Lab
description:    Crash Lab deliberately buggy test module
license:        GPL
name:           crashlab
vermagic:       7.3.0+ SMP preempt mod_unload
```

## 启动

把编好的内核在虚拟机中启动起来并确认 `debugfs` 挂上，确认用`crashkernel=` 为第二个内核预留内存：

```
# mount -t debugfs none /sys/kernel/debug
```

## crash -> dump

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
## 触发panic

内核里的空指针解引用默认只 oops，机器继续跑。这正是本实验不需要的，所以先使能panic_on_oops：

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

内核的输出：

```
BUG: kernel NULL pointer dereference, address: 0000000000000000
#PF: supervisor write access in kernel mode
#PF: error_code(0x0002) - not-present page
PGD 0 P4D 0
Oops: Oops: 0002 [#1] SMP
CPU: 1 UID: 0 PID: 581 Comm: bash Kdump: loaded Tainted: G           O         7.3.0+ #16 PREEMPT(full)
Tainted: [O]=OOT_MODULE
```

## kdump 启动与抓取

crash 内核启动：

```
Command line: elfcorehdr=0x6a000000 rw ... console=ttyS0
...
vmcore: dump is from kernel 7.3.0+
```

把 dump 从 `/proc/vmcore` 写出来：

```
# makedumpfile -l -d 31 /proc/vmcore /root/vmcore
The kernel version is not supported.
The makedumpfile operation may be incomplete.
[... progress bars ...]

The dumpfile is saved to /root/vmcore.

makedumpfile Completed.
```

`-d 31` 会过滤页类型：zero、cache、cache-private、user、free 都不写。所以每份 dump 都是 `[PARTIAL DUMP]`。栈、任务、slab、日志够用；需要用户页的时候换 `-d 17` 或更完整的级别，并记住第 1 篇说过的：部分 dump 能支撑什么。

把文件Copy到跑 `crash` 的机器上。

## 打开它

配上匹配的 `vmlinux`：

```sh
crash -s --no_scroll ~/crash-lab/linux/vmlinux ~/crash-lab/vmcore
```

冒烟测试：

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

## QEMU monitor 生成dump

```
(qemu) stop
(qemu) dump-guest-memory /path/vmcore.elf
warning: guest note is not present
(qemu) cont
```

`warning: guest note is not present` 这份 dump 有 `NOTE` 和 `LOAD` 段、有每个 CPU 的寄存器，但没有 `VMCOREINFO`，因为 guest 没写过它。`crash` 打开后会报：

```
crash: cannot read vmcoreinfo_data
       PANIC: ""
```

没有 panic 任务，没有 panic 字符串，得到的是一台运行中机器的快照，而不是一台正在死的机器。

## KASLR，简单说

本实验的 `CONFIG_RANDOMIZE_BASE` 是关的，`vmlinux` 里的地址就是 dump 里的地址，不需要碰 `--kaslr`。KASLR 开着时，你读到的每个地址都是相对基址的，第一件事是确认 `crash` 找到了kaslr偏移。

## 配置不够时会怎样

本实验未开的几个CONFIG：

- `CONFIG_KALLSYMS_ALL=n`：模块数据符号解析不了，模块里只能看到文本符号。
- `CONFIG_SLUB_DEBUG=n`：`kmem -s` 会直接拒绝（`kmem: option requires kmem_cache_node.nr_slabs member!`）。要看 slab 细节就得重编。
- `CONFIG_RUST=n`：`rustfilt` 没有可反解的名字，目前没有用到。

## 练习

1. 为什么 `kexec -p` 加载的 `bzImage` 必须和机器启动的那份一致？
2. 哪些配置让 `struct task_struct` 在 `crash` 里可用？
3. `--no_panic` 改变了什么，什么时候该用？
4. `kexec -p` 返回 0，你崩了机器，结果它重启而不是进入 kdump。先查哪两件事？

答案见 [`answers.md`](answers.md)。

## 本篇用到的命令

| 位置 | 命令 | 证明什么 |
| --- | --- | --- |
| 编译 | `make -j"$(nproc)" bzImage modules` 
| 编译 | `modinfo crashlab.ko` 
| guest | `insmod`、`echo 1 > /proc/sys/kernel/panic_on_oops` 
| guest | `kexec -p`、`cat /sys/kernel/kexec_crash_loaded`
| guest | `echo null > /sys/kernel/debug/crashlab/trigger`
| kdump | `makedumpfile -l -d 31 /proc/vmcore /root/vmcore`
| host | `crash -s vmlinux vmcore` 
| host | monitor `dump-guest-memory` 

---



上一篇：[认识 crash](../01-what-crash-is/index.html) · 下一篇：[命令语言](../03-the-command-language/index.html) · 目录：[全部文章](../../index.html)
