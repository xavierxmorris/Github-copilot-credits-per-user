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
- Billing access at the scope you query (see below)

## Scope & access — pick exactly one target

| Parameter      | Scope        | Who can run it                       | Billing endpoint |
| -------------- | ------------ | ------------------------------------ | ---------------- |
| `-Org`         | Organization | Org owner / billing manager          | `/organizations/{org}/settings/billing/ai_credit/usage` |
| `-Enterprise`  | Enterprise   | Enterprise admin / billing manager   | `/enterprises/{ent}/settings/billing/ai_credit/usage` |
| `-Self`        | Personal     | The authenticated user (`user` scope)| `/users/{me}/settings/billing/ai_credit/usage` |

For `-Self`, grant the scope once: `gh auth refresh -h github.com -s user`.

### Personal vs. enterprise-managed users — important

A user's Copilot usage is visible **only at the scope that pays for their seat**:

- **Personal plan** (the user bought their own Copilot): use `-Self`, or `-Org/-Enterprise -Users <login>` is *not* applicable — their usage lives on `/users/{login}/...`.
- **Enterprise-managed / org-managed** (the seat is billed by an org or enterprise): the user's usage does **not** appear on their personal `-Self` account. It is billed to the owning org/enterprise, so query that scope with billing access:
  - `-Org <org> -Users <login>`
  - `-Enterprise <slug> -Users <login>`

If you run `-Self` and get `$0` with a warning, your seat is almost certainly managed by an org/enterprise — ask a billing manager there to run the org/enterprise query.

> **Note:** GitHub exposes **no enterprise-wide Copilot seats endpoint** (only `/orgs/{org}/copilot/billing/seats`). So `-Enterprise` requires either `-Users` (explicit logins) or `-Organizations` (member orgs whose seats are enumerated).

## Usage

```powershell
# Organization: every current Copilot seat, this month
./Get-CopilotCreditsPerUser.ps1 -Org my-org

# Organization: specific users, exported to CSV
./Get-CopilotCreditsPerUser.ps1 -Org my-org -Users alice,bob -CsvPath .\june.csv

# Enterprise: explicit users
./Get-CopilotCreditsPerUser.ps1 -Enterprise my-ent -Users alice,bob -Year 2026 -Month 6

# Enterprise: enumerate seats across member orgs, then bill via the enterprise endpoint
./Get-CopilotCreditsPerUser.ps1 -Enterprise my-ent -Organizations team-a,team-b

# Personal: the authenticated user's own Copilot usage
./Get-CopilotCreditsPerUser.ps1 -Self
```

### Parameters

| Parameter        | Applies to        | Default       | Notes                                                             |
| ---------------- | ----------------- | ------------- | ----------------------------------------------------------------- |
| `-Org`           | Org scope         | —             | Organization login                                                |
| `-Enterprise`    | Enterprise scope  | —             | Enterprise **slug**                                               |
| `-Self`          | Personal scope    | —             | Authenticated user's own usage                                    |
| `-Year`          | all               | current year  | Four-digit year                                                   |
| `-Month`         | all               | current month | 1–12                                                              |
| `-Users`         | Org, Enterprise   | (auto for Org)| Explicit logins; required for Enterprise unless `-Organizations`  |
| `-Organizations` | Enterprise        | —             | Member orgs to **discover users from** (seats enumerated per org) |
| `-Product`       | all               | —             | Optional `product` filter passed to the usage API                 |
| `-CsvPath`       | all               | —             | If set, writes the table to CSV                                   |

## How it works

1. **Resolve users.**
   - `-Org`: list seats via `/orgs/{org}/copilot/billing/seats` (or `-Users`).
   - `-Enterprise`: from `-Users`, or enumerate seats of each `-Organizations` member org.
   - `-Self`: skipped — the personal endpoint is already user-scoped.
2. **Fetch usage** per user from the scope's `ai_credit/usage` endpoint and sum `netAmount` across every line item (all models).
3. **Convert** to credits (`USD x 100`) and print a per-user table + total.
4. **Reconcile** (Org / Enterprise): re-query the scope without `?user=` to get the aggregate total and report any **unattributed** usage. When auto-discovering users, a non-zero gap warns that the user list is incomplete (e.g. seats removed mid-month).

Failed lookups are reported and **excluded** from the total (never silently counted as `$0`), with a final failure count.

## Notes & caveats

- **USD denomination (verified live).** Billing line items satisfy `grossAmount = grossQuantity × pricePerUnit`, amounts are in USD, and `unitType` is the native unit (tokens, minutes, etc.). So `AICredits = NetUSD × 100` is correct.
- **Current seats only.** Auto-discovery (Org / Enterprise `-Organizations`) finds users who hold a Copilot seat *now*. For a closed month, pass `-Users` to include anyone who has since lost their seat — the reconciliation line flags any unattributed spend if you don't.
- **`-Organizations` is a discovery source, not a report filter.** It lists each named org's seats to build the user set; the enterprise usage endpoint then reports each user's *full enterprise* usage (not limited to those orgs).
- **Usage items not paginated.** The usage endpoints document no `page`/`per_page` params and return an aggregate report, so all `usageItems` are read from a single response.
- **No raw token counts.** The billing API exposes AI credits / dollars, not token counts. Tokens are converted to credits before they reach the API, so per-user token totals are not recoverable from billing data alone.

## License

MIT
