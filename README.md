# IMDPot (IMDPOT)

A fixed-supply ERC-20 token for an IMD custom-token launch on Ethereum (chain id 1).

| Property | Value |
| --- | --- |
| Solidity contract | `IMDPotToken` (`src/IMDPotToken.sol`) |
| `name()` | `IMDPot` |
| `symbol()` | `IMDPOT` |
| `decimals()` | `18` |
| `totalSupply()` | `1000000000000000000000000000` (1,000,000,000 × 10^18) |
| Constructor arguments | none |
| Compiler | solc 0.8.26, optimizer 200 runs, `bytecode_hash = "none"` |

## Behaviour

- The constructor mints the whole supply once to `msg.sender`. On the launch that is the IMD
  factory, which pays it out (10% to the swarm's MerkleDistributor, 80% to the pool seed, the rest
  to the requester's `remainderTo`).
- Standard ERC-20 `transfer`, `approve`, `transferFrom`, `allowance`, `balanceOf`. An allowance of
  `type(uint256).max` is treated as unlimited and is not decreased.
- Errors follow ERC-6093 naming (`ERC20InsufficientBalance`, `ERC20InsufficientAllowance`,
  `ERC20InvalidReceiver`, `ERC20InvalidSpender`). Transfers to the zero address revert; zero-value
  transfers succeed.
- **No fees, taxes, burns or transfer hooks**: every transfer moves exactly the named amount, so the
  factory → distributor, distributor → claimant, pool seed and swaps all arrive whole.
- **No owner or admin powers**: no mint, burn, pause, blacklist, freeze or upgrade. The supply can
  never change after deployment, and nobody but a holder (or a spender they approved) can move
  their balance.
- No external calls, no `DELEGATECALL`/`SELFDESTRUCT`, no libraries to link.

## Assumptions

- The brief fixes name, symbol, supply and decimals; it asks for no other token mechanics, so none
  were added. There are no open numbers, fees or outside addresses to configure.
- The launch's pool, fee, price and economics (pair IMD, fee 12500, tick spacing 60, poolBps 8000,
  remainderTo `0x6bf192ebef135e0f645e99d59d9bf44e7711606c`) are applied by IMD's factory and
  manifest step, not by this contract. No `launch.json` is included; the manifest step writes it.

## Deployment

On the launch, IMD's factory deploys `IMDPotToken` from its creation code with no constructor
arguments. `script/Deploy.s.sol` (`DeployIMDPot`) exists only for local/test-network use; its
`deploy()` function is what the tests call. This repository holds no keys and broadcasts nothing.

## After launch

Nothing to configure: the token has no owner and no settings.

## Operational responsibilities

- The factory (IMD) distributes the minted supply at launch.
- After launch there is no operator; holders are solely responsible for their own keys.
- Tests passing are not a security audit. An independent review is recommended before release.

## Development

```sh
forge build
forge test
forge fmt --check
```

`forge-std` is vendored under `lib/forge-std` (used only by tests and the script).
