# 命令语言：上下文、输出与 foreach

**crash 的命令由命令名、选项和参数组成。参数位置可以放符号、地址、PID 或任务指针；输出可以接管道和重定向；`foreach` 把一条命令套到一批任务上。**

## 用管道过滤（diable scrollup）

```
crash> foreach bt | wc -l
1014
```

九十四个任务，一千多行。要找的是 PID 581：

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

## 命令、选项、参数

一行是 `命令 [选项] [参数]`。很多命令的参数位置既收符号也收地址：

```
crash> bt 581
crash> bt ffff88807db98000
```

两个请求等价。地址也能换回符号：

```
crash> sym ffffffffa0000063
ffffffffa0000063 (t) crashlab_trigger_write.cold [crashlab]
```

## 上下文

`set` 打印当前上下文：

```
crash> set
    PID: 581
COMMAND: "bash"
   TASK: ffff88807db98000  [THREAD_INFO: ffff88807db98000]
    CPU/NUMA:    1/0
  STATE: TASK_RUNNING (PANIC)
```

`set -p` 切到 panic 任务，`set -c 2` 切到 CPU 2：

```
crash> set -c 2
crash> bt
    PID: 0
COMMAND: "swapper/2"
   TASK: ffff88800294e200  (1 of 4)  [THREAD_INFO: ffff88800294e200]
    CPU/NUMA:    2/0
  STATE: TASK_RUNNING (ACTIVE)
```

上下文会保留，后面的 `bt`、`task`、`files` 都用它。`ps` 用 `>` 标出当前任务：

```
      PID    PPID  CPU/NUMA       TASK        ST  %MEM      VSZ      RSS  COMM
        1       0    3/0    ffff888002949c00  IN   0.7    25896    15300  systemd
>     581     516    1/0    ffff88807db98000  RU   0.3   234244     5492  bash
```

## 变量

`set -v` 打印全部变量，常用的是这几个：

```
        scroll: off (none)
[...]
         radix: 10 (decimal)
     print_max: 256
```

`radix` 控制 gdb 侧输出的进制：

```
crash> p jiffies
jiffies = $1 = 4294905494
crash> set radix 16
output radix: 16 (hex)
crash> p jiffies
jiffies = $2 = 0xffff0e96
```

## 输出

脚本里用 `-s --no_scroll` 关掉分页器，会话里用 `set scroll off`。输出可以接管道和重定向：

```
crash> log | grep -i crashlab
[   52.971995] CRASHLAB: null deref triggered by pid 581 (bash)
[   52.982059] RIP: 0010:crashlab_trigger_write.cold+0x3f/0x5d [crashlab]

crash> ps -S > ps-states.txt
crash> foreach UN bt >> un.txt
```

`>` 覆盖文件，`>>` 追加。用 `-s` 启动后 `set scroll on` 不生效。

## 输入

```sh
crash -s -i triage.crash vmlinux vmcore   # 执行命令文件
crash -s vmlinux vmcore < triage.crash    # 从标准输入
crash> ps -p < pids.txt                   # 每行一个参数
```

`-i` 读完文件就退出。文件末尾写 `exit`，否则返回码是 1。第三种适合批量查 PID：

```
crash> ps -p < pids.txt
PID: 0        TASK: ffffffff81a0a680  CPU/NUMA:    0/0    COMMAND: "swapper/0"
 PID: 1        TASK: ffff888002949c00  CPU/NUMA:    3/0    COMMAND: "systemd"
  PID: 516      TASK: ffff88807df78000  CPU/NUMA:    2/0    COMMAND: "login"
   PID: 581      TASK: ffff88807db98000  CPU/NUMA:    1/0    COMMAND: "bash"
```

## foreach 的选择器

选择器按位置给：

| 选择器 | 含义 |
| --- | --- |
| `pid` | 一个 PID |
| `taskp` | 一个 `task_struct` 地址 |
| `name` | 任务名，`'regex'` 表示正则 |
| `kernel` | 内核线程 |
| `user` | 用户线程 |
| `gleader` | 用户线程组长 |
| `active` | 每个 CPU 上正在跑的任务 |
| `state` | `RU IN UN ST ZO TR SW DE WA PA ID NE` 之一 |
| 空 | 所有任务 |

状态字母是 crash 自己的，和 `ps(1)` 不同。如 dump 的状态统计：

```
crash> ps -S
  RU: 5
  IN: 46
  ID: 43
```

所以 `foreach UN bt` 一行都不打，因为没有不可中断任务。几个实际用法：

```
crash> foreach kernel bt | head -12          # 内核线程
crash> foreach active bt                     # 每个 CPU 一个
crash> foreach systemd task -R __state       # 所有 systemd，只看一个成员
crash> foreach 'systemd|bash' ps             # 任务名正则
```

选项属于内层命令：`foreach 581 bt -r` 是对 PID 581 跑 `bt -r`。

## 别名、eval、ascii

```
crash> alias mytask task
ORIGIN   ALIAS    COMMAND
runtime  mytask   task
```

`eval` 做地址算术，一次列出各进制：

```
crash> eval (0xffffffff81000000 + 0x1000)
hexadecimal: ffffffff81001000  (18014398507401220KB)
    decimal: 18446744071578849280  (-2130702336)
      octal: 1777777777760100010000
     binary: 1111111111111111111111111111111110000001000000000001000000000000
```

`ascii` 把数值按字节还原：

```
crash> ascii 6c6c756e
000000006c6c756e: null<NUL><NUL><NUL><NUL>
```

`repeat` 一般用于live系统。

## `.crashrc`

`.crashrc` 可以作为crash的配置文件，首先从当前目录，其次从`$HOME`目录读取。
例如你可以设置 `set radix 10` 使crash report使用十进制。命令文件和命令行参数
有更高优先级可以覆盖.crashrc的配置。

## 把分诊写成文件

```
# triage.crash
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

`report.txt` 578 行，结构固定，只有地址随 dump 变化。

## 速查

| 想做的事 | 命令 |
| --- | --- |
| 执行命令文件 | `crash -s --no_scroll -i cmds vmlinux vmcore` |
| 从标准输入 | `crash -s vmlinux vmcore < cmds` |
| 每行一个参数 | `ps -p < pids.txt` |
| 关分页 | `-s --no_scroll`，或 `set scroll off` |
| 十进制输出 | `set radix 10` |
| 当前上下文 | `set` |
| panic 任务 | `set -p` |
| 某个 CPU | `set -c N` |
| 只看一个成员 | `task -R __state` |
| 过滤输出 | `log \| grep -i oops` |
| 保存 / 追加 | `> file`、`>> file` |
| 遍历任务 | `foreach [选择器] cmd` |
| 状态字母 | `RU IN UN ST ZO TR SW DE WA PA ID NE` |
| 给命令起名 | `alias mytask task` |
| 地址算术 | `eval (a + b)` |
| 字节转文本 | `ascii <hex>` |

---

**版本。** `crash 9.0.3++`（gdb 16.2）；内核 `7.3.0+`（x86_64，DWARF5，
`UNWINDER_ORC=y`，`KALLSYMS_ALL=n`）；dump `vmcore`，`makedumpfile -l -d 31`。
地址和 PID 来自某一次运行。

上一篇：[搭建环境](../02-the-lab/index.html) · 下一篇：[符号、类型与地址](../04-symbols-types-addresses/index.html) · 目录：[全部文章](../../index.html)
