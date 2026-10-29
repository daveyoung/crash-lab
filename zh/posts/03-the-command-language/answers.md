# 答案：命令语言

## 1. 可中断任务与空闲任务写进同一个文件

```crash
foreach IN bt > in.txt
foreach ID bt >> id.txt
```

**这份 dump 的命中数：** 46 个可中断任务，43 个空闲任务。动手之前 `ps -S` 就会告诉你：

```
crash> ps -S
  RU: 5
  IN: 46
  ID: 43
```

**`UN` 为什么不在其中：** 这些字母是崩溃那一刻的任务状态，而这台机器死的时候没有处于 `TASK_UNINTERRUPTIBLE`（也就是 `ps(1)` 里的 `D`）的任务。文件系统或驱动卡死时，`UN` 就是该抓的字母，第 7 篇会用到；但在本 dump 上它什么也选不中，空文件就是正确答案，不是命令坏了。

**第二条为什么用 `>>`：** `>` 会截断。两次都用 `>`，`in.txt` 里只剩空闲任务——这个练习就是让你记住这一点。

**输出长这样：** 每个任务一截头部加自己的栈：

```
PID: 1        TASK: ffff888002949c00  CPU/NUMA:    3/0    COMMAND: "systemd"
 #0 [ffffc900000b3d48] __schedule at ffffffff816708b8
 ...
```

## 2. 不知道 PID，切到 panic 任务

```crash
set -p
task
```

能证明你选对的是 `task` 打出来的状态，它把所有睡眠任务和这个任务区分开：

```
    PID: 581
COMMAND: "bash"
   TASK: ffff88807db98000  [THREAD_INFO: ffff88807db98000]
    CPU/NUMA:    1/0
  STATE: TASK_RUNNING (PANIC)
```

`(PANIC)` 是 `crash` 在说：它选的是内核死时正在跑的任务，不是猜的。dump 里根本没有 panic 任务时——比如 QEMU monitor 抓的——`set -p` 变不出一个来，诚实的做法是启动时用 `--no_panic`，落在 `swapper/0` 上。

想看得更窄，用 `task -R __state`：

```
crash> task -R __state
PID: 581      TASK: ffff88807db98000  CPU/NUMA:    1/0    COMMAND: "bash"
  __state = 0,
```

`__state = 0` 就是 `TASK_RUNNING`，和"panic 任务正在 CPU 上跑"对得上。注意成员名：这个内核叫 `__state`，不叫 `state`，所以 `task -R state` 会失败，报错本身就是提示。

## 3. 能干净退出的命令文件

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
echo $?
```

**末尾必须写：** `exit`。

**忘了会怎样：** 文件读完 `crash` 一样会退出，不会挂住——但返回码是 **1**，外面任何检查 `$?` 的包装脚本都会把这次分诊记成失败。这比挂住更糟，因为它不吭声：

```
$ crash -s --no_scroll -i noexit.crash vmlinux vmcore > /dev/null; echo $?
1
$ crash -s --no_scroll -i triage.crash vmlinux vmcore > /dev/null; echo $?
0
```

**为什么要 `-s --no_scroll`：** 不加它们，分页器可能在非交互运行里把输出吞掉，而文件里的 `set scroll off` 可能已经太晚。`-s` 同时把 `silent` 打开，报告里只留数据，不留横幅。

**可复现性：** 两次运行行数相同、结构相同。地址、PID、时间戳随 dump 变，别的都不该变。
