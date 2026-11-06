# Three providers.
#
# aws: allowed_account_ids is the safety net (a wrong CLI profile stops the plan); default_tags
# puts the same five tags on every taggable AWS resource (this layer creates none, the block is
# kept so all layers look alike and a later addition is tagged without anyone remembering).
#
# kubernetes and helm: both reach the cluster the same way as kubectl does. The address and the
# certificate come from a lookup of the cluster (data.tf); the token is requested at run time by
# `aws eks get-token`, which uses your current `aws login` session. Nothing is stored: no
# kubeconfig file, no token in the state. The token lasts 15 minutes and is fetched again when
# needed.
#
# This only works if (a) 20-cluster is applied and (b) your public IP is still the one in the
# cluster's api_allowed_cidrs; otherwise the provider times out connecting.
provider "aws" {
  region              = var.region
  allowed_account_ids = [var.allowed_account_id]

  default_tags {
    tags = {
      Project     = "gatepass"
      Environment = var.environment
      Owner       = "davidoh"
      ManagedBy   = "terraform"
      CostCenter  = "learning"
    }
  }
}

locals {
  eks_exec_args = ["eks", "get-token", "--cluster-name", local.cluster_name, "--region", var.region]
}

provider "kubernetes" {
  host                   = data.aws_eks_cluster.main.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.main.certificate_authority[0].data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = local.eks_exec_args
  }
}

provider "helm" {
  kubernetes = {
    host                   = data.aws_eks_cluster.main.endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.main.certificate_authority[0].data)

    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = local.eks_exec_args
    }
  }
}
