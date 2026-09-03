# Terraform Revision — DevOps Engineer (3-4 YoE Level)

## 1. Core & Architecture

**Terraform** — HashiCorp's declarative, provider-agnostic IaC tool. You describe desired end-state; Terraform figures out the diff and applies it.

**Lifecycle**: Write → Init → Validate → Plan → Apply → Destroy. `plan`/`apply` silently do a state **refresh** first (compares real infra vs recorded state).

**Real-time example**: At HCL, if you provision an EKS cluster + node group + VPC via Terraform, a teammate manually resizing the node group in AWS console causes drift — next `plan` shows a diff even though you changed nothing in code.

## 2. Block Types

- `terraform{}` — required_version, required_providers, backend config
- `provider{}` — region, alias, credentials
- `resource "type" "name" {}` — a managed object
- `data "type" "name" {}` — read-only fetch of existing/external object
- `variable "name" {}` — input parameter
- `output "name" {}` — exposes value to caller/CLI
- `locals {}` — internal computed values, not exposed as I/O
- `module "name" {}` — calls a reusable child module

**Example**: `data "aws_vpc" "existing"` to pull an already-created shared VPC's ID instead of hardcoding it — common when platform team owns networking and app team consumes it.

## 3. CLI Commands

`init`, `validate`, `fmt` (`-check` for CI), `plan` (`-out=plan.tfplan`), `apply` (`-auto-approve`, or `apply plan.tfplan`), `destroy` (`-target` for partial), `output`, `show`.

**Real-time**: In a pipeline, never use `-auto-approve` on `prod` — always gate with a manual approval step after `plan`.

## 4. Meta-Arguments

- `count` — numeric replication, `count.index`
- `for_each` — map/set replication, `each.key`/`each.value`
- `for_each` is safer than `count` — removing a middle item with `count` shifts every subsequent index and forces unwanted destroy/recreate; `for_each` keys are stable.
- `depends_on` — explicit dependency when no attribute reference exists.

**Example**: Creating 3 EC2 instances with different names/tags → use `for_each` over a map, not `count`, so deleting instance "web-2" doesn't recreate "web-3".

## 5. Lifecycle Block

Nested in a `resource`:
- `create_before_destroy` — new resource up before old is torn down (zero-downtime replace)
- `prevent_destroy` — blocks destroy/replace (protect RDS/state buckets)
- `ignore_changes` — ignore drift on listed attrs or `all`
- `replace_triggered_by` — force replace when a referenced value changes
- `precondition{}` / `postcondition{}` — custom validation (1.2+)

**Real-time**: ASG `desired_capacity` is managed by an autoscaler at runtime → `ignore_changes = [desired_capacity]` so Terraform doesn't fight the scaler on every apply.

## 6. Dependency Graph

Terraform builds a DAG. Implicit dependency (via attribute reference) is preferred and auto-detected; `depends_on` is the fallback when there's no direct reference (e.g., IAM eventual consistency). `terraform graph` outputs DOT format for Graphviz. The graph also decides what can run in parallel.

## 7. Variables, Outputs, Locals

Types: string, number, bool, list, map, set, object, tuple, any.

Precedence (low→high): defaults < `TF_VAR_*` env < `.tfvars` < `*.auto.tfvars` < `-var-file` < `-var` (CLI flag wins).

`output` supports `sensitive` and `depends_on`. `locals` = DRY reusable expressions scoped to a module.

**Example**: `TF_VAR_db_password` set as a pipeline secret env var rather than in any `.tfvars` file — keeps it out of git entirely.

## 8. Provider Configuration

`alias` for multi-region/multi-account setups. `required_providers{}` with version constraints (`~>`, `>=`, `=`). `.terraform.lock.hcl` locks exact provider versions — **commit this**. `default_tags` (AWS provider) auto-tags every resource in that provider config.

