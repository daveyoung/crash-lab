# Answers — What `crash` is, and what it needs

## 1. One dump, three candidate `vmlinux` files

**Answer:** the one whose build ID matches the dump's build ID.

Two commands, one from each side:

```sh
crash --build-id the.vmcore                       # 6460abf30df798ec67d2db4aae0d9a1fcdfb9f63
readelf -n candidate-1/vmlinux | grep -A1 'Build ID'   # compare with the above
```

The dump side reads the `BUILD-ID` key from `VMCOREINFO`; the namelist side reads the ELF `NT_GNU_BUILD_ID` note. Equal strings mean the same build, not merely the same source tree.

**Why not the release string:** in this lab all three candidates report `Linux version 7.3.0+`. One is the matching build, one is a rebuild of the same `.config` (build ID `0a649fbb…`), one is a build with `CONFIG_IKCONFIG=y` added (build ID `5d2a2a5a…`). Release strings are shared across all of them because nobody changed `Makefile`.

**Why not `crash -g`:** it only answers "does this file contain DWARF". All three do.

**What the wrong ones do:** the `IKCONFIG` build makes `crash` read the dump at addresses the namelist claims are kernel data, find the wrong bytes, and refuse to open (`do not match!`). The rebuild of the same config opens with a single `kernel version inconsistency` warning and otherwise behaves, which is the case that needs the build ID to settle.

## 2. A session that warns once and then looks perfect

**Answer:** because the layout is identical, correct-looking output is not evidence of correctness.

A rebuild of the same `.config` puts the same functions at the same addresses. `bt` walks the same frames and prints the same names; `sys` prints the same banner except `VERSION`. Nothing is *visibly* broken, so the usual instinct — "the stack trace makes sense, so the namelist must be right" — is satisfied by a file that is not the one that crashed.

Two things are still true and both matter:

1. You cannot prove the code is the same. A rebuild from a dirty tree, a different compiler point release, or a config that moved only data can change a struct member or a branch while leaving most addresses alone. The warning is the tool telling you it does not know either.
2. Any conclusion you publish will be attributed to a build ID that does not exist in the dump. A reader who tries to reproduce it will fail.

**What to do:** rebuild from the exact commit and `.config`, confirm the build ID matches the dump, and re-run the commands you intend to quote. Cite the build ID next to the transcript. If the matching build is gone, say so in the report and treat addresses as indicative only — never present a symbolization from a different build as fact.

**What not to do:** `--no_data_debug` and `--machdep` are not fixes. They change what `crash` reads or how it maps it; they do not make two different builds into one.

## 3. Types versus bytes

**Answer:** the `vmlinux` supplies types (and symbols and line numbers); the `vmcore` supplies the memory contents and the register/notes state.

With only `System.map` you keep the address-to-name mapping, so you can sometimes still read a stack trace of function names, and you can look up where a raw address falls. You lose:

- every struct layout, so `ps`, `struct task_struct`, `kmem -s`, `files`, and most of the command set in this series either fail or need you to do the pointer arithmetic by hand;
- line numbers and source paths, so no `bt -l`;
- enum and typedef names, so raw integers stay raw.

`System.map` is a symbol table. It is not a namelist, and `crash` will not take it as one (`namelist argument required`).
