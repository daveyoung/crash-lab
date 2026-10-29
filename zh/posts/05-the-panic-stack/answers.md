# 答案：panic 栈

## 1. 哪个 CPU，哪个任务

**CPU 1，任务 `bash`（PID 581）。**

最省事的命令是 `bt -p`，直接向 dump 要 panic 任务：

```
crash> bt -p
PID: 581      TASK: ffff88807db98000  CPU/NUMA:    1/0    COMMAND: "bash"
```

证据有三处，而且互相吻合：

- 帧头写着 `CPU/NUMA: 1/0` 与 `COMMAND: "bash"`；
- `set -p` 之后 `task` 打出 `STATE: TASK_RUNNING (PANIC)`；
- `log` 里的 oops 行写着 `CPU: 1 ... PID: 581 Comm: bash`。

如果 `bt -p` 不可用，`bt -a` 换条路也能给出同样的答案：只有栈里带 `page_fault_oops`/`oops_end` 的那个 CPU 接了这次缺页，CPU 1 上就是 PID 581。另外三个 CPU 是 idle 循环里的 `swapper/N`，栈是 crash 路径用 NMI 打出来的回溯。

## 2. 出错地址与指令

**出错地址是 0（`CR2`）。指令是 `crashlab_trigger_write.cold+63` 处的 `movl $0xdeadbeef,0x0`。**

两半各由一条命令证明：

```
crash> log -T | grep CR2
[...] CR2: 0000000000000000 [...]

crash> dis ffffffffa00000a2
0xffffffffa00000a2 <crashlab_trigger_write.cold+63>:	movl   $0xdeadbeef,0x0
```

`RIP` 来自异常帧（`bt -e` 里是 `RIP: ffffffffa00000a2`），指令内容是把 `0xdeadbeef` 写到绝对地址 0。`log` 里的 `#PF` 行还补了一句：这是一次**写**，目标是 not-present 页。

只引用 `CR2` 或只引用 `RIP`，描述都是不完整的：`CR2` 是指针当年指到的地址，`RIP` 是使用它的那条指令。这次两者指向同一个 bug，但它们是两件事。

## 3. 进程上下文还是中断上下文

**进程上下文。**

定案靠这几帧：

- 栈底的 `entry_SYSCALL_64_after_hwframe` 和 `CS: 0033`：任务是通过系统调用从用户态进来的，不是被中断打断的。
- `do_syscall_64` → `ksys_write` → `vfs_write` → `full_proxy_write`：一次 `write(2)` 的普通调用链，全程都在发起任务自己的上下文里。
- panic 任务是 `bash`，而 `bt -p`、`task` 和 oops 行里的 `Comm: bash` 三处说的是同一个任务。

中断上下文出错长得不一样：栈会从 `irqentry_*`、`asm_common_interrupt` 或者异常栈开始，`current` 只是"当时恰好在跑的那个任务"，不一定是代码出错的那个。故障下方存在用户态系统调用帧，是最有力的单个信号。
