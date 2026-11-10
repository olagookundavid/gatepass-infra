# Day-to-day commands for the ephemeral layers: bring them up in order, take them down in
# reverse. 00-bootstrap is NOT in these lists: it is persistent and stays between sessions.
#
#   make plan            init + plan every layer (read-only; 20-cluster needs 10-network applied)
#   make up              apply 10-network, 20-cluster, 30-platform-aws, 25-gitops-bootstrap, then point kubectl at the cluster
#   make drain           empty the cluster of load balancers and Karpenter nodes (scripts/drain-cluster.sh)
#   make down            drain, destroy 25-gitops-bootstrap, 30-platform-aws, 20-cluster, 10-network, remove the kubectl context
#   make kubeconfig      (re)create the kubectl context "gatepass-dev"
#   make check-clean     read-only: list what would still cost money after a `make down`
#   make check-retention read-only: list log groups that never expire (should print none)
#   00-bootstrap, 05-dns, 40-data and 60-observability are PERSISTENT: `terraform -chdir=<layer> apply` once; not in `make up`
#   (`make up` also needs `make lambda-zip` run once in gatepass-app: 45-database uploads the report Lambda zip)
#   (`make up` ends with scripts/post-up.sh: makes the load balancer webhook certificate consistent
#    and re-syncs applications that failed meanwhile; see the script header)
#   make up AUTO_APPROVE=-auto-approve    skip the confirmation prompts (use only when sure)
#
# `make up` and `make down` change AWS (they ask for confirmation unless AUTO_APPROVE is set).
# Run them from this folder, with AWS_PROFILE=gatepass and AWS_REGION=us-east-1 exported.
#
# Layers are added to the two lists below as the phases arrive; the plan's section 9 gives the
# full teardown order. ORDER MATTERS: 30-platform-aws (the IAM roles of the controllers) is
# applied BEFORE 25-gitops-bootstrap (which starts Argo CD and with it the controllers), so a
# controller never starts without its credentials; on the way down `drain` first makes the
# controllers delete the load balancers and nodes they created, which Terraform does not know.

# Order matters. 45-database needs the cluster's security group (so after 20); 50-workloads needs the
# database's resource id and must exist before any pod starts (credentials are injected at pod start),
# so it comes before 25-gitops-bootstrap. Teardown is the exact reverse. The persistent layers
# 00-bootstrap, 05-dns, 40-data and 60-observability are applied by hand and are not in these lists.
LAYERS_UP   := 10-network 20-cluster 30-platform-aws 45-database 50-workloads 25-gitops-bootstrap
LAYERS_DOWN := 25-gitops-bootstrap 50-workloads 45-database 30-platform-aws 20-cluster 10-network
CLUSTER     := gatepass-dev
REGION      ?= us-east-1
AUTO_APPROVE ?=

.PHONY: help plan up down drain kubeconfig check-ip remove-kubeconfig check-clean check-retention
.DEFAULT_GOAL := help

help:
	@sed -n '1,14p' Makefile | sed 's/^# \{0,1\}//'

plan:
	@for l in $(LAYERS_UP); do \
	  echo "== $$l"; \
	  terraform -chdir=$$l init -backend-config=backend.hcl -input=false >/dev/null && \
	  terraform -chdir=$$l plan -input=false || exit 1; \
	done