**Example**:
```hcl
provider "aws" {
  alias  = "us_east"
  region = "us-east-1"
}
resource "aws_acm_certificate" "cert" {
  provider = aws.us_east   # CloudFront certs must be in us-east-1
}
```

## 9. State Management

`terraform.tfstate` — JSON mapping config → real resource IDs/attributes. Remote state (S3, Azure Blob, GCS, TFC) is the norm for teams: single source of truth, avoids stale local state, enables locking. **Sensitive values are stored in plaintext in state** — encrypt the backend. Never commit state to git.

**Split strategy**:
- Per environment (dev/stage/prod) — blast-radius control
- Per layer/module (network, platform, app) — smaller/faster plans, independent ownership
- Trade-off: more state files = more cross-state lookups via `terraform_remote_state`

## 10. Remote Backends

- AWS: S3 (storage) + DynamoDB (lock table) — **note**: since Terraform 1.10, S3 backend supports native state locking without DynamoDB (`use_lockfile = true`), though DynamoDB is still widely used in existing setups.
- Azure: `azurerm` backend → Storage Account + Blob container
- GCP: GCS backend
- Terraform Cloud/Enterprise: built-in locking

Backend block allows partial config (`-backend-config=` at init) and **cannot use variables/interpolation**.

## 11. Cross-State Communication

`terraform_remote_state` data source reads another module's outputs from its state file (read-only). Use case: network team's VPC/subnet IDs consumed by the app team. Requires read access to the source backend (e.g., S3 bucket IAM perms).

Modules never talk to each other directly — the root module wires them: `module.vpc.private_subnet_id` passed as an input to `module "ec2"`.

## 12. Module Design

```
modules/vpc, modules/ec2, modules/rds   (each: main.tf, variables.tf, outputs.tf)
root: module "vpc" { source = "./modules/vpc"; cidr = var.cidr }
root: module "ec2" { source = "./modules/ec2"; subnet_id = module.vpc.private_subnet_id }
```
For shared org modules, use a registry/versioned source (`source`, `version`).

## 13. Workspaces vs Separate Env Directories

`terraform workspace new/list/select/show/delete`. `${terraform.workspace}` usable in config. Workspaces = same config, multiple states — light isolation only.

**Separate directory approach** (environments/dev, environments/stage, environments/prod, each with own backend.tf and tfvars) gives full isolation, explicit blast radius, different approvers/variables per env. More common in production companies than raw workspaces, at the cost of some duplication (mitigated via shared `modules/`).

## 14. Repo Structure (Common Pattern)

```
modules/         -> reusable building blocks
environments/dev/prod -> main.tf, variables.tf, backend.tf, tfvars, own state
global/          -> account-level resources (IAM, DNS)
versions.tf, README.md per module
```

## 15. Data Sources vs Resources

`data` blocks = read-only fetch, no lifecycle management (`data "aws_ami"`, `data "aws_vpc"`). `resource` blocks = Terraform owns create/update/destroy.

## 16. Expressions & Functions

Interpolation `"${var.x}"` (implicit in most HCL2 contexts). Conditional: `condition ? true_val : false_val`. `for` expression: `[for x in list : x.name]`. `dynamic` blocks generate nested blocks programmatically (e.g., variable number of ingress rules in a security group).

Common functions: `lookup()`, `merge()`, `join()`, `split()`, `coalesce()`, `templatefile()`, `file()`, `jsonencode()`, `try()`, `element()`.

**Example**: `dynamic "ingress"` block looping over a list of allowed ports from a variable, instead of writing a separate `ingress{}` block per port.

## 17. State Drift

Drift = real infra ≠ state (manual console change, external automation). Detected via `plan` (unexpected diff) or `refresh`. `ignore_changes = [attr1, attr2]` or `all` silences expected drift. `terraform apply -refresh-only` syncs state to reality without changing infra.

## 18. State Manipulation Commands

