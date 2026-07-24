# Naming and API Design In Depth

## RFC 430 Naming — Full Table

| Item | Convention | Notes |
|---|---|---|
| Crates | no strict convention | avoid `-rs`/`-rust` suffix/prefix — every crate is Rust |
| Modules | `snake_case` | |
| Types (structs, enums) | `UpperCamelCase` | |
| Traits | `UpperCamelCase` | |
| Enum variants | `UpperCamelCase` | |
| Functions, methods | `snake_case` | |
| General constructors | `new` or `with_more_details` | |
| Conversion constructors | `from_some_other_type` | |
| Macros | `snake_case!` | |
| Local variables | `snake_case` | |
| Statics, constants | `SCREAMING_SNAKE_CASE` | |
| Type parameters | concise `UpperCamelCase`, usually one letter | `T`, `E` |
| Lifetimes | short `lowercase`, usually one letter | `'a`, `'de`, `'src` |

Acronyms and contractions count as **one word**:

- In `UpperCamelCase`: `Uuid` (not `UUID`), `Usize` (not `USize`), `Stdin`
  (not `StdIn`).
- In `snake_case`: lower-cased entirely, e.g. `is_xid_start`.

In `snake_case`/`SCREAMING_SNAKE_CASE`, a "word" should never be a single
letter unless it's the last word: `btree_map` (not `b_tree_map`), but
`PI_2` (not `PI2`).

## Conversion Method Naming (`as_`/`to_`/`into_`)

Three prefixes signal three different costs/ownership shapes for a
conversion method:

- **`as_*`** — free, borrowed-to-borrowed. `fn as_bytes(&self) -> &[u8]`.
- **`to_*`** — expensive, borrowed-to-owned (typically allocates/copies).
  `fn to_uppercase(&self) -> MyString`.
- **`into_*`** — owned-to-owned, consumes `self`. `fn into_bytes(self) ->
  Vec<u8>`.

When a conversion involves mutability, `mut` appears where it would in the
resulting type: `as_mut_slice` (returns `&mut [T]`), not `as_slice_mut`.

```rust
impl MyString {
    pub fn as_bytes(&self) -> &[u8] { &self.data }
    pub fn to_uppercase(&self) -> MyString { /* allocates */ }
    pub fn into_bytes(self) -> Vec<u8> { self.data }
    pub fn as_mut_slice(&mut self) -> &mut [u8] { &mut self.data }
}
```

## Flexibility: Minimal Assumptions in Public Signatures

Prefer the least restrictive type/trait bound a function's implementation
actually needs, so callers aren't forced into unnecessary conversions:

```rust
// Prefer this — works with &str, String, &Path, ...
pub fn read_config<P: AsRef<Path>>(path: P) -> io::Result<Config> {
    let file = File::open(path)?;
    // ...
}

// Over this — forces every caller through &Path first
pub fn read_config(path: &Path) -> io::Result<Config> { /* ... */ }

// Prefer this — works with Vec, arrays, ranges, any IntoIterator
pub fn sum_values<I: IntoIterator<Item = i64>>(iter: I) -> i64 {
    iter.into_iter().sum()
}

// Over this — forces a Vec allocation at every call site that doesn't
// already have one
pub fn sum_values(c: &Vec<i64>) -> i64 { /* ... */ }
```

This cuts both ways: generics have real costs (monomorphization increases
binary size, homogeneous-type constraints, more verbose signatures at high
generic counts). The goal is matching the bound to what the function
actually requires — not maximizing genericity for its own sake, and not
over-constraining callers with a concrete type the implementation didn't
need.
