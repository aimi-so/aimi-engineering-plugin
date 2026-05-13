# Topic Slug Derivation

Shared reference for deriving a URL-safe slug from a feature description.
Apply these five steps wherever the command says "derive a topic slug."

## Algorithm

Given a feature description string:

1. Convert to lowercase
2. Replace spaces and special characters with hyphens
3. Remove consecutive hyphens
4. Truncate to 50 characters
5. Remove trailing hyphens

The result is the topic slug used in research output paths, brainstorm
filenames, prototype paths, and any other artefact that embeds the topic.