`state list`, `state show <addr>`, `state mv <old> <new>` (rename/move without destroy-recreate), `state rm <addr>` (stop tracking; infra stays), `state pull` / `state push` (raw backups).

**Real-time**: Renaming a resource in code (e.g., `aws_instance.web` → `aws_instance.app_server`) without `state mv` first will make Terraform plan to destroy the old and create a new one — `state mv` avoids that.

## 19. Import / Taint / Replace

`terraform import <addr> <id>` brings an existing resource under management — needs a matching `resource` block written first, and import **does not generate config**, only state. `terraform taint` is deprecated → use `terraform apply -replace=<addr>`.

**Newer (1.5+)**: `import {}` config blocks + `terraform plan -generate-config-out=` can generate HCL automatically from real resources — worth mentioning in interviews as the modern replacement for manual `terraform import`.

## 20. State Recovery & DR

Always `terraform state pull > backup.tfstate` before risky operations. S3 backend: enable bucket versioning to restore a prior object version. No backup as last resort: rebuild via `import` per resource. Test recovery periodically.

**DR checklist**: S3 versioning + SSE encryption on state bucket; DynamoDB PITR on lock table; cross-region replication for critical envs; least-privilege IAM + CloudTrail audit; documented import runbook; pre-change backup step in CI/CD.

## 21. State Locking

DynamoDB (AWS, traditional) / native locking (TFC, azurerm, GCS, or newer S3 native lockfile). Prevents concurrent plan/apply from corrupting state. Lock held for the duration of plan/apply.

**"Error acquiring state lock" — troubleshooting steps**:
1. Read the error (LockID, Who, Operation, Created time)
2. Check if another pipeline run is genuinely in progress → wait
3. If holder crashed (stale lock), confirm with team before acting
4. `terraform force-unlock <LOCK_ID>` — only after confirming it's safe
5. Root-cause: pipeline killed mid-run, network drop, manual Ctrl+C

## 22. Provisioners

`local-exec` / `remote-exec` — treated as a **last resort**; prefer native resources/config management (Ansible) instead. `when = destroy` for destroy-time provisioners. `connection{}` block for SSH/WinRM.

**Real-time**: Instead of `remote-exec` to install a package on a new EC2, hand off to your Ansible playbook (fits your existing Ansible skill) via `user_data` or a post-provision pipeline stage.

## 23. Secrets Management

Never hardcode secrets in `.tf` or commit `.tfvars` with secrets. Source from Vault, AWS SSM Parameter Store/Secrets Manager, Azure Key Vault. Pass via data source or `TF_VAR_*` env vars, not literals. `sensitive = true` masks CLI output only — **value is still plaintext in state**, so state encryption is still required. `.gitignore`: `*.tfstate`, `*.tfvars` (if secret-bearing), `.terraform/`
# Injecting AWS Secrets into Terraform & Ansible

## 1. Terraform — pulling secrets from AWS

Use a `data` source. Never hardcode a secret in a `resource`, `variable` default, or `.tfvars`.

**Secrets Manager**:
```hcl
data "aws_secretsmanager_secret_version" "db" {
  secret_id = "prod/db/password"
}

resource "aws_db_instance" "main" {
  password = data.aws_secretsmanager_secret_version.db.secret_string
}
```

**SSM Parameter Store** (simpler key-value config):
```hcl
data "aws_ssm_parameter" "db_pass" {
  name            = "/prod/db/password"
  with_decryption = true
}
```

**Caveat**: even fetched this way, the value still lands in **plaintext inside the Terraform state file** once used in a resource attribute. This approach keeps the secret out of `.tf`/`.tfvars`/git — it does not remove the need to encrypt the state backend (SSE on the S3 bucket).

## 2. Ansible — pulling secrets from AWS

**Secrets Manager**:
```yaml
vars:
  db_password: "{{ lookup('amazon.aws.aws_secret', 'prod/db/password') }}"
```

