# Clippy and Rustfmt CI Gate In Depth

## Why "Prints Warnings" Isn't a Gate

`cargo clippy` by itself only prints lint diagnostics to the terminal — it
exits `0` even when lints fire, so a CI job that just runs `cargo clippy`
will show warnings in the log and still report success. To make it an
actual gate, warnings must be turned into a hard failure.

## Turning Warnings Into a Hard Failure

The direct way, on the command line:

```bash
cargo clippy -- -D warnings
# check every target/feature combination, not just the default
cargo clippy --all-targets --all-features -- -D warnings
```

Or via the `RUSTFLAGS` environment variable, which additionally makes any
other `cargo` invocation (build, test) fail on warnings too:

```bash
export RUSTFLAGS="-Dwarnings"
```

## CI Snippets

**GitHub Actions:**

```yaml
on: push
name: Clippy check

# Make sure CI fails on all warnings, including Clippy lints
env:
  RUSTFLAGS: "-Dwarnings"

jobs:
  clippy_check:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
      - name: Run Clippy
        run: cargo clippy --all-targets --all-features
```

**GitLab CI:**

```yaml
variables:
  RUSTFLAGS: "-Dwarnings"

clippy_check:
  image: rust:latest
  script:
    - rustup component add clippy
    - cargo clippy --all-targets --all-features
```

**Travis CI:**

```yaml
language: rust
rust:
  - stable
  - beta
before_script:
  - rustup component add clippy
script:
  - cargo clippy --all-targets --all-features -- -D warnings
  - cargo test
```

Pair this with a `cargo fmt --check` step (fails if any file isn't
formatted per `rustfmt`, without rewriting it) so formatting drift is
caught the same way lint drift is.

## Lint Groups Beyond the Default

Clippy organizes lints into groups with different default states:

| Group | Default | Purpose |
|---|---|---|
| `clippy::correctness` | warn/deny | Code that is outright wrong |
| `clippy::style` | warn | Idiomatic style (the RFC 430 casing lints live here) |
| `clippy::complexity` | warn | Needlessly complex constructs |
| `clippy::perf` | warn | Common performance footguns |
| `clippy::pedantic` | **allow** | Opinionated lints with plausible false positives — enable deliberately, expect to `#[allow]` some |
| `clippy::restriction` | **allow** | Lints that restrict the language on purpose (`unwrap_used`, `expect_used`, `unimplemented`, etc.) — enable individually, not as a whole group, since some are mutually exclusive by design |
| `clippy::nursery` | **allow** | New lints still being validated — expect false positives |

Enable an allow-by-default group (or individual lint) either in code:

```rust
#![warn(clippy::pedantic)]
#![deny(clippy::unwrap_used, clippy::expect_used)]
```

or in `Cargo.toml` (the modern, project-wide way, checked into version
control so it applies uniformly regardless of how `cargo clippy` is
invoked):

```toml
[lints.clippy]
unwrap_used = "deny"
expect_used = "deny"
pedantic = { level = "warn", priority = -1 }
```

`clippy::restriction` lints are meant to be cherry-picked, not enabled as
a block — several of them actively conflict with each other or with
`clippy::pedantic` by design (e.g. a lint that forbids one idiom and
another that recommends it in a different context).
