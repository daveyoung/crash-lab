# Crash Lab

[English](../index.html) | **中文**

本实验是用 `crash` 做 Linux 内核vmcore分析（postmortem）的实战系列。 分为五个部分，
二十篇文章。本实验的目标是让 `crash` 更容易上手。如果您发现问题欢迎提 PR。

<!--POSTS-->

## 实验模块

[`crashlab/`](../crashlab/index.html) 是一个用于实验的内核模块：从 debugfs 触发一次空指针
解引用，另外在加载时建一个四个节点的链表。它会触发内核panic，推荐在用于测试的虚拟机里
使用。

## 许可

模块使用 GPL-2.0。
