# Upstream fix PR body (zero false positives)

<!-- Every section is required. The grader rejects a PR that skips one. No internal names, IPs, wallets or lab details. -->

## The bug
What goes wrong, for whom, and why it matters. Fixes #<issue>.

## Where
`path/to/file.go:<line>` on `<base commit>`, and the traced path from the entry point to the failure.

## Reproduction on the base
Steps on a clean `<base commit>` checkout. Runtime bug: a live run with the result. Logic bug: the failing test.

## The fix
What changed and why this is the smallest correct change.

## Proof
- A test that fails on the base and passes with the fix.
- A surgical compiling mutant of the fix that the test catches.
- For runtime bugs: the live run with the fix, with one side changed (client or node), same machine.

## Gate
Build, `go vet`, cross-builds for every OS, `go test -race -count=3` on the touched packages; on-chain program diff
empty.

## Scope, risk, compatibility
What else it touches, what could break, old clients/nodes.

## Alternatives ruled out
What else was tried or considered, and why not.

Merge after #<N> (only when it depends on another PR).
