# 命令语言

**crash 不是一堆命令的集合，它更像一门小语言。会用它管上下文、管输出、管循环，六七条命令就能回答原本要翻一百条命令才能回答的问题。**

先看最容易想到的做法：

```
crash> foreach bt | wc -l
1014
```

一千零一十四行，九十四个任务，真正要看的那个 `bash` 埋在中间。翻页不是办法，过滤才是：

```
crash> foreach 581 bt
PID: 581      TASK: ffff88807db98000  CPU/NUMA:    1/0    COMMAND: "bash"
 #0 [ffffc90000e6bb98] machine_kexec at ffffffff810e5a8d
 #1 [ffffc90000e6bba8] __crash_kexec at ffffffff81191acc
 #2 [ffffc90000e6bc60] crash_kexec at ffffffff81191ffb
 #3 [ffffc90000e6bc70] oops_end at ffffffff810c4973
 #4 [ffffc90000e6bc90] page_fault_oops at ffffffff810ecdc7
 #5 [ffffc90000e6bd10] exc_page_fault at ffffffff8166d18c
 #6 [ffffc90000e6bd60] asm_exc_page_fault at ffffffff810011b6
    [exception RIP: crashlab_trigger_write.cold+63]
```

输出里没有新东西。新的是知道了 `foreach` 可以带选择器，而选择器可以是 PID、任务指针、名字或者状态。

## 语法其实很小

一行就是 `命令 [选项] [参数]`。真正讲究的是参数：很多命令的同一个位置，既能放符号，也能放十六进制地址、PID 或 `task_struct` 指针。

```
crash> bt 581
crash> bt ffff88807db98000
```

这两个请求等价。下面这个也一样：

```
crash> sym ffffffffa0000063
ffffffffa0000063 (t) crashlab_trigger_write.cold [crashlab]
```

异常帧里的地址，一条命令就还原成了符号。第 4 篇专门讲这件事，这里只要记住：参数位置不挑食。

## 上下文是一种状态

不带参数的 `set` 打印你当前站在哪儿：

```
crash> set
    PID: 581
COMMAND: "bash"
   TASK: ffff88807db98000  [THREAD_INFO: ffff88807db98000]
    CPU/NUMA:    1/0
  STATE: TASK_RUNNING (PANIC)
```

这是 panic 任务，因为 `crash` 从 dump 里把它挑出来了。panic 任务也会丢，丢的时候用这条找回来：

```
crash> set -p
```

也可以把上下文钉在某个 CPU 上：

```
crash> set -c 2
crash> bt
    PID: 0
COMMAND: "swapper/2"
   TASK: ffff88800294e200  (1 of 4)  [THREAD_INFO: ffff88800294e200]
    CPU/NUMA:    2/0
  STATE: TASK_RUNNING (ACTIVE)
```

上下文是会留存的。后面的 `bt`、`files`、`vm`、`task` 都会默默沿用 `set` 留下的状态。写命令文件时这很方便，交互式敲了一长串之后就很危险。`ps` 会用 `>` 标出当前任务，随时可以核一下：

```
      PID    PPID  CPU/NUMA       TASK        ST  %MEM      VSZ      RSS  COMM
        1       0    3/0    ffff888002949c00  IN   0.7    25896    15300  systemd
>     581     516    1/0    ffff88807db98000  RU   0.3   234244     5492  bash
```

## 几个值得设的变量

`set -v` 会把变量表整个打出来。和 dump 有关的是这几个：

```
        scroll: off (none)
[...]
         radix: 10 (decimal)
     print_max: 256
   print_array: off
        silent: on
        unwind: off
[...]
```

这段取自一次 `-s` 运行，所以滚动关着、`silent` 是 on；交互式会话里这里会是 `scroll: on (/usr/bin/less)`。

`radix` 决定 gdb 那侧输出按什么进制打。同一个符号：

```
crash> p jiffies
jiffies = $1 = 4294905494
crash> set radix 16
output radix: 16 (hex)
crash> p jiffies
jiffies = $2 = 0xffff0e96
```

这里默认是十进制，别的地方不一定。`print_max` 和 `print_array` 管数组打多少、打不打全。只看一次的 dump，默认值够用；要拿两次报告做 diff，这些就是可复现性的一部分。

## 输出：分页器、管道、文件

默认情况下 `crash` 把输出送给 `less`。放进脚本就是等着挂住，所以常规调用都带 `-s`（`--silent`）和 `--no_scroll`，会话里则用 `set scroll off`。

管道和重定向就是 shell 语法，对 crash 输出同样有效：

