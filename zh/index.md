# Crash Lab

[English](../index.html) | **中文**

用 `crash` 做 Linux 内核事后分析（postmortem）的实战系列。每一份 dump 都来自
自己编译、故意弄崩的内核，而不是从别处捡来的样本。

二十篇文章，分成五部分。写好的给出链接，还没写的标成"待发布"，写完一篇链接就
自动出现。

本实验的目标是让 `crash` 更容易上手。发现问题欢迎提 PR。

<!--POSTS-->

## 实验模块

[`crashlab/`](../crashlab/index.html) 是一个故意写坏的小内核模块：从 debugfs 触发一次空指针
解引用，另外在加载时建一条四节点的链表，方便在 dump 里手动走一遍。它会让所在机器
panic，请只在一次性虚拟机里用。

## 构建本站

```sh
./build.sh          # 生成到 docs/
```

`docs/` 就是发布出去的内容。文章是 Markdown，`build.sh` 用 `pandoc` 把正文、答案
和首页渲染成自带样式的 HTML，并把答案链接改写成 `.html`。

## 许可

模块使用 GPL-2.0，文章版权归作者。
