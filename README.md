# gatepass-infra

Terraform for the Gatepass platform on AWS. One folder per **layer**; each layer has its own state key (`gatepass/<env>/<layer>.tfstate`) and is applied in numeric order and destroyed in reverse.

| Layer | What | Lifetime |
|---|---|---|
| `00-bootstrap` | KMS key, artifacts bucket, ECR, GitHub OIDC roles, budget, CloudTrail | persistent |
| `10-network` | VPC, 3 public + 3 private + 3 isolated data subnets, NAT, S3/DynamoDB gateway endpoints, flow logs | ephemeral (`make down` nightly) |
| `20-cluster` | EKS (API access entries, KMS secrets, logs with retention), managed add-ons, system node group | ephemeral |
| `25-gitops-bootstrap` | Argo CD (pinned Helm chart), repository credential, RBAC and notification secrets read ephemerally from Secrets Manager, the bootstrap project and the root application | ephemeral |
| `30-platform-aws` | AWS side of the platform add-ons: Pod Identity roles (load balancer controller, Karpenter, External Secrets, EBS CSI), the Karpenter node role and interruption queue, the EBS CSI add-on, the WAF web ACL | ephemeral |
| `60-observability` | Prometheus workspace (AMP), alert manager and rules, SNS alerts topic with e-mail subscription, application log group with retention, X-Ray sampling rule, IAM roles of the collectors and Grafana. The two Pod Identity associations live in `30-platform-aws/observability.tf` | **persistent** (apply once, like 00; not part of `make up`) |
| `05-dns` | Route 53 zone of the delegated subdomain, CAA record, ACM wildcard certificate (two-step apply: the NS delegation in the parent zone comes in between) | persistent |
| `40-data` | Cognito, DynamoDB (reservations, notifications), SQS queues with DLQs, EventBridge bus + rules + archive, S3 buckets, CloudFront on `cdn.<domain>`, SES identity with DKIM, the Scheduler group and the hold-expirer Lambda, the DB password secrets, the published config secret | persistent |
| `45-database` | RDS PostgreSQL (IAM auth, forced TLS), ElastiCache Serverless for Valkey (IAM users), the in-VPC nightly report Lambda and its schedule, the published addresses | ephemeral |
| `50-workloads` | One IAM role per deployable with exact-ARN permissions and its Pod Identity association | ephemeral |

Rules: no secrets, no `*.tfvars`, no state in Git (the repo is public); every change by pull request; versions pinned (the lock file is committed).

`make plan`, `make up`, `make down` and `make check-clean` run the ephemeral layers in order (read the header of `Makefile` first).

Per layer: `terraform init -backend-config=backend.hcl`, then `plan`, then `apply` (by hand until a protected workflow exists). Start with `00-bootstrap/`; every file is commented.
