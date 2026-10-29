# 答案：搭一个能崩的内核

## 1. 为什么 kexec 的 bzImage 必须与启动的那份一致

**答案：因为 crash 内核是你抓 dump 的环境，任何差异都是你没打算引入的变量。**

严格的要求落在**被崩的内核**上：dump 是它的内存，所以分析用的 `vmlinux` 必须是它的那次构建。`kexec -p` 加载的是 panic 之后启动的第二个内核，它负责暴露 `/proc/vmcore`、运行 `makedumpfile`，因此它需要 `CONFIG_PROC_VMCORE` 和写出 dump 所需的驱动。一个旧构建的镜像可能两样都缺。

还有一种更安静的失败：旧镜像**居然能用**，于是没有任何东西告诉你，你抓取的那台机器并不是你测试过的那台。实验室让两份镜像保持逐字节一致，用 `sha256sum` 核对，因为核对只要一条命令。

**相关陷阱：** `--reuse-cmdline` 是把 `crashkernel=256M` 带进 crash 内核的通道。复用出来的命令行里没有这笔预留，crash 内核就无处安身，kdump 根本起不来。

## 2. 让 struct task_struct 可用的配置

**答案：`CONFIG_DEBUG_INFO=y` 配上完整的 DWARF 变体（这里是 `CONFIG_DEBUG_INFO_DWARF5=y`），并且**不能**开 `CONFIG_DEBUG_INFO_REDUCED` 或 `CONFIG_DEBUG_INFO_SPLIT`。**

`CONFIG_DEBUG_INFO` 只表示"生成 DWARF"。真正悄悄坏事的是这两个：

- `DEBUG_INFO_REDUCED`：为了缩小镜像丢掉结构体成员等细节。`struct task_struct` 还在，但你要的成员可能不在，于是 `ps` 和所有顺着任务指针走的命令都不可靠。
- `DEBUG_INFO_SPLIT`：把类型放进对象文件旁边的 `.dwo`。单独的 `vmlinux` 就不含 `crash` 需要的类型，典型症状是会话能打开、一碰结构体就失败。

符号来自另一个选项 `CONFIG_KALLSYMS`：它给名字和地址，`KALLSYMS_ALL` 再扩展到数据符号。符号不是类型。

**本实验的验证：** `struct task_struct` 能完整打印，结尾是 `SIZE: 2624`，`ps -S` 走完 94 个任务。

## 3. --no_panic 改变了什么

**答案：它让 `crash` 不去找崩溃时正在运行的任务，直接把初始上下文设成 CPU 0 上的 `swapper`。**

这在 dump 里没有 panic 任务时才有意义：QEMU monitor 抓的运行中 guest、`panic_on_oops=0` 下根本没 panic 的 dump、或者 notes 没保住的 kdump。本实验的 monitor dump 里，`crash` 会自己说明并退回那里：

```
crash: cannot read vmcoreinfo_data
       PANIC: ""
```

**该用的场合：** 你知道没有 panic 上下文，又想要一个确定的起点，比如 `bt` 不带 `-a`、`files`、`vm` 这类依赖上下文的命令。

**不该用的场合：** 绝不要用它掩盖 namelist 不匹配或符号缺失导致的警告。它改变的是你从哪个任务开始，不是 namelist 对不对。

## 4. kexec 返回 0，机器却重启了

**答案：先查 crash 内核是否真的武装好，再查预留内存是否存在并被带了过去。**

1. **是"已武装"，不只是"加载成功"。** `kexec -p` 返回 0 与 `/sys/kernel/kexec_crash_loaded` 读到 `1` 是两件事：

   ```sh
   cat /sys/kernel/kexec_crash_loaded
   ```

   panic 之前不是 `1`，kdump 就不可能跑起来。第二个信号在 oops 头里：只有内核知道 crash 内核已武装时，才会出现 `Kdump: loaded`。

2. **有没有为它预留内存。** 预留来自命令行上的 `crashkernel=`，并要靠 `--reuse-cmdline` 带过去：

   ```sh
   grep -i crash /proc/iomem
   ```

   没有 `Crash kernel` 区间，crash 内核就无处安放，`kexec -p` 报什么都无关紧要。

两样都没问题，下一个怀疑对象是 oops 根本没有变成 panic（没有 `panic_on_oops=1`，或者内核从 oops 里恢复了过来），以及 crash 内核起来了但没写任何东西就死了。那篇故事在**第二次启动**的串口日志里，不在第一次。
