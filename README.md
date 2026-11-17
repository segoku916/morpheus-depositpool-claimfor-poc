# Morpheus — DepositPool claimFor receiver bypass destroys lock multiplier (PoC)

Foundry proof of concept for a Morpheus bug bounty report. `claimFor` skips the
`claimSender` check entirely when a `claimReceiver` is set, so any address can
force-claim for that staker; `_claim` then unconditionally resets the lock,
destroying the victim's lock multiplier and diverting a share of their future
MOR emissions to everyone else (including the attacker).

- **Target:** stETH DepositPool `0x47176B2Af9885dC6C4575d4eFd63895f7Aaa4790`
  (Ethereum, Appendix A)
- **Fork:** Ethereum mainnet, pinned to block **26434871**
- **Result:** victim share 43.8% → 9.5% of the pool tranche; victim loses
  897.9 MOR/day (~$634/day at $0.7058/MOR); attack cost ~$1.07. Even an
  immediate re-lock only recovers to 3.04x (from 7.42x) — a permanent ~59%
  multiplier loss. No privileged accounts are used.

## Run (one command, from a clean clone)

```sh
forge test
```

Requires [Foundry](https://getfoundry.sh/) (forge 1.9+). `forge-std` is vendored
under `lib/`, so no install step is needed. The fork RPC is
`https://eth.drpc.org`.

## What the test asserts

`test_ForcedClaimViaReceiverResetsMultiplier` — a stranger with no
`claimSender` delegation force-claims a 1,000-stETH victim (5-year lock, 7.42x)
who set a claim receiver. It asserts the victim's `claimLockStart`/`claimLockEnd`
are zeroed, virtual deposits collapse to 1x while the deposit is untouched, the
victim's tranche share collapses to under a third of its pre-attack value while
the attacker's share rises, and an immediate re-lock cannot recover the old
multiplier.

Harness note (documented in the test header): Chainlink reads are mocked to
their pinned-block values (warps would stale them); one day of Lido rebase
yield is simulated per tranche as a small stETH donation to the Distributor.