# Read-only. The EKS API is reachable only from the address(es) in 20-cluster/terraform.tfvars
# (api_allowed_cidrs). A laptop that moved to another network gets "i/o timeout" from kubectl and from
# the layers that talk to the cluster, in the middle of `make up` (seen 2026-11-09). This stops early.
check-ip:
	@ip=$$(curl -fsS -m 8 https://checkip.amazonaws.com | tr -d '[:space:]'); \
	if [ -z "$$ip" ]; then echo "!! could not find out the public IP (offline?)" >&2; exit 1; fi; \
	if grep -q "$$ip/32" 20-cluster/terraform.tfvars 2>/dev/null; then echo "public IP is allowed on the cluster API"; \
	else echo "!! your public IP changed. Put \"$$ip/32\" into api_allowed_cidrs in 20-cluster/terraform.tfvars" >&2; \
	echo "   (then: terraform -chdir=20-cluster apply, if the cluster already exists)" >&2; exit 1; fi

up: check-ip
	@for l in $(LAYERS_UP); do \
	  echo "== apply $$l"; \
	  terraform -chdir=$$l init -backend-config=backend.hcl -input=false >/dev/null && \
	  terraform -chdir=$$l apply -input=false $(AUTO_APPROVE) || exit 1; \
	done
	@$(MAKE) --no-print-directory kubeconfig
	@scripts/post-up.sh

# The kubectl context is removed LAST: drain needs it.
down: drain
	@for l in $(LAYERS_DOWN); do \
	  echo "== destroy $$l"; \
	  terraform -chdir=$$l init -backend-config=backend.hcl -input=false >/dev/null && \
	  terraform -chdir=$$l destroy -input=false $(AUTO_APPROVE) || exit 1; \
	done
	@$(MAKE) --no-print-directory remove-kubeconfig
	@$(MAKE) --no-print-directory check-clean

drain:
	@CLUSTER=$(CLUSTER) ./scripts/drain-cluster.sh

kubeconfig:
	aws eks update-kubeconfig --name $(CLUSTER) --alias $(CLUSTER) --region $(REGION)

# Leaving a context for a deleted cluster in ~/.kube/config makes kubectl hang or fail with
# confusing errors the next day. `|| true`: it is fine if there is nothing to remove.
# `delete-context` does NOT clear the `current-context:` line, so afterwards every kubectl command
# fails with "context was not found" (2026-11-10). If the deleted context was the active one we
# unset it (kubectl then falls back to "no context"; pick one with `kubectl config use-context`).
# The user entry (AUTHINFO) has the same name as the cluster ARN and is removed too.
remove-kubeconfig:
	-@if [ "$$(kubectl config current-context 2>/dev/null)" = "$(CLUSTER)" ]; then kubectl config unset current-context >/dev/null 2>&1 || true; fi
	-kubectl config delete-context $(CLUSTER) 2>/dev/null || true
	-@arn="arn:aws:eks:$(REGION):$$(aws sts get-caller-identity --query Account --output text):cluster/$(CLUSTER)"; kubectl config delete-cluster "$$arn" 2>/dev/null || true; kubectl config delete-user "$$arn" 2>/dev/null || true

# Read-only. Every line should say "none" after a full `make down`.
# (`x=$$(...); ${x:-none}` prints "none" when the command printed nothing.)
check-clean:
	@x=$$(aws eks list-clusters --region $(REGION) --query 'clusters' --output text); printf '%-20s %s\n' "EKS clusters:" "$${x:-none}"
	@x=$$(aws ec2 describe-nat-gateways --region $(REGION) --filter Name=state,Values=pending,available --query 'NatGateways[].NatGatewayId' --output text); printf '%-20s %s\n' "NAT gateways:" "$${x:-none}"
	@x=$$(aws ec2 describe-addresses --region $(REGION) --query 'Addresses[].PublicIp' --output text); printf '%-20s %s\n' "Elastic IPs:" "$${x:-none}"
	@x=$$(aws elbv2 describe-load-balancers --region $(REGION) --query 'LoadBalancers[].LoadBalancerName' --output text); printf '%-20s %s\n' "Load balancers:" "$${x:-none}"
	@x=$$(aws ec2 describe-instances --region $(REGION) --filters Name=tag:Project,Values=gatepass Name=instance-state-name,Values=pending,running --query 'Reservations[].Instances[].InstanceId' --output text); printf '%-20s %s\n' "EC2 instances:" "$${x:-none}"
	@x=$$(aws logs describe-log-groups --region $(REGION) --query "logGroups[?starts_with(logGroupName,'/aws/eks/$(CLUSTER)') || starts_with(logGroupName,'/aws/vpc/$(CLUSTER)')].logGroupName" --output text); printf '%-20s %s\n' "Log groups:" "$${x:-none}"
	@x=$$(aws rds describe-db-instances --region $(REGION) --query 'DBInstances[].DBInstanceIdentifier' --output text); printf '%-20s %s\n' "RDS instances:" "$${x:-none}"
	@x=$$(aws elasticache describe-serverless-caches --region $(REGION) --query 'ServerlessCaches[].ServerlessCacheName' --output text); printf '%-20s %s\n' "ElastiCache caches:" "$${x:-none}"
	@d=$$(aws ec2 describe-vpcs --region $(REGION) --filters Name=is-default,Values=true --query 'Vpcs[0].VpcId' --output text); x=$$(aws ec2 describe-network-interfaces --region $(REGION) --query "NetworkInterfaces[?VpcId!='$$d'].NetworkInterfaceId" --output text); printf '%-20s %s\n' "Network interfaces:" "$${x:-none}"

# Read-only. Every log group in the account must have a retention period (no expiry = billed
# forever). Prints the offenders; "none" is the goal. (60-observability sets it for the
# application log group, 20-cluster and 10-network for theirs.)
check-retention:
	@x=$$(aws logs describe-log-groups --region $(REGION) --query "logGroups[?retentionInDays==null].logGroupName" --output text); printf '%-34s %s\n' "Log groups without retention:" "$${x:-none}"
