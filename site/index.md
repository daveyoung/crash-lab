# Crash Lab

Practical Linux kernel postmortem analysis with `crash`, written as a series of
case-driven posts. Every dump comes from a kernel built from source, crashed on
purpose.

Twenty posts, in five parts. Finished posts are links; the rest are listed as
planned and gain a link as they land.

This lab is meant to make `crash` easier to learn.
If you find something to improve, pull requests are welcome.

<!--POSTS-->

## The module

[`crashlab/`](crashlab/) is a small deliberately buggy kernel module: a NULL
dereference you trigger from debugfs, and a four-entry list that a dump can be
walked by hand. It panics the machine it runs on — use a disposable VM.

## Building this site

```sh
./build.sh          # renders everything into docs/
```

`docs/` is what gets published. The posts are Markdown; `build.sh` renders them,
their answers, and this page into self-contained HTML with `pandoc`, and rewrites
the answer links.

## Licence

The module is GPL-2.0. The posts are © the author.
