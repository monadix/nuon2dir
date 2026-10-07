use ../nuon2dir.nu

def main [] {
    $in | from json --strict | nuon2dir
}
