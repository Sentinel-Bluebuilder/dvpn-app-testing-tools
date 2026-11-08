# tools/money — top-ups, reclaim, books

How the fleet kept every test wallet funded and got the money back. Background and rules: `docs/06-money.md`.
Devnet only. Nothing here holds a key, a real wallet address or a host: every value comes from env or a file
outside the repo.

| Tool | What it does | Writes on chain? |
|---|---|---|
| `sol-topup.sh` | Tops every wallet in the list up to its target when it drops under its minimum, from the funder. Stops if the funder is under its reserve. One ledger line per funded wallet. | yes (`APPLY=1`); dry run by default |
| `money.sh list` | Reclaim list: every dvpn account the listed wallets hold, its state, its money, and the exact close commands ("run now" + the later steps after their waits). | no |
| `reclaim-run.sh` | Runs one wallet's "run now" cells from that list through the `sentinel-dvpn` CLI, 7 s apart (for a wallet whose key lives in the CLI home, e.g. the funder). | yes (`APPLY=1`); dry run by default |
| `money.sh own` | For a wallet with a key file: re-reads each listed account and takes its next step (start-close, close, close-subscription), then withdraws `User.balance`. | yes (unless `--dry-run`) |
| `money.sh sweep` | Sends tDVPN then SOL back to the funder, keeping a reserve (default 1 tDVPN + 0.05 SOL). | yes (`--apply`); dry run by default |
| `money.sh books` | Books: every tx of every wallet and its token account, classed (top-up, open, close, refund, …), top-ups matched to the ledger, open accounts at the end. | no |

`money.sh` runs the logic from the public Node Tester for Solana (`scripts/ops/*.mjs`), which carries the account decoder
and the IDL. Set `TESTER_DIR` to a checkout of it with `npm ci` done.

## Setup

```sh
export TESTER_DIR=/path/to/sentinel-solana-node-tester
export FUNDER_PUBKEY=<funder public key>
export MINT=<tDVPN mint>
export WALLET_LIST=/path/outside/repo/wallets.txt   # format: wallets.example.txt
export LEDGER=/path/outside/repo/ledger.md
export SOLANA_RPC_URLS=<your devnet RPC>,https://api.devnet.solana.com
# sol-topup only, on the machine that holds the funder key:
export FUNDER_KEYFILE=/path/outside/repo/funder.json
```

## The reclaim pipeline

One wallet at a time, 7 s between transactions, never two runs on one wallet at once:

1. `money.sh list > reclaim.md` (read-only; `--after-final <labels>` marks wallets whose owner still has passes to run).
2. Run the "run now" steps: `money.sh own --channels … < key.json`, or `APPLY=1 reclaim-run.sh reclaim.md <label>`.
3. Wait: voucher channels 7200 s after start-close; node/provider bonds 3600 s after close.
4. `money.sh list` again and run the new "run now" steps (the closes).
5. Withdraw (`money.sh own` does it at the end).
6. `money.sh sweep < key.json` (dry run), check it, then `--apply`.

**Sweep a wallet only after its owner's last pass and its finish.** A wallet swept early cannot pay for its next
connect.

## Lessons kept in the code

- **Field 9, never field 10.** In the reclaim table (`awk -F'|'`), field 9 is "run now" and field 10 is "then, in order".
  Field 10 carries the wait in front of each command, e.g. "(after 7200 s) `…`"; sending it to the CLI fails with
  `unknown command "(after"`. A field 9 cell can also end in a note ("(as <label>, after its channels close)"),
  which failed as `unknown command "(as"`. `reclaim-run.sh` executes field 9 only, cuts any trailing note, and skips any
  cell that is not a command. After the wait, regenerate the list rather than running field 10.
- **One command per cell.** An earlier list put both steps in one cell, which could not be pasted and run safely.
- **The rent field is `rentRecipient`.** The cb33 IDL renamed `rent_payer` to `rent_recipient`; reading the old name
  printed `undefined` into every close command. Every close pins the stored rent recipient, so a wrong value fails.
- **Pause between account scans** (`--gap-ms 8000`): back-to-back `getProgramAccounts` calls hit a per-token RPC cap and
  one account type came back empty.
- **Build the list from the chain,** never from a tool's database: a rebuilt test VM once lost 16 channel rows.
- **Top-ups credit the token account,** not the wallet: the books scan both.
