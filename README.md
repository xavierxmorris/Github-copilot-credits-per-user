# Github-copilot-credits-per-user

A small PowerShell tool that reports **net money + AI credit count per user** for GitHub Copilot in a given month, aggregated across **all models** each user used — at **organization**, **enterprise**, or **personal** scope.

Since GitHub moved Copilot to [usage-based billing](https://github.blog/changelog/2026-06-01-updates-to-github-copilot-billing-and-plans/) on **June 1, 2026**, usage is metered in **GitHub AI Credits** (1 credit = $0.01 USD). This script pulls per-user usage from the billing API and rolls it up into one row per person.

## What it reports

One row per user:

| Column      | Meaning                                                        |
| ----------- | ------------------------------------------------------------- |
| `User`      | GitHub login                                                  |
| `NetUSD`    | Net spend in USD for the month (sum of `netAmount`)           |
| `AICredits` | Net AI credits (`NetUSD x 100`, since 1 credit = $0.01)       |
| `Models`    | Distinct models the user consumed credits on                 |

…plus a grand total across all users.

```
User  NetUSD AICredits Models
----  ------ --------- ------
alice  42.18      4218 Claude Sonnet 4.6, GPT-5.5
bob    11.07      1107 GPT-5.4
TOTAL  net $53.25 USD  =  5,325 AI credits   (2026-06)
```

## Requirements

- [GitHub CLI](https://cli.github.com/) (`gh`), authenticated: `gh auth login`
- PowerShell 5.1+ (Windows PowerShell or PowerShell 7+)
- Billing access at the scope you query:
  - **Org**: organization owner or billing manager
  - **Enterprise**: enterprise admin or billing manager
  - **Self**: the authenticated user (needs the `user` OAuth scope — run `gh auth refresh -h github.com -s user` once)

## Usage

```powershell
# Organization: every current Copilot seat, this month
./Get-CopilotCreditsPerUser.ps1 -Org my-org

# Enterprise: a specific month, exported to CSV
./Get-CopilotCreditsPerUser.ps1 -Enterprise my-ent -Year 2026 -Month 6 -CsvPath .\ent-june.csv

# Specific users only (skips seat enumeration; use for closed months or enterprises)
./Get-CopilotCreditsPerUser.ps1 -Org my-org -Users alice,bob

# Personal: just the authenticated user's own Copilot usage
./Get-CopilotCreditsPerUser.ps1 -Self
```

### Scope (choose exactly one)

| Parameter      | Scope        | Notes                                                       |
| -------------- | ------------ | ----------------------------------------------------------- |
| `-Org`         | Organization | Aggregates every user with a Copilot seat in the org        |
| `-Enterprise`  | Enterprise   | Aggregates every user with a Copilot seat in the enterprise |
| `-Self`        | Personal     | Only the authenticated user's personal Copilot usage        |

### Common parameters

| Parameter  | Default       | Notes                                                                  |
| ---------- | ------------- | ---------------------------------------------------------------------- |
| `-Year`    | current year  | Four-digit year                                                        |
| `-Month`   | current month | 1–12                                                                   |
| `-Users`   | (auto)        | Explicit list (Org/Enterprise only); otherwise current seats are used  |
| `-CsvPath` | —             | If set, writes the table to CSV                                        |

## How it works

1. Resolves the user list from the seats endpoint (`/orgs/{org}/copilot/billing/seats` or `/enterprises/{ent}/copilot/billing/seats`), or uses `-Users`. `-Self` skips this — the personal endpoint is already user-scoped.
2. For each user, calls the AI-credit usage endpoint for the chosen scope and sums `netAmount` across every line item (all models):
   - Org: `/organizations/{org}/settings/billing/ai_credit/usage?user=…&year=…&month=…`
   - Enterprise: `/enterprises/{ent}/settings/billing/ai_credit/usage?user=…&year=…&month=…`
   - Self: `/users/{me}/settings/billing/ai_credit/usage?year=…&month=…`
3. Converts to credits (`USD x 100`) and prints a per-user table + total.

Failed lookups are reported and **excluded** from the total (never silently counted as `$0`), with a final failure count.

## Notes & caveats

- **USD denomination (verified).** Billing line items satisfy `grossAmount = grossQuantity × pricePerUnit`, amounts are in USD, and `unitType` is the native unit (tokens, minutes, etc.). So `AICredits = NetUSD × 100` is correct. (Confirmed against live billing data.)
- **Current seats only.** Auto-discovery finds users who hold a Copilot seat *now*. For a closed month, pass `-Users` to include anyone who has since lost their seat.
- **Query at the billing owner's scope.** If a user's Copilot license is managed and billed by an org or enterprise, their usage appears only at *that* scope — not on their personal (`-Self`) account. Run the script against the scope that actually pays for the seat.
- **No raw token counts.** The billing API exposes AI credits / dollars, not token counts. Tokens are converted to credits before they reach the API, so per-user token totals are not recoverable from billing data alone.

## License

MIT