**SSM Parameter Store**:
```yaml
vars:
  db_password: "{{ lookup('amazon.aws.aws_ssm', '/prod/db/password', decrypt=True) }}"
```

Both require `boto3`/`botocore` on the control node and IAM permission (`secretsmanager:GetSecretValue` or `ssm:GetParameter`) on whatever identity Ansible runs as.

## 3. How they connect in a real pipeline

Terraform provisions the Secrets Manager entry / SSM parameter (or security team does it out-of-band) → Ansible, running later in the same pipeline against the infra Terraform just built, pulls the value live via the lookup plugin at runtime. Neither tool ever stores the secret on disk or in git — it's fetched on-demand from AWS, gated purely by IAM.

## 4. Two separate requirements: permission vs credentials

**IAM permission** — always required, everywhere. Whatever identity runs `terraform apply` or `ansible-playbook` must be authorized (via policy) for the specific action (`secretsmanager:GetSecretValue`, `ssm:GetParameter`) on that specific secret's ARN. No permission, no fetch, regardless of how credentials are supplied.

**AWS credentials** — *how* that identity authenticates. Two approaches:

| Approach | What it looks like | Verdict |
|---|---|---|
| Static credentials | `aws configure`, `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` env vars, credentials file | Avoid for anything long-lived — leak risk, no auto-rotation, extra audit burden |
| IAM role on the compute | Instance profile (EC2), IRSA (EKS pod), OIDC federation (CI runner), STS assume-role (local) | Best practice — SDK auto-discovers short-lived temp creds, nothing to store or type |

## 5. Where each execution context gets its identity

- **EC2 running Terraform/Ansible** → IAM role attached as an instance profile
- **EKS pod** (e.g. CI runner or AWX pod in-cluster) → IRSA (IAM Roles for Service Accounts)
- **GitHub Actions / Jenkins pipeline** → OIDC federation: the job authenticates to AWS via OIDC, assumes an IAM role, gets short-lived STS credentials for that run only — no long-lived keys stored in GitHub Secrets or Jenkins credentials store at all
- **Local machine (dev/testing `terraform plan` before pushing)** → `aws sso login` or `assume-role` for temporary creds, not permanent access keys in `~/.aws/credentials`

## 6. Pipeline vs local — what "no configuration needed" actually means

**Pipeline run**: no static credential configuration required. OIDC → assume role → short-lived STS credentials, automatically, per job run.

**Not credential-free by accident**: someone still has to set up the OIDC trust relationship + IAM role once — a trust policy scoped to the specific GitHub repo/branch. That one-time IAM setup is itself usually done via Terraform, and is worth being able to explain in an interview rather than just "the pipeline handles it."

**Local machine**: still used for `terraform plan` while writing/testing code before it hits the pipeline — normal dev workflow. The correction isn't "no config on local," it's "no *static* long-lived credentials, anywhere — local or pipeline." Local uses temporary SSO/assume-role credentials instead.

How it actually works: instead of you manually pasting a secret into Jenkins's credential store, this plugin surfaces secrets already sitting in AWS Secrets Manager as if they were native Jenkins credentials — Jenkins queries Secrets Manager at build time and the value is never persisted in Jenkins's own credential database. You reference it the same way (credentials('my-secret-id')), but nothing static is stored on the Jenkins side.

The catch you should catch yourself: this solves secret storage, not the underlying chicken-and-egg problem — Jenkins still has to authenticate to AWS Secrets Manager to fetch anything. That authentication step needs one of:

Instance profile on the EC2 box running Jenkins (best — no keys anywhere)
IRSA if the Jenkins agent runs as an EKS pod
A static AWS key, if neither of the above is possible

So the plugin removes static app-level secrets (DB passwords, API tokens) from Jenkins's store — but the AWS-auth-for-Jenkins-itself problem still resolves to instance profile/IRSA vs static keys, same as before. It doesn't eliminate that layer, it just moves the "what's stored where" question one level down.

