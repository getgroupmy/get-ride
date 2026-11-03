# Lawful-request export (migration 0338)

## What it is

A way for get.ride to answer a **valid request from the authorities** — the
police (PDRM), MCMC, or a court order — about **one user**, by exporting the
data the platform **already lawfully holds** about that account.

It is **not** new tracking and collects nothing new. It only **reads** existing
rows and assembles them into a single document the owner can hand over. Nothing
in the subject's data is written or changed by an export.

## Who may use it

**Full admins only.** A lawful export discloses a whole account, so it is not a
sub-admin action. The server enforces this two ways: the RPC's write target is
left unmapped, so only a page `*` edit grant (a full admin) passes
`caller_admin_can_write`, and `caller_is_full_admin()` is required on top of
that. The admin screen (Admin › Security & integrations › Lawful-request
export) is shown and usable to full admins only.

## What it discloses

For the chosen subject, reading only existing data:

- **account** — the profile: name, phone, email, gender, date of birth,
  nationality, address, ID type and the **full ID number**, account code,
  status, and created / deleted timestamps.
- **sessions** — recent device / network rows (IP, ISP, platform, app version,
  times) with a total count.
- **trips** — rides as rider or as partner (status, service, pickup/drop, fare,
  times, the other party's id), capped at the 1000 most recent with a total.
- **payments** — wallet transactions (type, amount, ride, times), capped at
  1000 with a total, plus current wallet balances.
- **location_history** — stored location fixes (lat, lng, time), capped at the
  5000 most recent, with the total and the earliest / latest timestamps.
- **safety** — safety incidents the subject was involved in.
- **deletion** — any account-deletion requests and whether the account is
  deleted.
- **meta** — when it was generated, the subject, and the request details.

On screen any ID number is **masked to its last 4**. The full number is in the
**downloaded / copied** document only — that document is the lawful disclosure.

## Every export is logged

Each export writes two records (and nothing else that changes state):

- a row in the `lawful_requests` register — who asked, when, and the agency,
  officer, reference (case / warrant / report number) and legal basis; the
  register survives the account if it is later deleted;
- an `admin_audit_log` row (`lawful_export`) carrying identifiers only — never
  the exported data itself.

The register is shown on the screen as the audit trail (`admin_lawful_requests`)
and is readable only through that full-admin RPC, never by a client directly.
