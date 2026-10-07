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

# Nu expands runs of three or more dots in any path component.
def needs-literal-path [path: string] {
    $path =~ '(^|/)\.{3,}(/|$)'
}

def entry-type [path: string] {
    if not (needs-literal-path $path) {
        let type: any = ($path | path type)
        match $type {
            null => { 'missing' }
            'dir' => { 'dir' }
            'symlink' => { 'link' }
            _ => { 'leaf' }
        }
    } else if (exists-as '-L' $path) { 'link' } else if (exists-as '-d' $path) {
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
        let nodes = ($job.tree | transpose name value | each {|entry|
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
                    {path: $path, kind: 'dir', payload: $value}
                }
                'string' | 'binary' => {
                    {path: $path, kind: 'file', payload: $value}
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
                    {path: $path, kind: $kind, payload: $payload}
                }
                _ => { error make {msg: $"nuon2dir: unsupported value type ($type) at ($path)"} }
            }
        })
        let children = ($nodes | where kind == 'dir' | each {|node|
            {path: $node.path, tree: $node.payload}
        })
        $todo = ($todo | append $children)
        # Collect a whole directory at once instead of copying the growing
        # plan for every member. Directory payloads are only needed in todo.
        $plan = ($plan | append ($nodes | update payload {|node|
            if $node.kind == 'dir' { null } else { $node.payload }
        }))
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
@example 'Create a file and a symbolic link' '{hello: "world", current: [link hello]} | nuon2dir'
@example 'Create an executable file in a destination directory' '{run: [script "#!/bin/sh\necho hello\n"]} | nuon2dir --root ./result'
@example 'Materialize a NUON file' 'open tree.nuon | nuon2dir --root ./result'
export def main [
    --root: path = '.' # Destination directory, created if missing
]: [record -> nothing, nothing -> nothing] {
    let tree = $in
    # The nothing signature permits --help without input; execution needs a record.
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
    if (needs-literal-path $root) {
        checked 'mkdir' '-p' '--' $root
    } else { mkdir $root }
    for node in $plan {
        let existing = (entry-type $node.path)
        if $existing == 'dir' {
            if $node.kind == 'dir' { continue }
            error make {msg: $"nuon2dir: cannot replace directory with ($node.kind): ($node.path)"}
        }
        let literal = (needs-literal-path $node.path)
        if $existing != 'missing' {
            if $literal { checked 'rm' '--' $node.path } else { rm --permanent $node.path }
        }
        match $node.kind {
            'dir' => {
                if $literal { checked 'mkdir' '--' $node.path } else { mkdir $node.path }
            }
            'link' => { checked 'ln' '-s' '--' $node.payload $node.path }
            _ => {
                if $literal {
                    # Fixed shell program with the literal path passed as an argument.
                    $node.payload | checked 'sh' '-c' 'cat > "$1"' 'nuon2dir' $node.path
                } else { $node.payload | save --raw $node.path }
                if $node.kind == 'script' { checked 'chmod' 'a+x' '--' $node.path }
            }
        }
    }
}