## 7. Senior-level framing for interviews

"Credentials configured" signals static keys. "IAM role attached to the execution identity" signals you understand least-privilege and rotation. Lead with the second phrasing.

## 24. Tagging Strategy

Consistent tags: `Environment`, `Owner`, `Project`, `CostCenter`, `ManagedBy`. `default_tags` on the AWS provider auto-applies tags to every resource in that provider config — reduces repetition, supports cost allocation and automation exclusion.

## 25. Testing & Static Analysis

`terraform validate`, `terraform fmt -check` (CI gate). `tflint` for linting/provider rules. `checkov` / `tfsec` for static security/compliance scanning. `terraform plan -detailed-exitcode` (0 = no changes, 1 = error, 2 = changes — useful for CI branching logic).

**Missing but worth knowing at 3 YoE**: native `terraform test` framework (`.tftest.hcl` files, `run` blocks, assertions) — HashiCorp's built-in alternative to Terratest for unit/integration testing modules. Also **Infracost** for cost estimation on PRs before apply.

## 26. CI/CD Integration

Standard pipeline: `fmt → validate → plan → manual approval → apply`. Plan output posted as PR artifact/comment before apply. Remote backend handles locking across pipeline runs. Use a **separate service principal/IAM role per environment** (least privilege, blast-radius control).

**Missing topic — Atlantis**: a popular open-source tool that automates this exact plan/apply-on-PR workflow via PR comments (`atlantis plan`, `atlantis apply`) — commonly asked about alongside GitHub Actions/Jenkins pipelines for Terraform.

## 27. Terraform Cloud/Enterprise

Remote runs, VCS-driven workflow, remote state + locking built-in. **Sentinel** / **OPA** = policy-as-code gates before apply (e.g., "no public S3 buckets allowed," enforced automatically, not just by code review). Private module + provider registry, RBAC, run triggers.

## 28. Common Errors

- Provider version conflicts → pin versions, delete `.terraform/` and re-init
- Cyclic dependency errors → refactor implicit refs / `depends_on`
- "Resource already exists" → import instead of recreate

## 29. Missing Topics Worth Adding at 3-4 YoE

- **Terragrunt**: a thin DRY wrapper around Terraform — keeps backend/provider config non-repetitive across many environments. Frequently asked "have you used it / why not" in interviews even if you only use native Terraform.
- **`moved` block** (1.1+): declares a resource/module was renamed/moved in code without triggering destroy-recreate — the declarative alternative to `terraform state mv`.
- **`terraform_data` resource** (1.4+): replacement for the old `null_resource` + `triggers`, used to force actions on arbitrary value changes.
- **`terraform console`**: interactive REPL to test expressions/functions against current state — handy for debugging complex `for` expressions before putting them in code.
- **`TF_LOG`** env var (`TRACE/DEBUG/INFO/WARN/ERROR`) for provider-level debugging when a provider call fails mysterously.
- **Provider plugin caching** (`plugin_cache_dir`) to speed up `init` across many environment directories in CI.


# Terraform Production Folder Structure (Real-World)

