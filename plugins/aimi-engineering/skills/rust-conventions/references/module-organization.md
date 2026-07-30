# Module and Crate Organization In Depth

## File-Per-Module vs `mod.rs`

Rust supports two ways to place a module's code in its own file:

**Modern, idiomatic style — module name as filename:**

```text
backyard
├── Cargo.toml
└── src
    ├── main.rs
    ├── garden.rs           # `mod garden;` declared in main.rs
    └── garden
        └── vegetables.rs   # submodule of `garden`, `mod vegetables;` in garden.rs
```

**Older style — `mod.rs` inside a directory named after the module:**

```text
backyard
├── Cargo.toml
└── src
    ├── main.rs
    └── garden
        ├── mod.rs          # the `garden` module itself
        └── vegetables.rs
```

Both are functionally equivalent and legal — the Rust Book itself now
names the first "the modern, idiomatic style" and the second "the older
style." Prefer the first for new code. The practical reason to care: a
project with many modules produces many identically-named `mod.rs` tabs in
an editor, which the file-per-module style avoids entirely.

Mixing the two styles **within the same crate** is legal but discouraged —
it makes navigation inconsistent. Using **both for the same module** (e.g.
both `garden.rs` and `garden/mod.rs` present) is a compiler error, not just
a style nit.

One legitimate exception where `mod.rs` still shows up deliberately: Rust's
own test-organization convention uses `tests/common/mod.rs` for shared
integration-test helpers, specifically because a file `tests/common.rs`
would otherwise be picked up by cargo as its own top-level integration test
binary. That's a narrow, intentional carve-out, not a reason to default
back to `mod.rs` everywhere.

## Curating a Public API with `pub use`

A crate's internal module structure and its public API do not have to
match. Keep implementation details organized however makes sense
internally (`pub(crate)` for anything only used within the crate), and use
`pub use` at the crate root to present a flat, curated surface to
consumers:

```rust
//! # Art
//!
//! A library for modeling artistic concepts.

pub use self::kinds::PrimaryColor;
pub use self::kinds::SecondaryColor;
pub use self::utils::mix;

pub mod kinds {
    // --snip--
}

pub mod utils {
    // --snip--
}
```

Consumers then write `use art::PrimaryColor;` and `use art::mix;` instead
of reaching into `art::kinds::PrimaryColor` — simpler for them, and it
decouples your public API from your internal module layout: you can freely
reorganize `kinds`/`utils` internally later without a breaking change, as
long as the `pub use` re-exports stay stable.

The same mechanism works one level down, inside a crate, to re-export a
deeply nested item at a shallower path:

```rust
mod front_of_house {
    pub mod hosting {
        pub fn add_to_waitlist() {}
    }
}

pub use crate::front_of_house::hosting;

pub fn eat_at_restaurant() {
    hosting::add_to_waitlist();
}
```

`pub use` re-exports also show up directly in generated `rustdoc` output at
the location they're re-exported to, which is part of why curating them
matters for a library's documentation, not just its import ergonomics.

## Deriving Instead of Hand-Rolling

When a type logically supports a standard trait, derive it rather than
implementing an equivalent by hand:

```rust
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Config {
    pub max_retries: u32,
    pub timeout_ms: u64,
}
```

This is what lets `Config` work naturally with `{:?}` formatting,
equality comparisons, cloning, and any generic code written against
`T: Clone + PartialEq` — all without writing or maintaining that
boilerplate by hand. Reach for a manual `impl` only when the derived
behavior would be semantically wrong (e.g. a `PartialEq` that should
compare only some fields, or a `Clone` that needs to deep-copy a resource
handle differently than a field-by-field clone would).
