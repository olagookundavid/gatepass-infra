# Version constraints (plan rule 5: pin everything, upgrade on purpose through a PR).
#
# Three providers here, because this layer talks to three APIs:
#   aws         reads the cluster's address and the secrets in Secrets Manager;
#   kubernetes  creates the namespace, the Kubernetes Secrets and the RBAC ConfigMap;
#   helm        installs Argo CD and the root application.
#
# Each is constrained to one minor series; the exact versions tested are recorded in
# .terraform.lock.hcl, which IS committed (it also stores package checksums).
terraform {
  required_version = "~> 1.16.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.69.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.5.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.3.0"
    }
  }
}
