# Github-copilot-credits-per-user

A small PowerShell tool that reports **net money + AI credit count per user** for GitHub Copilot in a given month, aggregated across **all models** each user used.

Since GitHub moved Copilot to [usage-based billing](https://github.blog/changelog/2026-06-01-updates-to-github-copilot-billing-and-plans/) on **June 1, 2026**, usage is metered in **GitHub AI Credits** (1 credit = $0.01 USD). This script pulls per-user usage from the billing API and rolls it up into one row per person.

## What it reports

One row per Copilot user:

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
- Billing access to the org (org owner or billing manager). The billing endpoints require a **classic** PAT scope if you authenticate with a token directly; `gh auth login` works for interactive use.

## Usage

```powershell
# Current month, all current Copilot users in the org
./Get-CopilotCreditsPerUser.ps1 -Org my-org

# A specific month, exported to CSV
./Get-CopilotCreditsPerUser.ps1 -Org my-org -Year 2026 -Month 6 -CsvPath .\copilot-june.csv

# Only specific users (skips seat enumeration; use this for closed months)
./Get-CopilotCreditsPerUser.ps1 -Org my-org -Users alice,bob
```

### Parameters

| Parameter  | Required | Default       | Notes                                                     |
| ---------- | -------- | ------------- | --------------------------------------------------------- |
| `-Org`     | yes      | —             | Organization login                                        |
| `-Year`    | no       | current year  | Four-digit year                                           |
| `-Month`   | no       | current month | 1–12                                                      |
| `-Users`   | no       | (auto)        | Explicit list; otherwise current Copilot seats are listed |
| `-CsvPath` | no       | —             | If set, writes the table to CSV                           |

## How it works

1. Resolves the user list from `GET /orgs/{org}/copilot/billing/seats` (or `-Users`).
2. For each user, calls `GET /organizations/{org}/settings/billing/ai_credit/usage?user=…&year=…&month=…` and sums `netAmount` across every line item (all models).
3. Converts to credits (`USD x 100`) and prints a per-user table + total.

Failed lookups are reported and **excluded** from the total (never silently counted as `$0`).

## Caveats

- **Current seats only.** Auto-discovery finds users who hold a Copilot seat *now*. For a closed month, pass `-Users` to include anyone who has since lost their seat.
- **No raw token counts.** The billing API exposes AI credits / dollars, not token counts. Tokens are converted to credits before they reach the API, so per-user token totals are not recoverable from billing data alone.
- **Denomination check.** The script assumes `netAmount` is USD. If a usage row shows `pricePerUnit ≈ 0.01`, the API is already returning credits — swap the two columns.

## License

MIT
