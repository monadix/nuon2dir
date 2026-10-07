# Materialize native Nushell records as directory trees.

def value-type [value: any] {
    $value | describe | split row '<' | first
}

# Always check external exit status; Nushell does not throw on it by default.
def checked [command: string ...args: string] {
    let result = ($in | ^$command ...$args | complete)
    if $result.exit_code != 0 {
        error make {msg: $"nuon2dir: ($command) failed: ($result.stderr | str trim)"}
    }
}

def exists-as [flag: string path: string] {
    let result = (^test $flag $path | complete)
    if $result.exit_code > 1 {
        error make {msg: $"nuon2dir: cannot inspect ($path): ($result.stderr | str trim)"}
    }
    $result.exit_code == 0
}

def entry-type [path: string] {
    if (exists-as '-L' $path) { 'link' } else if (exists-as '-d' $path) {
        'dir'
    } else if (exists-as '-e' $path) { 'leaf' } else { 'missing' }
}

# Build a validated plan iteratively, without consuming the recursion budget.
def plan-tree [root: string tree: record] {
    mut todo = [{path: $root, tree: $tree}]
    mut plan = []
    while not ($todo | is-empty) {
        let job = ($todo | last)
        $todo = ($todo | drop 1)
        for entry in ($job.tree | transpose name value) {
            let name = $entry.name
            if (($name == '') or ($name == '.') or ($name == '..') or
                ($name | str contains '/') or ($name | str contains (char nul))) {
                error make {msg: $"nuon2dir: invalid entry name ($name | to nuon)"}
            }
            # String concatenation deliberately avoids Nushell path expansion.
            let path = $"($job.path)/($name)"
            let value = $entry.value
            let type = (value-type $value)
            match $type {
                'record' => {
                    $plan = ($plan | append {path: $path, kind: 'dir', payload: null})
                    $todo = ($todo | append {path: $path, tree: $value})
                }
                'string' | 'binary' => {
                    $plan = ($plan | append {path: $path, kind: 'file', payload: $value})
                }
                'list' => {
                    if ($value | length) != 2 {
                        error make {msg: $"nuon2dir: expected a two-element link/script at ($path)"}
                    }
                    let kind = $value.0
                    let payload = $value.1
                    if (value-type $kind) != 'string' or (value-type $payload) != 'string' {
                        error make {msg: $"nuon2dir: link/script elements must be strings at ($path)"}
                    }
                    if $kind not-in ['link' 'script'] {
                        error make {msg: $"nuon2dir: unknown node kind ($kind) at ($path)"}
                    }
                    $plan = ($plan | append {path: $path, kind: $kind, payload: $payload})
                }
                _ => { error make {msg: $"nuon2dir: unsupported value type ($type) at ($path)"} }
            }
        }
    }
    $plan
}

# Create a tree from a native record. Strings/binary become files; records
# become directories. Existing directories are merged; unlisted entries survive.
#
# Special entries use two-element lists of strings:
#   [link "target"]     creates a symbolic link; target is stored verbatim.
#   [script "contents"] writes a file and adds all three execute bits.
# Script contents are never executed.
#
# Names must be nonempty, not . or .., and contain neither / nor NUL.
# The complete tree is validated before writing. Files and symlinks are
# replaced; directories cannot be replaced by leaves. Filesystem failures
# may leave earlier writes in place.
#
# Examples:
#   {hello: "world", current: [link hello]} | nuon2dir
#   {run: [script "#!/bin/sh\necho hello\n"]} | nuon2dir --root ./result
#   open tree.nuon | nuon2dir --root ./result
export def main [
    --root: path = '.' # Destination directory, created if missing
] {
    let tree = $in
    if (value-type $tree) != 'record' {
        error make {msg: 'nuon2dir expects a record as pipeline input'}
    }
    if $nu.os-info.name == 'windows' {
        error make {msg: 'nuon2dir requires a POSIX system'}
    }
    # Resolve the explicitly selected root, then treat every member literally.
    let root = ($root | path expand)
    let plan = (plan-tree $root $tree)
    if (entry-type $root) not-in ['dir' 'missing'] {
        error make {msg: $"nuon2dir: root is not a directory: ($root)"}
    }
    checked 'mkdir' '-p' '--' $root
    for node in $plan {
        let existing = (entry-type $node.path)
        if $existing == 'dir' {
            if $node.kind == 'dir' { continue }
            error make {msg: $"nuon2dir: cannot replace directory with ($node.kind): ($node.path)"}
        }
        if $existing != 'missing' { checked 'rm' '--' $node.path }
        match $node.kind {
            'dir' => { checked 'mkdir' '--' $node.path }
            'link' => { checked 'ln' '-s' '--' $node.payload $node.path }
            _ => {
                # Fixed shell program, path passed as an argument. Both native
                # strings and binary stream unchanged; no Nu path shorthand.
                $node.payload | checked 'sh' '-c' 'cat > "$1"' 'nuon2dir' $node.path
                if $node.kind == 'script' { checked 'chmod' 'a+x' '--' $node.path }
            }
        }
    }
}
