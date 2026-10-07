# nuon2dir

Turn a native Nushell record into a directory tree. Import one module and pipe
in a record, an opened JSON/NUON file, or a computed value.

```nu
use ./nuon2dir.nu

{
    "hello.txt": "Hello, world!\n"
    config: { "app.conf": "theme = dark\n" }
    current: [link config]
    hello: [script "#!/bin/sh\necho hello\n"]
    "blob.bin": 0x[00 01 fe ff]
} | nuon2dir --root ./result
```

The default root is the current directory. A missing root is created, including
its parent directories. An explicitly selected root follows normal Nushell path
expansion, including resolving existing symlinks. Tree member names are literal.

## Data model

| Native value | Filesystem entry |
| --- | --- |
| Record | Directory |
| String | File containing exactly its UTF-8 bytes |
| Binary | File containing exactly its bytes (native extension) |
| `[link "target"]` | Symbolic link with the target stored verbatim |
| `[script "contents"]` | File with all three execute bits added |

The root must be a record. Every member name must be nonempty, different from
`.` and `..`, and contain neither `/` nor NUL. Names such as `...`, `*`, leading
dashes, backslashes, spaces, and Unicode are preserved. Nested paths must be
represented by nested records. Other value types, malformed special nodes, and
unknown node kinds are errors. Script contents are written, never run.

```nu
use ./nuon2dir.nu
open tree.json | nuon2dir
open examples/tree.nuon | nuon2dir --root ./result
'{"file": "contents"}' | from json --strict | nuon2dir
```

Parsing belongs to the caller. The module accepts values, and has no JSON or
NUON parsing mode. Link and script nodes are ordinary two-element lists
compatible with the JSON format. Run `help nuon2dir` or `nuon2dir --help` for
the data model and examples.

## Existing content and failures

Existing directories are merged, retaining their permissions and unlisted
entries. Existing files, symlinks (including dangling links), and other leaves
are removed before their replacements are created. Replacing a script with a
regular file clears its executable permissions. Existing symlinks at member
paths are replaced themselves; their targets are not modified.

A directory cannot be replaced with a file, link, or script. Neither the
directory nor its contents are deleted in that case. Files omitted from a later
tree remain on disk.

Traversal and validation use explicit work lists, supporting deep nesting
without recursive Nu command calls. The complete native value is validated
before any filesystem mutation. Filesystem failures throw errors and can leave
earlier writes in place; application is not atomic. The implementation uses
path-based operations and does not prevent concurrent symlink replacement
races. Use a destination that other processes cannot modify during application.

## Installation and dependencies

Tested with Nushell **0.115.1** on Linux. Requires a POSIX system and `test`,
`mkdir`, `rm`, `ln`, `chmod`, `sh`, and `cat` on `PATH` (standard Linux/macOS
tools). External command failures are checked and propagated.

Copy `nuon2dir.nu` into a directory on `$env.NU_LIB_DIRS`, then import it:

```nu
use nuon2dir.nu
```

No plugin or overlay is needed. Filesystem operations use literal external
arguments because Nushell built-ins expand dot-only names such as `...` into
parent paths, even when passed as strings. All tree handling and validation is
implemented in the Nu module; the fixed shell program used to write files
receives paths as arguments, never as interpolated shell source.

## JSON stdin command

The separate `json2dir` executable wrapper reads strict JSON from stdin and applies it in
the current directory:

```sh
/path/to/nuon2dir/bin/json2dir < tree.json
```

Add this repository's `bin` directory to `PATH` to call it as `json2dir`.
Keep the shell launcher, `bin/json2dir.nu`, and module in their existing relative
locations. The launcher rejects every argument, including `--help` and `-h`,
with a usage message on stderr and exit status 1, matching the original
json2dir CLI. It starts Nushell without configuration and returns a nonzero
status on failure. Native module help remains available through
`help nuon2dir` and `nuon2dir --help`.

## Verification

Run the local regression tests with Python 3 (standard library only):

```sh
python3 -m unittest discover -s tests -v
```

These exercise binary values, native type rejection, special nodes, NUON input,
100 nested records with a recursion limit of 12, literal names, validation
before mutation, symlink replacement, directory preservation, umask behavior,
strict JSON parsing, and external command failure reporting.

The wrapper also passes all **68** cases in the
[awesome-json2dir conformance suite](https://github.com/kitsunoff/awesome-json2dir/tree/main/conformance):
**52/52 core** and **16/16 overwrite**, tested against commit
`2ee7413a0a29d3d50b39049cb295dd2bf3b6fa77` on 2026-10-07.

To reproduce against that snapshot (substitute an absolute wrapper path):

```sh
git clone https://github.com/kitsunoff/awesome-json2dir.git /tmp/awesome-json2dir
git -C /tmp/awesome-json2dir checkout 2ee7413a0a29d3d50b39049cb295dd2bf3b6fa77
python3 /tmp/awesome-json2dir/conformance/run.py '/absolute/path/to/nuon2dir/bin/json2dir'
```

The native API implements the parsed tree behavior from
[RFC J2D-1](https://github.com/kitsunoff/awesome-json2dir/blob/main/spec/rfc-json2dir.md)
with binary files as an extension; the wrapper delegates raw JSON validation
to Nushell's `from json --strict`.

## References and license

Design follows the format of [alurm/json2dir](https://github.com/alurm/json2dir).
ISC licensed; see [LICENSE](LICENSE).