```
crash> log | grep -i crashlab
[   52.971995] CRASHLAB: null deref triggered by pid 581 (bash)
[   52.982059] RIP: 0010:crashlab_trigger_write.cold+0x3f/0x5d [crashlab]
[   53.016379] Modules linked in: crashlab(O)

crash> ps -S > ps-states.txt        # 覆盖
crash> foreach UN bt >> un.txt      # 追加
```

有一个坑，是这次实验真花时间踩出来的：当前版本的 `crash`，在 `-i` 命令文件里跑**带管道**的 `log`，会把头部打坏。文件如果是

```
sys
log -T | tail -n 3
exit
```

`PANIC:` 那一行会变成 log 的尾巴，真正的 panic 字符串被挤到整个输出的最后：

```
       PANIC: [Mon Oct 26 18:55:16 CST 2026]  </TASK>
[Mon Oct 26 18:55:16 CST 2026] Modules linked in: crashlab(O)
[Mon Oct 26 18:55:16 CST 2026] CR2: 0000000000000000
[...]
"Oops: Oops: 0002 [#1] SMP" (check log for details)
```

同样的命令从 stdin 喂进去没事，`log -T` 不带管道也没事。修好之前，命令文件里把 `log` 放在 `sys` 前面，或者干脆别加管道。

## 输入：三种喂法

```sh
crash -s -i triage.crash vmlinux vmcore   # 命令文件
crash -s vmlinux vmcore < triage.crash    # 标准输入
crash> ps -p < pidlist                    # 单个命令的逐行参数
```

`-i` 读完文件就执行，遇到文件末尾退出。不过还是把 `exit` 写上：不写也能结束，但 `crash` 的返回码是 1，外面包一层脚本就会记成失败。

第三种最容易被忽略。一个每行一个 PID 的文件，就是参数列表：

```
crash> ps -p < pids.txt
PID: 0        TASK: ffffffff81a0a680  CPU/NUMA:    0/0    COMMAND: "swapper/0"
 PID: 1        TASK: ffff888002949c00  CPU/NUMA:    3/0    COMMAND: "systemd"
  PID: 516      TASK: ffff88807df78000  CPU/NUMA:    2/0    COMMAND: "login"
   PID: 581      TASK: ffff88807db98000  CPU/NUMA:    1/0    COMMAND: "bash"
```

## foreach 就是那个循环

`foreach` 对一批任务跑一条命令。选择器按位置给：

| 选择器 | 含义 |
| --- | --- |
| `pid` | 一个 PID |
| `taskp` | 一个 `task_struct` 地址 |
| `name` | 任务名；`'regex'` 写正则 |
| `kernel` | 只看内核线程 |
| `user` | 只看用户线程 |
| `gleader` | 用户线程的组长 |
| `active` | 每个 CPU 上正在跑的任务 |
| `state` | `RU IN UN ST ZO TR SW DE WA PA ID NE` 之一 |
| 不给 | 所有任务 |

状态字母是 crash 自己的一套，和 `ps(1)` 对不上。这份 dump 里是这样的：

```
crash> ps -S
  RU: 5
  IN: 46
  ID: 43
```

于是 `foreach UN bt`——"谁卡在 D 状态"这个经典问题——一行都不打，因为这份崩溃里没有不可中断任务。这不是命令坏了，这就是答案。同样的选择器放到一次文件系统挂死的现场，画面完全不同。

几个实际用法：

```
crash> foreach kernel bt | head -12          # 只看内核线程
crash> foreach active bt                     # 每个 CPU 一个
crash> foreach systemd task -R __state       # 所有 systemd，只看一个成员
crash> foreach 'systemd|bash' ps             # 按任务名正则
```

`foreach` 把余下的内容原样交给内层命令，选项也算内层的：

```
crash> foreach 581 bt -r
```

意思是"对 PID 581 跑 `bt -r`"，不是"用 `foreach` 的 `-r` 跑 `bt`"。任务名和选择器重名时，加反斜杠转义（`\kernel`）。

## 别名、算术、ASCII

会话开得久，就把反复敲的命令起个名：

```
crash> alias mytask task
ORIGIN   ALIAS    COMMAND
runtime  mytask   task
```

`eval` 做地址算术，一次把所有进制列全。拿到一个偏移、想知道它属于哪个符号时很好用：

```
crash> eval (0xffffffff81000000 + 0x1000)
hexadecimal: ffffffff81001000  (18014398507401220KB)
    decimal: 18446744071578849280  (-2130702336)
      octal: 1777777777760100010000
     binary: 1111111111111111111111111111111110000001000000000001000000000000

crash> eval -b 0x800
hexadecimal: 800  (2KB)
[...]
   bits set: 11

crash> eval 2g
hexadecimal: 80000000  (2GB)
```

