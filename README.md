# gatepass-infra

Terraform for the Gatepass platform on AWS. One folder per **layer**; each layer has its own state key (`gatepass/<env>/<layer>.tfstate`) and is applied in numeric order and destroyed in reverse.

| Layer | What | Lifetime |
|---|---|---|
| `00-bootstrap` | KMS key, artifacts bucket, ECR, GitHub OIDC roles, budget, CloudTrail | persistent |
| `10-network` | VPC, 3 public + 3 private + 3 isolated data subnets, NAT, S3/DynamoDB gateway endpoints, flow logs | ephemeral (`make down` nightly) |
| `20-cluster` | EKS (API access entries, KMS secrets, logs with retention), managed add-ons, system node group | ephemeral |
| `25-gitops-bootstrap` | Argo CD (pinned Helm chart), repository credential, RBAC and notification secrets read ephemerally from Secrets Manager, the bootstrap project and the root application | ephemeral |
| `30-platform-aws` | AWS side of the platform add-ons: Pod Identity roles (load balancer controller, Karpenter, External Secrets, EBS CSI), the Karpenter node role and interruption queue, the EBS CSI add-on, the WAF web ACL | ephemeral |
| `40-data` ... `60-observability` | added phase by phase (see the workspace plan) | ephemeral or persistent, noted per layer |

Rules: no secrets, no `*.tfvars`, no state in Git (the repo is public); every change by pull request; versions pinned (the lock file is committed).

`make plan`, `make up`, `make down` and `make check-clean` run the ephemeral layers in order (read the header of `Makefile` first).

Per layer: `terraform init -backend-config=backend.hcl`, then `plan`, then `apply` (by hand until a protected workflow exists). Start with `00-bootstrap/`; every file is commented.
