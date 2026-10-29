# 答案：认识 crash

## 1. 一份 dump，三个候选 vmlinux

**答案：build ID 与 dump 相同的那个。**

两侧各一条命令：

```sh
crash --build-id the.vmcore                            # 6460abf30df798ec67d2db4aae0d9a1fcdfb9f63
readelf -n candidate-1/vmlinux | grep -A1 'Build ID'   # 与上面比较
```

dump 侧读的是 `VMCOREINFO` 里的 `BUILD-ID`，namelist 侧读的是 ELF 的 `NT_GNU_BUILD_ID` note。两个字符串相同，说明是同一次构建，而不只是同一份源码。

**为什么不能比 release：** 本实验的三个候选都报 `Linux version 7.3.0+`。一个是匹配的构建，一个是同配置重编（build ID `0a649fbb…`），一个是加了 `CONFIG_IKCONFIG=y` 的构建（`5d2a2a5a…`）。release 相同，因为没人改 `Makefile`。

**为什么不能只靠 `crash -g`：** 它只回答"这个文件里有没有 DWARF"，三个都有。

**错的那两个会怎样：** `IKCONFIG` 那次在布局移动后被拒（`could not find MAGIC_START!`）。同配置重编的那次只留一行 `kernel version inconsistency` 警告，然后照常工作——这正是必须靠 build ID 才能定案的情况。

## 2. 只警告一次、之后看起来完美的会话

**答案：布局相同，所以"看起来对"不能证明"是对的"。**

同一份 `.config` 重编，函数还在同样的地址上。`bt` 走同样的帧、打同样的名字；`sys` 除了 `VERSION` 之外一模一样。没有任何东西**明显**坏掉，于是"栈讲得通，namelist 应该没错"这个直觉，被一个并非崩溃内核的文件满足了。

两件事仍然成立，而且都重要：

1. 你无法证明代码相同。脏源码树、编译器小版本差异、只移动数据的配置改动，都可能在大部分地址不变的情况下改变某个结构体成员或分支。警告就是工具在说：它也不知道。
2. 你发布的结论会挂在一个 dump 里并不存在的 build ID 上，想复现的人必然失败。

**该做的：** 用同一 commit、同一 `.config` 重编，确认 build ID 与 dump 一致，再重跑你要引用的命令，并在记录里写上 build ID。匹配的构建已经没了，就在报告里明说，把地址当作参考值，而不是把另一次构建的符号解析当事实。

**不该做的：** `--no_data_debug` 和 `--machdep` 都不是修复。它们改变 crash 读什么、怎么映射，不会把两次构建变成一次。

## 3. 类型与字节

**答案：`vmlinux` 提供类型（以及符号、行号），`vmcore` 提供内存内容和寄存器/notes 状态。**

只有 `System.map` 时，你保留了地址到名字的映射，所以有时还能读出一串函数名，也能把某个原始地址落到函数附近。你失去的是：

- 所有结构体布局，于是 `ps`、`struct task_struct`、`kmem -s`、`files` 以及本系列大部分命令要么失败，要么得自己手算指针；
- 行号与源码路径，于是没有 `bt -l`；
- 枚举与 typedef 名字，于是原始整数仍然是原始整数。

`System.map` 是符号表，不是 namelist，`crash` 也不会接受它作为第一个参数（`namelist argument required`）。
