# ERC-4626 donation attack experiment

Two vaults hold the same 18-decimal `MockToken`. `NaiveVault` deliberately exposes
the first-depositor inflation attack. `SafeVault` uses OpenZeppelin's virtual
assets and shares, with an immutable constructor offset from 0 through 18.

The deliverable is a local Foundry project. No contracts have been deployed and
there is no broadcast script.

```sh
forge build
forge test
forge fmt --check
forge test --match-test testPrintInflationTable -vv
python3 script/inflation_table.py
```

Solidity is pinned to **0.8.26**, targeting Cancun. Foundry and that compiler must
be installed on the checking machine. The required OpenZeppelin Contracts
**v5.0.2** sources and MIT license are ordinary files under
`lib/openzeppelin-contracts/`; builds need no package downloads or submodules.
Tests use a small local cheatcode interface, and neither read environment
variables nor use FFI or filesystem permissions. The optional table checker uses
only Python's standard library and runs the printing test locally.

See [docs/inflation.md](docs/inflation.md) for the measured table, exact accounting,
proof of the single-victim bound, assumptions, and operational responsibilities.

## Contracts and construction parameters

| Contract | Constructor | Purpose |
| --- | --- | --- |
| `MockToken` | `()` | 18 decimals, name `Mock Asset`, symbol `MOCK`; anyone can mint to any nonzero address. |
| `NaiveVault` | `(IERC20 asset_)` | Use the mock's address. Shares have 18 decimals; name `Naive Vault Share`, symbol `nvMOCK`. |
| `SafeVault` | `(IERC20 asset_, uint8 offset_)` | Use the same mock's address and recommended offset **6**. Shares have `18 + offset_` decimals; name `Safe Vault Share`, symbol `svMOCK`. |

Both vaults inherit OpenZeppelin's ERC-20 share token, allowance handling,
ERC-4626 entry/exit methods, preview methods and events. Both read the underlying
balance for `totalAssets()`. SafeVault keeps the inherited conversion formulas;
NaiveVault overrides both conversions to remove virtual assets and shares.
The offset cannot change after construction; values 19 through 255 revert with
`InvalidDecimalsOffset`.

The intended asset is this exact mock; constructors accept an `IERC20` for standard
ERC-4626 composition and do not validate that it is an 18-decimal mock. There are
no owners, managers, fees, strategies, oracles, pauses, upgrades, rescue methods,
or restricted depositors. Exit is synchronous, subject to assets represented by
the holder's shares and share allowance for delegated exits. All balances stay
in the vault; donations create no shares or redemption rights for the donor.

## Coverage

- Attack fuzzing with 1,024 runs per property, independent integer calculations,
  an explicit offset-6 boundary grid over `[0, 1e27]`, and zero-share thresholds.
- All supported offsets, invalid offsets, donations before and after the first
  deposit, residual assets after all real shares are redeemed, and reentry.
- Deposit/redeem floor rounding, mint/withdraw ceiling rounding, executed previews,
  all four entry/exit operations, share transfer and delegated exits.
- Insufficient asset balances/allowances, unauthorized and excessive exits,
  zero receivers with atomic rollback, and zero-value operations.
- Per-scenario conservation of assets and a reproducible 24-row measurement table.

The mock has no transfer fees, rebasing, callbacks, or adversarial transfer
behavior. These are outside the experiment's claims. The name `SafeVault` refers
to the bounded attack result, not a general security certification. Any release
for real funds requires separate independent adversarial review and a decision
on slippage protection and the actual underlying asset.
