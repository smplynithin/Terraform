# Terraform Revision Notes — 3 YOE DevOps

## 1. Core & Lifecycle
- IaC, declarative, provider-agnostic. HCL = `.tf` files (JSON-compatible).
- Lifecycle: **Write → Init → Validate → Plan → Apply → Destroy**
- `plan`/`apply` auto-refresh state against real infra before diffing.
- Providers = plugins talking to target APIs (AWS, Azure, GCP, K8s, Helm).

## 2. Block Types
| Block | Purpose |
|---|---|
| `terraform{}` | required_version, required_providers, backend |
| `provider{}` | region, alias, credentials |
| `resource "type" "name"{}` | managed infra object |
| `data "type" "name"{}` | read-only fetch |
| `variable "name"{}` | input param |
| `output "name"{}` | expose value |
| `locals{}` | internal reusable values |
| `module "name"{}` | call reusable child module |

## 3. CLI Commands
```
terraform init        # download providers/modules, setup backend
terraform validate    # syntax/config check, no API calls
terraform fmt -check  # format, CI gate
terraform plan -out=plan.tfplan
terraform apply -auto-approve | apply plan.tfplan
terraform destroy -target=<addr>
terraform output
terraform show
terraform console      # interactive expression evaluation (REPL) — often missed
```

## 4. Meta-Arguments
- `count` → index via `count.index`
- `for_each` → key via `each.key` / `each.value`
- `for_each` safer than `count` — avoids index-shift on reorder/removal
- `depends_on` → explicit dependency (prefer implicit via reference)

## 5. Lifecycle Block
- `create_before_destroy`, `prevent_destroy`, `ignore_changes = [attr]` / `all`
- `replace_triggered_by` — force replace on referenced value change
- `precondition{}` / `postcondition{}` (1.2+) — custom validation

## 6. Dependency Graph
- Terraform builds a DAG. Implicit (via reference, preferred) vs explicit (`depends_on`).
- `terraform graph` → DOT format, visualize with Graphviz.
- Graph decides parallel vs sequential execution order.

## 7. Variables / Outputs / Locals
- Types: string, number, bool, list, map, set, object, tuple, any
- Precedence (low→high): defaults < `TF_VAR_*` env < `.tfvars` < `auto.tfvars` < `-var-file` < `-var` (CLI wins)
- `sensitive = true` masks CLI output only — still plaintext in state.

## 8. Provider Config
- `alias` for multi-region/multi-account setups.
- `.terraform.lock.hcl` — locks exact provider versions, **commit this**.
- `default_tags` (AWS provider) — auto-tags all resources under that provider.

## 9. State Management
- `terraform.tfstate` = JSON map of config → real resource IDs/attrs.
- Local vs remote state — remote = team collaboration, single source of truth.
- **Never commit state to Git.** Sensitive values stored in plaintext — encrypt backend.

### State splitting strategy
- Per environment (dev/stage/prod) — blast-radius control.
- Per layer/module (network/platform/app) — smaller/faster plans, independent ownership.
- Trade-off: more state files = more cross-state lookups.
- Common key pattern: `env/component/terraform.tfstate`

## 10. Remote Backends
- **S3 + DynamoDB** (AWS): S3 = storage, DynamoDB = lock table.
- **New in TF 1.10+**: native S3 locking via `use_lockfile = true` — DynamoDB no longer mandatory (often missed in older notes).
- Azure: `azurerm` → Storage Account + Blob container.
- GCS backend (GCP), Terraform Cloud/Enterprise (built-in locking).
- Backend block: partial config allowed (`-backend-config=` at init); **cannot use variables/interpolation**.

## 11. Cross-State / Module Communication
- `terraform_remote_state` data source — reads another module's outputs (read-only).
- Modules don't talk to each other directly — root module wires them: `module.A.output_x` → input of `module "B"`.
- Use case: network team's VPC/subnet IDs consumed by app team.

## 12. Modules
```
root: module "vpc" { source = "./modules/vpc"; cidr = var.cidr }
root: module "ec2" { source = "./modules/ec2"; subnet_id = module.vpc.private_subnet_id }
```
- Registry/versioned source for shared org modules: `source`, `version`.

## 13. Workspaces vs Env Directories
- `terraform workspace new/list/select/show/delete`; `${terraform.workspace}` in config.
- Workspaces = light isolation only, shared backend config — **not** a substitute for full env separation.
- Separate env directories (`environments/dev`, `environments/prod`) — full isolation, own backend/tfvars/state, different approvers per env. Preferred in most companies for prod-grade separation. Trade-off: code duplication, mitigated by shared `modules/`.

## 14. Repo Structure (Common Pattern)
```
modules/            # reusable building blocks
environments/dev/   # main.tf, variables.tf, backend.tf, tfvars
environments/prod/  # isolated state/backend
global/             # account-level (IAM, DNS)
```

## 15. Data Sources
- Read-only fetch, no lifecycle management. e.g. `data "aws_ami"`, `data "aws_vpc"`.

