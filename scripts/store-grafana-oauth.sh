#!/usr/bin/env bash
# Store the Grafana "Sign in with GitHub" settings in AWS Secrets Manager (walkthrough 08, step K).
#
# WHY A SCRIPT. The GitHub OAuth client secret must reach the cluster without ever being typed into
# a chat, a values file, a command line (shell history, process list) or Terraform state. This
# script reads the two values from your keyboard (the secret is not echoed) and writes them, with
# the public address of Grafana, into ONE Secrets Manager secret. External Secrets copies it into
# the Grafana pod's environment (gatepass-gitops examples/grafana-github-sso/externalsecret.yaml).
#
# The secret: gatepass/dev/app/grafana-oauth, JSON {client_id, client_secret, root_url}, encrypted
# with the environment KMS key. The prefix gatepass/dev/app/ is the only one External Secrets may
# read (30-platform-aws/external-secrets.tf). Run it again to replace the values (new version).
#
# Needs: aws (signed in: AWS_PROFILE=gatepass), python3. Takes the domain from the environment
# variable GATEPASS_DOMAIN or asks for it.
set -euo pipefail

SECRET_ID="gatepass/dev/app/grafana-oauth"
REGION="${AWS_REGION:-us-east-1}"
KMS_ALIAS="alias/gatepass-dev"

domain="${GATEPASS_DOMAIN:-}"
if [[ -z "$domain" ]]; then
  read -r -p "Delegated subdomain (for example gatepass.example.com): " domain
fi
read -r -p "GitHub OAuth app client id: " client_id
read -r -s -p "GitHub OAuth app client secret (hidden): " client_secret
echo

if [[ -z "$domain" || -z "$client_id" || -z "$client_secret" ]]; then
  echo "!! all three values are required" >&2
  exit 1
fi

# Build the JSON in python so quoting is correct; the secret goes through the environment of that one
# process and a pipe, never through a command-line argument.
payload="$(CLIENT_ID="$client_id" CLIENT_SECRET="$client_secret" DOMAIN="$domain" python3 -c '
import json, os
print(json.dumps({
    "client_id": os.environ["CLIENT_ID"],
    "client_secret": os.environ["CLIENT_SECRET"],
    "root_url": "https://grafana." + os.environ["DOMAIN"],
}))')"

if aws secretsmanager describe-secret --secret-id "$SECRET_ID" --region "$REGION" >/dev/null 2>&1; then
  aws secretsmanager put-secret-value --secret-id "$SECRET_ID" --region "$REGION" \
    --secret-string "$payload" --query VersionId --output text >/dev/null
  echo "updated $SECRET_ID"
else
  aws secretsmanager create-secret --name "$SECRET_ID" --region "$REGION" --kms-key-id "$KMS_ALIAS" \
    --secret-string "$payload" --query ARN --output text >/dev/null
  echo "created $SECRET_ID"
fi
unset client_secret payload
