# Crash Lab

Practical Linux kernel postmortem analysis with `crash`, written as a series of
case-driven posts. Every dump comes from a kernel built from source, crashed on
purpose.

## Posts

1. **What `crash` is, and what it needs** — the two files a session is built
   from, the banner, and how to tell a bad `vmlinux` from a good one.
   [Read](posts/01-what-crash-is/)
2. **The lab: build a kernel you can crash, and a dump you can read** — config,
   `crashlab.ko`, `kexec -p`, `makedumpfile`, first session.
   [Read](posts/02-the-lab/)
3. **The command language** — context, output control, command files,
   `foreach`, aliases, and a triage file.
   [Read](posts/03-the-command-language/)
4. **Symbols, types, addresses** — `sym` versus DWARF, `mod -S`, list walking,
   `container_of`, `dis`, and address translation.
   [Read](posts/04-symbols-types-addresses/)

More posts are on the way. Each one ships with answers and is meant to be
reproduced against your own kernel and dump.

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