```
terraform-infra/
├── modules/
│   ├── vpc/
│   │   ├── main.tf
│   │   ├── variables.tf
│   │   ├── outputs.tf
│   │   └── versions.tf
│   ├── eks/
│   │   ├── main.tf
│   │   ├── variables.tf
│   │   ├── outputs.tf
│   │   └── versions.tf
│   ├── rds/
│   │   ├── main.tf
│   │   ├── variables.tf
│   │   ├── outputs.tf
│   │   └── versions.tf
│   ├── ec2/
│   │   ├── main.tf
│   │   ├── variables.tf
│   │   └── outputs.tf
│   └── alb/
│       ├── main.tf
│       ├── variables.tf
│       └── outputs.tf
│
├── environments/
│   ├── dev/
│   │   ├── backend.tf          # remote state config, own S3 key
│   │   ├── main.tf             # calls modules with dev-sized inputs
│   │   ├── variables.tf
│   │   ├── outputs.tf
│   │   ├── terraform.tfvars
│   │   └── provider.tf
│   ├── stage/
│   │   ├── backend.tf
│   │   ├── main.tf
│   │   ├── variables.tf
│   │   ├── outputs.tf
│   │   ├── terraform.tfvars
│   │   └── provider.tf
│   └── prod/
│       ├── backend.tf
│       ├── main.tf
│       ├── variables.tf
│       ├── outputs.tf
│       ├── terraform.tfvars
│       └── provider.tf
│
├── global/
│   ├── iam/
│   │   ├── main.tf              # cross-account roles, org policies
│   │   └── outputs.tf
│   └── dns/
│       ├── main.tf              # Route53 zones shared across envs
│       └── outputs.tf
│
├── policies/                    # optional — OPA/Sentinel or Checkov rules
│   └── no-public-s3.rego
│
├── scripts/
│   ├── init.sh                  # wrapper: terraform init -backend-config=...
│   └── plan-all-envs.sh
│
├── .github/
│   └── workflows/
│       └── terraform.yml        # fmt -> validate -> plan -> approval -> apply
│
├── .gitignore                   # .terraform/, *.tfstate, *.tfvars (if secret), crash.log
├── .terraform.lock.hcl          # one per environment dir, always committed
└── README.md
```

## Why it's structured this way

**`modules/`** — reusable building blocks only. No environment-specific values live here; everything comes in via `variables.tf`. One module = one piece of infra (vpc, eks, rds), each independently testable.

**`environments/<env>/`** — the actual root configs that get `init`/`plan`/`apply`'d. Each has its **own backend** (own S3 state key, e.g. `env:/prod/network/terraform.tfstate`), own tfvars, and often its own IAM role/service principal. This is what gives you real blast-radius isolation — a mistake in `dev/main.tf` can't touch prod state, because prod state literally lives elsewhere with different credentials.

**`global/`** — account-level resources that don't belong to any single environment (IAM roles, Route53 zones, org-wide guardrails). Usually its own state file too.

**Real-time flow at HCL-scale**: platform team owns `modules/vpc` and `modules/eks`; app teams only ever touch their own `environments/<team>/<env>/main.tf`, referencing the shared modules by version (`source = "git::https://.../modules//vpc?ref=v1.4.0"`). Nobody edits `modules/` directly without a version bump — that's how you avoid one team's change silently breaking another team's plan.

**One state file per env + per layer** (as in your revision notes) — network/platform/app split further under each `environments/<env>/` in bigger orgs, e.g. `environments/prod/network/`, `environments/prod/eks/`, `environments/prod/app/`, each with its own backend key, wired together via `terraform_remote_state`.

## Common mistake to avoid

Putting `provider{}` config with hardcoded credentials inside `modules/` — providers belong in the **root** (`environments/<env>/provider.tf`), modules should stay provider-config-agnostic so the same module works across accounts/regions.

---

# Top 15 Scenario-Based Interview Questions

**1. Two engineers ran `apply` on the same state at the same time. What actually stopped a corruption, and what would you check first if you saw a stuck lock?**
State locking (DynamoDB or backend-native) blocks the second `apply` until the first finishes. If a lock looks stuck, read the lock's Who/Operation/Created-time, confirm with the team whether that run actually crashed, and only then run `force-unlock` — never force it blindly.

**2. A junior removed the third of five items from a `count`-based resource block and it wanted to destroy and recreate items 4 and 5. Why, and how do you prevent it?**
`count` indexes are positional — removing an item shifts every later index, so Terraform sees "different" resources at those indices. Refactor to `for_each` over a map/set, which keys by stable identity, not position.

