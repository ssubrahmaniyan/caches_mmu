# LLCache_1rw

This directory contains the LLCache 1RW implementation and its testbench.

## Clone the Repository

```bash
git clone --recurse-submodules git@gitlab.com:shaktiproject/uncore/caches_mmu.git
cd caches_mmu
```

## Checkout the LLCache Branch

```bash
git fetch --all
git checkout LLCache
git pull --ff-only origin LLCache
```

## Pull Submodules

```bash
git submodule sync --recursive
git submodule update --init --recursive --remote
```

## Run LLCache_1rw Tests

From the repository root:

```bash
cd src/LLCache_1rw/testbench
make
```

`make` in this `testbench` directory builds and runs the LLCache_1rw testbench.
