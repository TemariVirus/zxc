# zxc

zxc is a simple Zig version manager that automatically detects the version of Zig needed based on the `minimum_zig_version` field in `build.zig.zon`.

> Why is it called zxc? Because it's easy to type on a keyboard and contains the letter 'z' which makes it look related to Zig.

Features:

- 0 configuration
- auto-detects required Zig version, or falls back to user input
- remembers last selected Zig version of each path when `build.zig.zon` cannot be found
- support for custom Zig versions
- list and remove Zig versions
- chooses a random mirror and verifies minisign signature

## Installation

Download the `zig` and `zxc` binaries from the releases page (TODO: release 1.0). That's it.

For convenience, you probably also want to move the binaries to somewhere inside your PATH.

## How do I use zxc?

zxc is comprised of 2 binaries: `zig` and `zxc`.

### `zig`

`zig` is a drop-in replacement for your regular Zig. It runs the appropriate Zig version upon startup,
or prompts the user if it cannot determine the version automatically.

### `zxc`

`zxc` is a CLI tool for managing installed Zig versions. This includes: installing, listing, and removing Zig versions.
More detailed help can be viewed by running `zxc --help`.

### Environment variables

Several environment variables affect zxc:

- `ZXC_FORCE_ZIG_VERSION` - If non-empty, this Zig version is always used regardless of `build.zig.zon`. Good for pinning Zig versions in scripts.
  Not recommended to set it to "master" as the "master" version is always changing.
- `ZXC_ALWAYS_INSTALL` - If non-empty, Zig versions are always installed when needed. Ignored when running `zig` from the CLI (answer those prompts!).

### Installing custom Zig versions

Custom Zig versions can be installed via a tarball or a directory.
In both cases, the directory structure must match that used by the official tarballs from [ziglang.org/download](ziglang.org/download)

```sh
zxc install 1.2.3-custom path/to/zig-tarball.tar.xz  # tarball will be extracted and installed
zxc install 1.2.3-custom path/to/zig-dir             # directory will be copied
```

To use the custom Zig versions, the `.minimum_zig_version` field of your `build.zig.zon` must be the same as the version argument used when installing.

```zig
.{
    // snip...
    .minimum_zig_version = "1.2.3-custom",
    // snip...
}
```

## Why make yet another Zig version manager?

Before making zxc, I was using [zvm](https://github.com/tristanisham/zvm), which even allows setting custom mirrors, index, and zls downloads.
Occasionally I would hop between projects on different Zig versions which required typing a lot of `zvm use`, but that was still okay...
if not for the fact that each invocation came with a _huge_ pause to query the lastest zvm version and tell me to upgrade.

```
> time zvm use 0.16.0
zvm use 0.16.0  0.03s user 0.02s system 4% cpu 0.987 total
# 0.987 / 0.05 = 20x slower than it needs to be?

# Plain old Zig 0.16.0
> time zig version
0.16.0
zig version  0.00s user 0.01s system 91% cpu 0.009 total

# zxc
> time zig version
0.16.0
zig version  0.00s user 0.01s system 92% cpu 0.010 total
```

So I looked to an alternative, called [anyzig](https://github.com/marler8997/anyzig). It sounded like it should solve both of my problems.
And indeed it does, however I noticed the seemingly ever-static TODO list in their README.
To give them credit where it's due, they did implement some of the items in the TODO.
However, I still need to run `zig any list-installed; rm ...` instead of a simple `zig any rm 0.15.2`, and I wasn't a fan of the complexity they added to the Zig CLI.

And that's how I stole anyzig's ideas and started working on zxc.
