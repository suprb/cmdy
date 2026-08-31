## What changed

<!-- Describe the user-visible or contributor-visible result. -->

## Why

<!-- Link an issue when one exists. Explain the problem, not only the diff. -->

## Approach

<!-- Call out important ownership, protocol, compatibility, or tradeoff choices. -->

## Validation

<!-- List exact commands and manual paths exercised. Use "Not run" with a reason when needed. -->

```text

```

## Evidence

<!-- Add before/after screenshots for UI changes and measurements for performance changes. Delete if not applicable. -->

## Risk and compatibility

<!-- Note migration, security, accessibility, performance, or release impact. Write "None" only after considering each boundary. -->

- Public protocol or schema change: no
- Security or trust-boundary change: no
- Performance-sensitive path: no
- User data or session migration: no

## Checklist

- [ ] The change is scoped and has focused tests proportional to its risk.
- [ ] Terminal bytes, shell processes, and ordinary input still work without optional platform features.
- [ ] New Extension authority has an explicit capability and a denial test.
- [ ] New public fields are documented and additive, or include a versioned migration path.
- [ ] UI changes were checked with keyboard navigation and at narrow and wide window sizes.
- [ ] No credentials, personal paths, generated build products, or private data are included.
- [ ] Documentation and the changelog are updated when users or contributors need them.
