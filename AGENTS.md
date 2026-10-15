# Notes for coding agents

This repository holds reference implementations. People point agents here for
one of two reasons: to use a tool as it is, or to build their own version. When
your user is building their own, it's their project, not this one: follow its
language, conventions and naming.

## Building something similar

1. Read the tool's `ARCHITECTURE.md` before its code. It separates the invariants
   (keep them) from incidental choices like the framework, the transport, or
   Docker (replace them freely).
2. Read the tests next. They describe the behavior more precisely than the
   prose does. Port the ones that cover the invariants.
3. Fit the result to the user's repository: their build system, their way of
   doing dependency injection, their storage, their naming. Don't copy names
   from this repository unless they fit.
4. Treat the "Pitfalls" section of `ARCHITECTURE.md` as a checklist. Each item cost
   real debugging time here.
5. Finish with a short summary of what you kept, what you changed, and why.

## Using a tool as it is

Pin a release tag (`<tool>-vX.Y.Z`) and follow the tool's `examples/`. Don't
vendor the whole directory unless the user asks for it.

## Layout

```text
<tool>/
  README.md        what it does and how to run it
  ARCHITECTURE.md  decisions, invariants, pitfalls
  examples/        integration code
  tests/           server-side tests (examples carry their own)
scripts/           repository tooling, not part of any tool
```
