# gatepass-infra

Terraform for the Gatepass platform on AWS. One folder per **layer**; each layer has its own state key (`gatepass/<env>/<layer>.tfstate`) and is applied in numeric order and destroyed in reverse.

| Layer | What | Lifetime |
|---|---|---|
| `00-bootstrap` | KMS key, artifacts bucket, ECR, GitHub OIDC roles, budget, CloudTrail | persistent |
| `10-network` ... `60-observability` | added phase by phase (see the workspace plan) | ephemeral or persistent, noted per layer |

Rules: no secrets, no `*.tfvars`, no state in Git (the repo is public); every change by pull request; versions pinned (the lock file is committed).

Per layer: `terraform init -backend-config=backend.hcl`, then `plan`, then `apply` (by hand until a protected workflow exists). Start with `00-bootstrap/`; every file is commented.
