# Thin alias over ./caliper so `just run` and `./caliper run` are the same
# entry. Single source of truth is the shell script; this file has no
# behaviour of its own. `just` is optional -- everything here works
# without it.

default:
    @./caliper --help

run *ARGS:
    @./caliper run {{ARGS}}