`ascii` 把一个数按字节还原，小端序，正好是寄存器或内存里某个字看着像文本时要的：

```
crash> ascii 6c6c756e
000000006c6c756e: null<NUL><NUL><NUL><NUL>
```

这就是模块里拿来比较的那个字符串，在内存里的四个字节。

`repeat` 反而是要避开的那个。文档说它是给活系统用的，在 dump 上它不会正常收尾：`repeat -1 bt` 打一条栈之后就卡住，不杀掉不回来；`repeat -1 ps -S` 一行都不打就卡住。真需要循环，用 shell 写；这里没有活的东西可盯。

## 把命令写成文件

上面这些，最后都是为了把一次分诊变成"一个文件加一行命令"。第一版故意很短：

```
# triage.crash - first pass over an unknown dump
set scroll off
sys
bt -a
ps -S
log -T
kmem -i
mod
exit
```

```sh
crash -s --no_scroll -i triage.crash ~/crash-lab/linux/vmlinux ~/crash-lab/vmcore > report.txt
```

`report.txt` 578 行，每一行都能复现：同样的输入文件、同一个 `vmlinux`，结构一致，只有地址会变。这就是"我看过一份 dump"和"这是我跑的分诊"之间的差别。第 19 篇会把这份文件长成报告，形状不变。

## 易错点

- `>` 覆盖，`>>` 追加。用错一个，昨天的证据就没了。
- 分页器会在脚本里吞输出。`-s` 和 `--no_scroll`，或者在文件里 `set scroll off`。
- 用 `-s` 启动之后，`set scroll on` 是无效的；它会回一句 `scroll: off (none)`，这次会话里也打不开了。
- 上下文会留存。三条命令之前的 `set -c` 可能正在悄悄改变此刻 `bt` 的含义。
- `foreach` 按位置解析，选项属于内层命令。
- 状态字母是 crash 自己的（`UN`、`DE`、`ID`），别当成 `ps(1)` 的字母。
- `-i` 文件末尾不写 `exit`，返回码是 1。
- 当前版本里，`-i` 中 `sys` 之后接带管道的 `log` 会打坏 `PANIC:` 行。修好之前别用管道。
- `!` 跑 shell 命令，单独一个 `!` 进 shell。别喂不可信输入。
- `repeat` 在 dump 上不能用，会卡住。
- 当前目录或 `$HOME` 下的 `.crashrc` 会悄悄改 `set` 变量；命令文件才是可复现的那一层。

## 练习

1. 把所有可中断任务的栈写进 `in.txt`，再把空闲任务的栈追加进去。两个选择器各命中多少？`UN` 为什么不在其中？
2. 不知道 PID，把上下文切到 panic 任务，再打出它的命令名和状态。哪条命令能证明你没选错？
3. 把三条命令的分诊变成 `crash -i triage.crash`，不要分页器，退出码为 0。末尾必须写什么？忘了会怎样？

答案见 [`answers.md`](answers.md)。

## 速查

| 想做的事 | 命令 |
| --- | --- |
| 跑一个命令文件 | `crash -s --no_scroll -i cmds vmlinux vmcore` |
| 从标准输入 | `crash -s vmlinux vmcore < cmds` |
| 逐行参数 | `ps -p < pids.txt` |
| 关分页 | `-s --no_scroll`，或 `set scroll off` |
| 十进制输出 | `set radix 10` |
| 当前上下文 | `set` |
| panic 任务 | `set -p` |
| 某个 CPU | `set -c N` |
| 只看一个成员 | `task -R __state` |
| 过滤命令输出 | `log \| grep -i oops` |
| 保存 / 追加 | `> file`、`>> file` |
| 遍历任务 | `foreach [选择器] cmd` |
| 状态字母 | `RU IN UN ST ZO TR SW DE WA PA ID NE` |
| 给命令起名 | `alias mytask task` |
| 地址算术 | `eval (a + b)` |
| 字节转文本 | `ascii <hex>` |
| 退出 | `exit`（写文件时别忘） |

---

**版本。** `crash 9.0.3++`（gdb 16.2）；内核 `7.3.0+`（x86_64，DWARF5，
`UNWINDER_ORC=y`，`KALLSYMS_ALL=n`）；dump `vmcore`，`makedumpfile -l -d 31`
（kdump compressed v6，`[PARTIAL DUMP]`）。地址和 PID 来自某一次运行。

上一篇：[搭一个能崩的内核](../02-the-lab/) · 下一篇：[符号、类型与地址](../04-symbols-types-addresses/)
