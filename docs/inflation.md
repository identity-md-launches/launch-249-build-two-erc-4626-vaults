# Measuring the first-depositor donation attack

This experiment compares a deliberately naive ERC-4626 vault with the virtual
asset/share formulas in [OpenZeppelin Contracts v5.0.2](https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v5.0.2/contracts/token/ERC20/extensions/ERC4626.sol).
The [OpenZeppelin explanation](https://docs.openzeppelin.com/contracts/5.x/erc4626)
provides background; the measurements below come from executing this repository's
contracts in Foundry, and the integer bound below is derived for this scenario.

## Scope and accounting

Each row starts with a fresh, empty vault over the same mock token. The ordered
actions are:

1. The attacker deposits **1 wei** of the asset, receiving all real shares.
2. The attacker transfers **D wei** directly to the vault, receiving no new shares.
3. One victim deposits **V wei** at the manipulated exchange rate.
4. The attacker redeems all attacker shares.
5. To measure realized loss, the victim redeems all victim shares after the attacker.

All amounts in the table are exact integer **asset wei**; `1e18` wei is one mock
token. Attacker profit is redemption proceeds minus **`1 + D`**, so negative
profit is an attacker loss. Victim loss is **`V - victim redemption proceeds`**.
No gas, financing, MEV fees, yield, or external token value is included. This is
an isolated deterministic transaction sequence, with no other shareholders or
intervening operations. Inputs for the requested bound are `0 <= D,V <= 1e27`.
Each fuzz property runs 1,024 cases; fuzzing samples the domain, while the algebra
below covers every integer pair under the stated assumptions.

Virtual shares/assets are conversion terms, not minted tokens. No address owns
them. There may be assets left after all real shares are redeemed. Every run
checks:

```text
1 + D + V = attacker proceeds + victim proceeds + residual vault balance
victim loss - attacker profit = residual vault balance
```

## Exact conversion and attack formulas

Let `A` be the actual token balance, `S` the real share supply, and `k = 10**offset`.

| Vault | Assets to shares | Shares to assets |
| --- | --- | --- |
| NaiveVault, `S > 0` | `assets * S / A` | `shares * A / S` |
| NaiveVault, `S = 0` | `assets` | `shares` |
| SafeVault | `assets * (S + k) / (A + 1)` | `shares * (A + 1) / (S + k)` |

`convertToShares`, `convertToAssets`, `previewDeposit`/`deposit`, and
`previewRedeem`/`redeem` round down. `previewMint`/`mint` and
`previewWithdraw`/`withdraw` round up. Products use OpenZeppelin's full-precision
`Math.mulDiv`. Deposits and mints price before transferring assets; exits burn
shares and transfer assets using the inherited ERC-4626 methods.

For NaiveVault, the attacker receives one share. Victim shares are
`q = floor(V / (D + 1))` and attacker proceeds are
`R = floor((D + 1 + V) / (1 + q))`. Thus `V <= D` gives **zero victim shares**,
`R = D + 1 + V`, and **profit = victim loss = V**. A positive victim deposit is
needed for positive profit. The adjacent boundary `V = D + 1` gives one victim
share and zero attacker profit. With zero share supply, NaiveVault resets to 1:1
even if donations remain, allowing the next depositor to capture those assets.

For SafeVault, the seed produces `k` real shares. Put `B = D + 2`; the extra two
are the seed asset and the virtual asset. Then:

```text
q = floor(2*k*V / B)
R = floor(k*(B + V) / (2*k + q))
W = floor(q*(B + V - R) / (k + q))
attacker profit = R - (D + 1)
victim loss = V - W
```

`W` is the victim's actual redemption after the attacker exits. In particular,
SafeVault with offset 0 still has virtual assets/shares and differs from
NaiveVault.

### Why the attacker cannot profit in this scenario

Because `q = floor(2*k*V/B)`, we have `V < (q + 1)*B/(2*k)`. Let `t = 2*k + q`.
For every supported offset, `k >= 1`, hence `t >= 2`. Therefore:

```text
k*(B + V) / t < B*(t + 1)/(2*t) <= 3*B/4 < B
R < B
R <= B - 1 = D + 1                    (R and B are integers)
attacker profit <= 0
```

This covers **all D and V through 1e27 with offset 6**, including zero inputs and
endpoints, and also applies to offsets 0 through 18 in this exact sequence. The
specified range fits comfortably in the contracts' arithmetic. The independent
test model's largest products are below `2**256` even at offset 18.

A larger offset reduces share-rounding loss and raises the donation needed to
force zero victim shares. The exact zero-share condition is
`2*k*V < D + 2`, or for integer inputs **`D >= 2*k*V - 1`**. For offset 6 and
`V = 1e18`, the first zero-share donation is `2e24 - 1`; the test exercises this
and the preceding value. This does not prevent griefing: the victim can lose its
entire deposit while the attacker incurs an even larger loss.

## Measured table

These 24 rows are printed by `testPrintInflationTable` in
[`test/Inflation.t.sol`](../test/Inflation.t.sol). Six rows are the naive baseline;
the other eighteen cover SafeVault offsets 0, 3, and 6. No rounded decimal display
or floating-point calculation is used.

<!-- BEGIN MEASURED TABLE -->
| Vault | Offset | D (wei) | V (wei) | Attacker profit (wei) | Victim loss (wei) |
| --- | ---: | ---: | ---: | ---: | ---: |
| NaiveVault | n/a | 1000000000000000000 | 1000000000000000000 | 1000000000000000000 | 1000000000000000000 |
| SafeVault | 0 | 1000000000000000000 | 1000000000000000000 | -333333333333333334 | 333333333333333333 |
| SafeVault | 3 | 1000000000000000000 | 1000000000000000000 | -499874968742185547 | 250062515628907 |
| SafeVault | 6 | 1000000000000000000 | 1000000000000000000 | -499999874999968751 | 250000062499 |
| NaiveVault | n/a | 1000000000000000000 | 100000000000000000000 | 9999999999999999 | 9999999999999999 |
| SafeVault | 0 | 1000000000000000000 | 100000000000000000000 | -497512437810945275 | 4975124378109451 |
| SafeVault | 3 | 1000000000000000000 | 100000000000000000000 | -499997524740221488 | 4950519557025 |
| SafeVault | 6 | 1000000000000000000 | 100000000000000000000 | -499999997524752464 | 4950495073 |
| NaiveVault | n/a | 1000000000000000000000 | 1000000000000000000 | 1000000000000000000 | 1000000000000000000 |
| SafeVault | 0 | 1000000000000000000000 | 1000000000000000000 | -499500000000000000000 | 1000000000000000000 |
| SafeVault | 3 | 1000000000000000000000 | 1000000000000000000 | -499750124937531234383 | 499750124937531235 |
| SafeVault | 6 | 1000000000000000000000 | 1000000000000000000 | -499999750249625499314 | 499500749001374 |
| NaiveVault | n/a | 1000000000000000000000 | 100000000000000000000 | 100000000000000000000 | 100000000000000000000 |
| SafeVault | 0 | 1000000000000000000000 | 100000000000000000000 | -450000000000000000000 | 100000000000000000000 |
| SafeVault | 3 | 1000000000000000000000 | 100000000000000000000 | -499772623919963619828 | 454752160072760346 |
| SafeVault | 6 | 1000000000000000000000 | 100000000000000000000 | -499999772727169421441 | 454545661157119 |
| NaiveVault | n/a | 1000000000000000000000000 | 1000000000000000000 | 1000000000000000000 | 1000000000000000000 |
| SafeVault | 0 | 1000000000000000000000000 | 1000000000000000000 | -499999500000000000000000 | 1000000000000000000 |
| SafeVault | 3 | 1000000000000000000000000 | 1000000000000000000 | -499999500000000000000000 | 1000000000000000000 |
| SafeVault | 6 | 1000000000000000000000000 | 1000000000000000000 | -499999750000124999937501 | 499999750000125000 |
| NaiveVault | n/a | 1000000000000000000000000 | 100000000000000000000 | 100000000000000000000 | 100000000000000000000 |
| SafeVault | 0 | 1000000000000000000000000 | 100000000000000000000 | -499950000000000000000000 | 100000000000000000000 |
| SafeVault | 3 | 1000000000000000000000000 | 100000000000000000000 | -499950000000000000000000 | 100000000000000000000 |
| SafeVault | 6 | 1000000000000000000000000 | 100000000000000000000 | -499999750024872525183745 | 499950254949632512 |
<!-- END MEASURED TABLE -->

For example, at `D = V = 1e18`, the naive attacker steals the whole victim deposit.
With SafeVault offset 6, the attacker loses `499999874999968751` wei and the victim
loses `250000062499` wei. At `D = 1e24` and `V = 1e18`, even offset 6 leaves a
victim loss close to half its deposit. Nonpositive attacker profit is a distinct
claim from negligible victim loss.

Reproduce or check the table with:

```sh
forge test --match-test testPrintInflationTable -vv
python3 script/inflation_table.py          # compare printed rows with this document
python3 script/inflation_table.py --write  # regenerate the measured block
```

The helper fails on a test failure, missing rows, or a stale table. The Foundry
test also checks the independent formulas and conservation before printing each
row. The full suite separately fuzzes the naive exploit and offset-6
nonprofitability, fuzzes all supported offsets, and checks a 64-case grid of zero,
small, large, and upper-bound D/V values.

## Assumptions and operational responsibilities

- The asset is the supplied standard, 18-decimal mock with unrestricted minting.
  It has no fees, rebasing, hooks, or malicious callbacks. This mock is unsuitable
  as an economically scarce production asset. Asset compatibility is the
  deployer's responsibility; the constructors do not enforce these assumptions.
- Construction requires the mock address for both vaults and a `uint8` offset
  for SafeVault. Select **6** for the recommended experiment configuration; the
  resulting shares have 24 decimals. All offsets 0 through 18 are accepted and
  immutable; larger values revert. The compiler targets Cancun, so any future
  deployment venue must support that EVM version. Nothing was deployed here.
- There is no administrator, fee collector, strategy, oracle, pause, cap, upgrade,
  sweep, or rescue authority. Anyone can deposit/mint or donate; only share owners
  and approved spenders can withdraw/redeem their claims. Donated funds are included
  immediately in the share exchange rate, without a settlement delay.
- Integrators must use the correct share decimals and understand that the standard
  ERC-4626 methods have no `minShares`/`minAssets` or deadline parameters. A preview
  is only a current-state quote. An integration handling real value needs atomic
  slippage checks, including a rejection of unexpectedly zero shares; these vaults
  intentionally preserve the standard behavior to reproduce the attack.
- Residual assets remain in the contract and affect later conversions, including
  after real supply reaches zero. They are not paid to an operator or automatically
  refunded. There is no assumed yield source; reported gains/losses are token
  transfers and rounding effects in this sequence.
- The proof fixes the attacker seed at one wei, a fresh vault, one victim, one
  donation, and attacker-first redemption. It is not a claim about repeated victims,
  different seeds, arbitrary transaction sequences, manipulated external prices,
  or arbitrary underlying tokens. Repeated victims can change attack economics.
  NaiveVault is intentionally exploitable; SafeVault is an experimental name, not
  a security audit. Independent adversarial review is a release responsibility
  before either design is adapted to hold real funds.
