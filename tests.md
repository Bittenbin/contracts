# Tests Run and Rationale

## Foundry Test Suites

- `test/EdgeCases.t.sol`
  - Validates URL requirements, single-axis constraints (no-op/diagonal reverts),
    and basic upvote/downvote moves under the new URL-derived `pageId` design.

- `test/PlatformMarkets.t.sol`
  - Validates market creation with URL hashing, URL uniqueness enforcement,
    and acceptance of non-Pythagorean coordinates.

- `test/Security.t.sol`
  - Validates security-related behavior (reentrancy-guarded paths, allowance limits,
    unauthorized fee extraction, and TenbinToken access control).