## 16. Expressions & Functions
- Conditional: `condition ? true_val : false_val`
- `for` expression: `[for x in list : x.name]`
- `dynamic` blocks — generate nested blocks programmatically.
- Common fns: `lookup()`, `merge()`, `join()`, `split()`, `coalesce()`, `templatefile()`, `file()`, `jsonencode()`, `try()`, `element()`

## 17. Drift & Refresh
- Drift = real infra ≠ state (manual console change, external process).
- Detected via `plan` or `refresh`.
- `ignore_changes = [attr]` — silence expected drift (e.g. autoscaler-managed `desired_count`).
- `terraform apply -refresh-only` — sync state to reality without changing infra.

## 18. State Commands
```
terraform state list
terraform state show <addr>
terraform state mv <old> <new>   # rename/move, no destroy-recreate
terraform state rm <addr>        # stop tracking; infra stays
terraform state pull / push      # raw state backup/restore
```

## 19. Import / Taint / Replace / Moved (gap-filled)
- `terraform import <addr> <id>` — needs matching resource block written first; does **not** generate config.
- `taint` (deprecated) → `terraform apply -replace=<addr>`
- **Import block (1.5+)**: declarative import via `import { to = ..., id = ... }` in `.tf` — can generate config with `-generate-config-out`. Commonly missed vs CLI import.
- **`moved` block (1.5+)**: refactor-safe renames across resources/modules without state surgery — replaces manual `state mv` in code-reviewable form.

## 20. State Recovery & DR
- Always `terraform state pull > backup.tfstate` before risky ops.
- S3: enable bucket versioning — restore prior object version.
- No backup: rebuild via `terraform import` per resource (last resort).
- DR checklist: S3 versioning + SSE, DynamoDB PITR, cross-region replication, least-privilege IAM, documented import runbook, pre-change backup in CI/CD.

## 21. State Locking
- Prevents concurrent plan/apply corruption. Lock held for duration of run.
- `ACQUIRING STATE LOCK` error: check if another run is genuinely active → wait; if holder crashed, confirm with team → `terraform force-unlock <LOCK_ID>` only after confirming safe.

## 22. Provisioners
- `local-exec` / `remote-exec` — last resort, prefer native resources.
- Creation-time vs `when = destroy`.
- `connection{}` block — SSH/WinRM for remote-exec.

## 23. Secrets
- Never hardcode in `.tf` or commit `.tfvars` with secrets.
- Source from Vault, AWS SSM/Secrets Manager, Azure Key Vault.
- Pass via data source / `TF_VAR_*` env vars.
- `.gitignore`: `*.tfstate`, `*.tfvars`, `.terraform/`
- **Ephemeral resources/values (1.10+)**: values that never persist to state — gap most 3 YOE candidates miss when asked "how do you avoid secrets landing in state at all."

## 24. Tagging Strategy
- Consistent: Environment, Owner, Project, CostCenter, ManagedBy.
- `default_tags` (AWS provider) reduces per-resource repetition.

## 25. Testing & Validation (expanded)
- `terraform validate`, `fmt -check` (CI gate)
- `tflint` — linting, provider-specific rules
- `checkov` / `tfsec` — static security/compliance scanning
- `terraform plan -detailed-exitcode` (0=no change, 1=error, 2=changes)
- **`terraform test` (1.6+)** — native `.tftest.hcl` test framework, run/assert blocks — increasingly asked at 3 YOE level.
- **Infracost** — cost estimation on PRs, commonly paired with the fmt→validate→plan pipeline.

## 26. CI/CD Integration
- Pipeline: `fmt → validate → plan → manual approval → apply`
- Plan output posted as PR artifact/comment before apply.
- Separate service principal/IAM role per environment.
- **Atlantis** — self-hosted PR-driven plan/apply automation with locking, common in orgs not on Terraform Cloud.

## 27. Terraform Cloud/Enterprise
- Remote runs, VCS-driven workflow, built-in remote state + locking.
- Sentinel / OPA — policy-as-code gates before apply.
- Private module + provider registry, RBAC, run triggers.

## 28. Common Errors
- Provider version conflicts → pin versions, delete `.terraform` & re-init.
- Cyclic dependency → refactor implicit refs / `depends_on`.
- "Resource already exists" → import instead of recreate.

## 29. Best Practices
- Small, composable modules; remote state + locking always.
- Consistent naming/tagging; never edit state manually.
- Pin provider/module versions; review plan before every apply.
- Separate state per environment; least-privilege execution role.

---

# Top 15 Scenario-Based Interview Questions

**1. Two engineers ran `apply` at the same time and one got "Error acquiring state lock." What do you do?**
Check the lock error for LockID/Who/Operation/time. Confirm with the team whether the holding run is genuinely still in progress — if yes, wait. If the process crashed/was killed, confirm it's truly dead before running `terraform force-unlock <LOCK_ID>`. Never force-unlock blindly; root-cause it (pipeline killed mid-run, network drop, Ctrl+C) and fix the underlying trigger.

