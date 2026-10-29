# Crash Lab

A series of posts about practical Linux kernel postmortem analysis with
`crash`, plus the small deliberately buggy module the examples are built on.

Every dump in the series comes from a kernel built from source, crashed on
purpose. You are expected to bring your own kernel build and your own way of
running it — a VM, a spare machine, whatever you can afford to lose.

## What is here

```
posts/
  01-what-crash-is/     # what the tool needs, and how to tell it is lying
  02-the-lab/           # build, crash, capture, open the first dump
  03-the-command-language/  # context, output, files, foreach
  04-symbols-types-addresses/  # type system, lists, dis, translation
crashlab/
  crashlab.c            # the module: a NULL deref you trigger from debugfs
  Makefile
  README.md
assets/
  blog.css              # shared by the post renderers
```

## What you need

- A kernel you built yourself, with `CONFIG_DEBUG_INFO` and a full DWARF
  variant (`DWARF5` here), and without `DEBUG_INFO_REDUCED` or
  `DEBUG_INFO_SPLIT`. The second post lists the rest.
- `crash` built or installed for your distro.
- `kexec-tools` and `makedumpfile` in the environment that will capture the
  dump.
- Something disposable to panic.

The examples were produced with kernel `7.3.0+`, `crash 9.0.3++`,
`makedumpfile 1.7.9++`, QEMU 10.1.2 and GCC 15.2.1. Older and newer toolchains
work; the warnings differ.

## Build

Each post is `index.md` plus `answers.md`. The site is generated into `docs/`:

```sh
./build.sh
```

That needs `pandoc` 3.0 or newer. `build.sh` renders the landing page, every
post, its answers, and the module README into self-contained HTML, rewrites the
answer links, and drops a `.nojekyll` marker. The per-post `render.sh` still
works for a quick single-page preview.

## Publish with GitHub Pages

`docs/` is committed, so no CI is required:

```sh
git remote add origin git@github.com:<user>/<repo>.git
git push -u origin main
```

Then in the repository: **Settings → Pages → Build and deployment → Deploy from
a branch**, branch `main`, folder `/docs`. The site appears at
`https://<user>.github.io/<repo>/`.

If you would rather build in CI, drop `docs/` from git and add a workflow that
runs `./build.sh` and uploads `docs/` with `actions/upload-pages-artifact`.

## The module

```sh
cd crashlab
make KDIR=~/crash-lab/linux
```

It panics the machine it is loaded into. See `crashlab/README.md`.

## Licence

The module is GPL-2.0. The posts are © the author.
