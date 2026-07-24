# Error Handling In Depth

## Result, Option, and `?`

Rust categorizes errors into two kinds, and the type system reflects the
split directly:

- **Recoverable errors** — represented by `Result<T, E>`. A caller can
  inspect `E` and decide what to do: retry, fall back, surface to a user,
  or propagate further up.
- **Unrecoverable errors** — represented by `panic!` (and the things built
  on it: `.unwrap()`, `.expect()`, array-index-out-of-bounds, integer
  overflow in debug builds). These stop the current thread; they are for
  bugs, not expected failure conditions.

`Option<T>` is the sibling type for "no error occurred, there's just
nothing here" — a missing config key, an empty search result. Do not
overload `Result<T, ()>` or a sentinel value (`-1`, `""`) to mean "nothing
here" when `Option` says it directly.

The `?` operator is sugar for the match-and-early-return pattern:

```rust
// Manual propagation
fn read_username_from_file() -> Result<String, io::Error> {
    let username_file_result = File::open("hello.txt");
    let mut username_file = match username_file_result {
        Ok(file) => file,
        Err(e) => return Err(e),
    };
    let mut username = String::new();
    match username_file.read_to_string(&mut username) {
        Ok(_) => Ok(username),
        Err(e) => Err(e),
    }
}

// With `?`
fn read_username_from_file() -> Result<String, io::Error> {
    let mut username_file = File::open("hello.txt")?;
    let mut username = String::new();
    username_file.read_to_string(&mut username)?;
    Ok(username)
}

// Chained further
fn read_username_from_file() -> Result<String, io::Error> {
    let mut username = String::new();
    File::open("hello.txt")?.read_to_string(&mut username)?;
    Ok(username)
}
```

`?` converts the error type via `From` at each propagation point, which is
what makes it compose across a call chain that returns different (but
convertible) error types — the mechanism `thiserror` and `anyhow` both
lean on.

Only wrap an error with added context when that context is genuinely
useful to the caller. Wrapping reflexively at every call site (`.context("failed
to do X")` on every single `?`) produces long, redundant error chains that
bury the actually-useful information.

## The thiserror/anyhow Boundary

**This is community convention, not official rust-lang policy.** Multiple
independent sources in the Rust community converge on the same rule of
thumb, which is why it is worth encoding here — but no compiler lint, RFC,
or rust-lang team document mandates it. Treat deviations as a judgment
call, not a violation.

**Library crates: a specific error enum, typically via `thiserror`.**

```rust
use thiserror::Error;

#[derive(Debug, Error)]
pub enum ConfigError {
    #[error("config file not found at {path}")]
    NotFound { path: PathBuf },

    #[error("failed to parse config: {0}")]
    ParseError(#[from] toml::de::Error),

    #[error("missing required field: {0}")]
    MissingField(String),
}
```

A caller of this library can `match` on `ConfigError::NotFound { .. }` and
handle that case specifically (e.g., write a default config) versus
`ConfigError::ParseError` (surface a syntax error to the user). An opaque
boxed error (`anyhow::Error`, `Box<dyn Error>`) as the return type would
take that ability away — the caller gets a string-shaped failure and
nothing to branch on.

**Application/binary crates: a broad, ergonomic type, typically
`anyhow::Error`.**

```rust
use anyhow::{Context, Result};

fn run() -> Result<()> {
    let config = load_config("app.toml")
        .context("failed to load application config")?;
    // ...
    Ok(())
}
```

An application's ultimate caller is a human reading a terminal or a log
aggregator, not code that pattern-matches on failure variants. `anyhow`
optimizes for exactly that: easy `?`-propagation across many different
underlying error types, plus `.context()` to annotate the chain for a
human reader, at the cost of losing the ability to `match` on a specific
variant.

A crate that legitimately has one caller it controls, or an application
that re-exports part of itself as a library other crates depend on, can
reasonably deviate from this split — but that should be a deliberate
choice, not a default.

## `.unwrap()` / `.expect()` and the `unwrap_used` Lint

`.unwrap()` and `.expect()` are appropriate:

- In tests and `#[cfg(test)]` code — a test failing loudly on an
  unexpected `Err`/`None` is the point.
- In quick prototypes not yet hardened for production input.
- Where the invariant is provable at compile time or by the surrounding
  code (e.g., `.get(0).unwrap()` immediately after checking
  `!v.is_empty()`, or unwrapping a `Regex::new()` on a string literal
  known-valid at compile time).

They are not appropriate on paths that handle untrusted or fallible input
in shipped code — every such unwrap is a potential unhandled panic.

Clippy ships `unwrap_used` and `expect_used` lints for exactly this, but
both live in the **`clippy::restriction` group, which is allow-by-default**
— `cargo clippy` on its own will not flag them. A crate must opt in
explicitly:

```toml
# Cargo.toml
[lints.clippy]
unwrap_used = "deny"
expect_used = "deny"
```

or, in code:

```rust
#![deny(clippy::unwrap_used, clippy::expect_used)]
```

Two configuration knobs (in `clippy.toml`) narrow false positives once the
lint is enabled:

- `allow-unwrap-in-tests` (default `false`) — set `true` to exempt test
  code from the lint instead of relying on `#[cfg(test)]`-scoped
  `#[allow(...)]`.
- `allow-unwrap-types = ["some::Type"]` — exempt specific types (e.g. a
  `LockResult` your codebase treats as infallible in practice) from both
  `unwrap_used` and `expect_used`.

## Forbidden Patterns (Detail)

- **`.unwrap()`/`.expect()` on untrusted input paths in shipped code** —
  the compiler will not catch this; only the opt-in restriction lint or
  review will.
- **A library's public function signature returning `anyhow::Error`** (or
  `Box<dyn std::error::Error>` used the same way) — forces every caller
  into string-shaped error handling with no way to branch on failure mode.
- **Reflexive `.context()` on every single `?`** — makes error chains long
  and noisy instead of highlighting the one piece of context that actually
  helps diagnose the failure.
- **Swallowing an `Err` silently** (`let _ = fallible_call();`) instead of
  propagating, logging, or explicitly documenting why the failure is safe
  to ignore.