**2. Someone manually deleted a resource from the AWS console that Terraform manages. Next `plan` shows it will recreate it — is that safe?**
Depends on intent. If the deletion was accidental, let `plan`/`apply` recreate it. If it was a deliberate manual change you want to keep, either `terraform state rm` (if you truly want to stop tracking it) or re-import it and reconcile config to match reality, then handle drift with `ignore_changes` if that field will keep drifting legitimately.

**3. Your state file is corrupted and you have no S3 versioning enabled. How do you recover?**
Rebuild by writing resource blocks that match the real infra and running `terraform import` per resource — no shortcut. This is exactly why DR checklists mandate S3 versioning + periodic backup-restore testing before this ever happens in prod.

**4. You need to rename a resource in code (e.g., refactor `aws_instance.web` to `aws_instance.app_web`) without destroying and recreating it. How?**
Use `terraform state mv aws_instance.web aws_instance.app_web`, or in 1.5+ use a `moved` block in code so the refactor is reviewable and repeatable across environments instead of a manual one-off CLI operation.

**5. A resource's tags keep drifting because an autoscaler/Lambda updates them outside Terraform. `plan` always shows a diff. How do you handle it?**
Add `lifecycle { ignore_changes = [tags] }` (or the specific drifting attribute) on that resource so Terraform stops flagging expected external drift, while still managing everything else about the resource.

**6. You have 50 near-identical S3 buckets to create with slightly different names. `count` or `for_each`?**
`for_each` with a map/set — keyed by name/identifier, so removing one bucket from the middle of the list doesn't shift indices and force-recreate/reorder unrelated resources the way `count` would.

**7. How do you structure Terraform for dev/stage/prod so a bad `apply` in dev can never touch prod?**
Separate env directories, each with its own backend config and state file (not just `terraform.workspace` switching on one backend). Different IAM roles/service principals per environment, shared logic pulled from a common `modules/` folder to avoid duplication while keeping blast radius fully isolated.

**8. Your `plan` fails after a provider version bump with an unfamiliar error. First 3 steps?**
Read the exact error for the specific incompatible argument/resource. Check `.terraform.lock.hcl` and provider changelog for breaking changes. If needed, delete `.terraform/` and re-`init` to force clean re-resolution, then pin the provider version explicitly with `~>` until you can test the upgrade properly.

**9. How do you make sure secrets (DB password, API keys) never end up committed or exposed via `plan` output?**
Never hardcode in `.tf`; source from Vault/AWS Secrets Manager/SSM via data source, mark the variable `sensitive = true` to mask CLI/log output, and `.gitignore` any `.tfvars` holding secrets. Note `sensitive` only masks display — the value is still in state plaintext, so the backend itself (e.g., S3) must be encrypted too. For values that must never even touch state, use ephemeral resources (1.10+).

**10. Team X owns the VPC/network Terraform, Team Y owns the app layer and needs the private subnet ID. How do they share that without merging state or repos?**
Team Y's config uses a `terraform_remote_state` data source pointing at Team X's backend (read-only), pulling `module.vpc.private_subnet_id` as an output. Keeps both teams' state fully decoupled while allowing composition; requires Team Y to have read access to Team X's state backend.

**11. `apply` partially fails halfway through creating 10 resources. What's your next move?**
Don't panic-destroy. Run `terraform plan` again — Terraform's state now reflects what succeeded, and plan will show only the remaining diff to reconcile. Investigate the specific failure (quota limit, IAM permission, naming conflict) and fix root cause before re-running `apply`.

**12. How would you enforce that nobody can `apply` a change that violates your org's security/compliance policy (e.g., an open security group) before it reaches prod?**
Wire `checkov`/`tfsec` into the CI pipeline as a gate before `plan`/`apply` can proceed, and/or use Sentinel/OPA policy-as-code in Terraform Cloud/Enterprise to block non-compliant plans automatically — not just rely on manual PR review.

**13. Explain the trade-off between one giant Terraform state for the whole account vs many small state files per layer/env.**
One giant state = simpler mental model but huge blast radius (any bad apply can touch everything) and slow plans as the state grows. Many small states (per env, per layer like network/platform/app) = smaller/faster plans, independent team ownership, isolated blast radius — but adds complexity via more `terraform_remote_state` cross-lookups to wire outputs between them. Most prod orgs choose the split.

**14. A junior engineer wants to skip `plan` and go straight to `-auto-approve apply` in prod CI to save time. How do you push back?**
Explain `plan` is the only safety check before real infra changes apply — `-auto-approve` in prod removes the human review gate entirely. Keep `fmt → validate → plan → manual approval → apply` in prod pipelines; `-auto-approve` is acceptable only in ephemeral/dev/test environments with low blast radius, and even there `plan` output should still be visible in logs.

**15. How do you test a module before it's used across 5 different environments?**
Use `terraform test` (1.6+) with `.tftest.hcl` run/assert blocks to validate module behavior in isolation with mock/test inputs, plus `tflint`/`checkov` for static checks. Validate in a throwaway/dev environment first, pin the module version, and only bump the version constraint in prod environments after it's proven out — never point prod directly at an unpinned/`main` branch module source.