**3. Your team's ASG desired_capacity keeps showing as drift on every plan even though nobody touched it. Fix?**
An autoscaler is adjusting `desired_capacity` at runtime outside Terraform. Add `lifecycle { ignore_changes = [desired_capacity] }` so Terraform stops treating scaler-driven changes as drift.

**4. You need to reference a VPC that another team manages in a separate state file. How, without duplicating their Terraform code?**
Use `terraform_remote_state` data source pointed at their backend (read-only), or better, have them expose it via an `output` and consume via `data` sources — requires read IAM access to their backend.

**5. Someone accidentally ran `apply` against prod with a stale local plan file. How do you prevent this going forward?**
Enforce a pipeline: `plan -out=plan.tfplan` as an artifact, mandatory manual approval, then `apply plan.tfplan` — never a fresh ad-hoc apply against prod, and no local applies allowed against the prod backend (separate role/credentials).

**6. Your state file got corrupted/partially lost with no recent backup. Walk through recovery.**
Check S3 versioning for a prior good object version and restore via `state push`. If truly gone, rebuild via `terraform import` per resource against a matching `resource` block (import brings state only, not config, so you write the HCL first — or use `-generate-config-out` in newer versions).

**7. You want to rename a resource in code without Terraform destroying and recreating the real infrastructure. How?**
`terraform state mv old_addr new_addr` (imperative), or the declarative `moved {}` block (1.1+) committed alongside the rename so anyone running plan gets the same non-destructive result.

**8. A `sensitive = true` variable holding a DB password — is it actually protected?**
Only from CLI/log output. The raw value is still stored in plaintext inside the state file, so the backend itself (S3 bucket, etc.) must be encrypted (SSE) and access-restricted — `sensitive` alone is not enough.

**9. Multiple environments need the same VPC/EKS module but different sizing and account isolation. Workspaces or separate directories — which and why?**
Separate environment directories for true isolation (different backends, blast radius, approvers, credentials per env), sharing logic via a common `modules/` folder. Workspaces are acceptable for light, same-account variation but are not a full substitute for prod-grade separation.

**10. Your CI pipeline needs to know whether `plan` found any changes, to decide whether to require approval.**
Use `terraform plan -detailed-exitcode`: exit code 0 = no changes (auto-skip approval), 1 = error, 2 = changes detected (require approval gate) — branch pipeline logic on that exit code.

**11. A resource block references another resource's attribute, but occasionally Terraform tries to create them in the wrong order.**
Implicit dependency via attribute reference should auto-order this correctly in the DAG; if there's genuinely no attribute reference (e.g., IAM eventual consistency, cross-service timing) add explicit `depends_on`.

**12. You need to enforce "no public S3 buckets" org-wide, not just rely on PR review.**
Policy-as-code: Sentinel (Terraform Cloud/Enterprise) or OPA, run as a mandatory gate before apply — reviewer error can't bypass a hard policy check the way it can bypass a human reviewer.

**13. Your `.tf` files reference a provider version that changed behavior after a teammate ran `init` fresh and got a different provider version than you.**
`.terraform.lock.hcl` wasn't committed, or someone deleted it. It should always be committed — it pins the exact resolved provider version so every teammate and CI run gets identical behavior; `required_providers{}` version constraints alone only set a range, not an exact pin.

**14. You're asked to reduce blast radius on a monolithic Terraform config that manages network, EKS, and app resources in one state file.**
Split by layer into separate state files (network / platform / app), each independently owned and planned, wired together via `terraform_remote_state` outputs — trades a bit of cross-state lookup complexity for much smaller, faster, safer plans per team.

**15. A `remote-exec` provisioner to install software on a new EC2 instance is flaky in CI (SSH timing issues).**
Provisioners are a last resort and fragile by design (they depend on network/SSH timing outside Terraform's control). Prefer baking the software into the AMI (Packer) or handing configuration to Ansible/`user_data` post-boot instead of `remote-exec`.
