# 06 — Money: funder, wallets, top-ups, reclaim, books

Written by #1b from its handoff, the books and the reclaim lists; DIR adds the funder-side details it owns. Cells marked PENDING fill in at the finish.
Everything here is devnet: tDVPN (6 decimals) and devnet SOL. No wallet keys, gate URLs or VM addresses appear here.

## 1. The money in one picture

```
funder wallet ──top-up (SOL + tDVPN)──▶ per-agent test wallets ──open channel / subscription──▶ program escrow
      ▲                                        │                                                     │
      └──────────── sweep (keep a reserve) ◀───┴──── withdraw User.balance ◀──── close + refund ◀──────┘
```

- **One funder.** The fleet's devnet funder wallet holds the tDVPN supply. It has no mnemonic: it exists only as a key
  file with a backup, and the mint authority is revoked. Lose the file and no more tDVPN can be made. The key never leaves
  the machine it lives on, and only DIR signs funder transactions.
- **One wallet per agent or rig.** Each product test lane (Windows, Linux, Mac, Android, node side, plan manager, tester)
  pays from its own wallet. Nothing ever asserts on a shared wallet's balance; tests check the accounts they created.
- **Every top-up is logged.** A top-up is one line in the ledger (time, agent, wallet, amount, tx prefix). The books match
  every funder transfer against that ledger (§4).

## 2. Program rules the money follows

These come from the program source, not from memory. They decide what can be reclaimed and when.

| Account | Who can close it | When | Where the money goes |
|---|---|---|---|
| Voucher channel (per GB) | the channel owner | `start_close_channel`, then `close_channel` after the 7200 s grace | unused escrow → owner's `User.balance`; rent → the stored rent recipient |
| Stream channel (per hour) | the channel owner | directly with `close_channel`; **it bills until closed**, so close it right after the session | same |
| Subscription | the owner at any time; anyone after expiry; the provider early only if the price is 0 | — | rent → the stored rent recipient |
| Plan | the provider | only after it is delisted (`status == 0`); open subscriptions do not block it | rent → rent recipient |
| Node / provider bond | the owner | close, then `withdraw_*_bond` after the 3600 s unbonding | bond → owner's token account |
| `User.balance` | the owner | `withdraw_user_balance` at any time | owner's token account |

Every close pins `rent_payer`/`rent_recipient` to the stored value (an `address =` constraint), and also the node, mint,
vault and owner. A close command must therefore name the exact stored accounts; a wrong one fails instead of paying the
wrong party.

## 3. The reclaim pipeline

Order per wallet: **read → close what is ready → wait out the timers → close the rest → withdraw → sweep.**

1. **Read (no writes).** `reclaim-cb33.mjs` reads every dvpn account type once (one `getProgramAccounts` per kind, a pause
   between kinds so the RPC gate's per-token cap is not hit) and keeps the rows that belong to the listed wallets. For each
   row it prints the state, the money in it and the exact commands: one column for the step to run now, one for each later
   step after its wait. `--after-final` marks wallets whose owner still has passes to run.
2. **Close.** Each wallet's owner runs its own rows (`reclaim-own.mjs` re-reads each account and takes the next step:
   start-close, close or close-subscription), with 7 s between transactions. The funder's rows are DIR's.
3. **Wait.** Voucher channels need the 7200 s grace after start-close; bonds need the 3600 s unbonding.
4. **Withdraw.** Refunds land in `User.balance`; `withdraw_user_balance` moves them to the wallet's token account
   (`reclaim-own.mjs` does this last unless `--no-withdraw`).
5. **Sweep.** `sweep-to-funder.mjs` sends tDVPN and SOL back to the funder, keeping a reserve (default 1 tDVPN and
   0.05 SOL). It is a dry run unless `--apply`.

**Sweep only after the wallet's last pass and its finish.** A wallet swept early cannot pay for its next connect (this
happened once to the Mac lane, bug M1B-05). The tester held its own sweep on 11-08 for the same reason until its final
check had run.

Reclaim lists are built from chain reads, never from a product's database: a rebuilt test VM once lost 16 channel rows,
and only the chain read found them (M1B-09).

## 4. The books

`books-cb33.mjs` (read-only) reconciles every fleet wallet over a time window:

- every transaction of each wallet **and its tDVPN token account** (top-ups credit the token account, not the wallet), classed
  from the dvpn program logs and balance changes: top-up, transfer in/out, open, redeem, close, refund, failed, other;
- every funder transfer matched to a ledger line by signature prefix; unmatched ones are listed and traced by hand;
- the open dvpn accounts per wallet at the end of the window.

The 11-07 run (window from 00:00Z): top-up 53, transfer-in 23, transfer-out 15, open 232, redeem 0, close 237, refund 24,
failed 0, other 78. All 22 ledger lines matched a transaction, and all 7 unmatched funder transfers were traced and closed
(top-ups from before the ledger started, an old fleet wallet, and a throwaway subscription-test wallet that was fully
returned).

## 5. Reclaim progress (11-08)

| Read | Rows | Notes |
|---|---|---|
| 05:58Z | 475 | 105 closed by the next read, 308 timers started, 62 not started, 23 held for final passes |
| post-final | 150 channels | e.g. one Windows lane 44 ready; Linux lanes waiting on their final passes; Mac stream channels closed; funder rows with DIR |

| final (B1) | PENDING | totals returned to the funder per wallet, filled in after the last sweep |

## 6. What the books found about billing

- **Prepay forfeit:** all 110 closed per-GB test channels redeemed the whole 1 GB prepay (1000 units) for 10–20 MB of use.
  Upstream issue #14, fix PR #29 (redeem only the metered amount; lab A/B 1,000,000 → 21,585 units). See `10-bugs.md`
  M1B-10.
- Per-hour channels redeemed 3–14 units each, exact by the channel's `stream_accrued`.

## 7. Money bugs

All in `docs/10-bugs.md` (prefix M1B). Short list: undefined rent recipient in reclaim commands (M1B-01), fill patch on a
closed account (M1B-02), two commands in one cell (M1B-03), RPC cap on back-to-back scans (M1B-04), early sweep (M1B-05),
racing sweeps (M1B-06), refund booked from the pre-close read (M1B-07), skipped withdraw (M1B-08), channels lost from a
rebuilt DB (M1B-09), prepay forfeit (M1B-10).
