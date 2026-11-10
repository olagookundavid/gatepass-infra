#!/usr/bin/env bash
# Test users and access tokens for the Gatepass Cognito user pool (layer 40-data, persistent).
#
#   scripts/cognito.sh create-test-users     once: admin, user, load1..load5 (random passwords)
#   scripts/cognito.sh token <name>          prints an ACCESS token on stdout (nothing else)
#
# WHY: the golden path and the proofs of walkthroughs 10 and 11 call the API with real tokens.
# The pool is persistent, so the users survive `make down`; create them once.
# WHERE THE SECRETS GO: each password is generated here, kept in ~/.gatepass/cognito-<name>
# (mode 600, outside every repository) and is never printed. Tokens are printed only by `token`,
# so use them as  TOKEN=$(scripts/cognito.sh token user)  and never echo them.
# The pool id and app client id are read from the data-config secret in Secrets Manager (no id in Git).
# Users are e-mail addresses at example.test: nothing is ever sent (MessageAction=SUPPRESS).
# Needs: aws (profile gatepass), jq, openssl. Related: gatepass-infra/40-data/cognito.tf.
set -euo pipefail

export AWS_PROFILE="${AWS_PROFILE:-gatepass}" AWS_REGION="${AWS_REGION:-us-east-1}"
DIR="${HOME}/.gatepass"
cfg() { aws secretsmanager get-secret-value --secret-id gatepass/dev/app/data-config --query SecretString --output text | jq -r ".$1"; }
email() { echo "$1@example.test"; }

create_user() { # <name> [admin]
  local name="$1" pw file="$DIR/cognito-$1" pool; pool="$(cfg cognito_user_pool_id)"
  mkdir -p "$DIR"; chmod 700 "$DIR"
  if [[ -f "$file" ]]; then pw="$(cat "$file")"; else pw="$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-20)Aa1!"; (umask 077; printf '%s' "$pw" > "$file"); fi
  aws cognito-idp admin-create-user --user-pool-id "$pool" --username "$(email "$name")" \
    --user-attributes Name=email,Value="$(email "$name")" Name=email_verified,Value=true \
    --message-action SUPPRESS >/dev/null 2>&1 || echo "   $name exists, resetting its password"
  aws cognito-idp admin-set-user-password --user-pool-id "$pool" --username "$(email "$name")" --password "$pw" --permanent
  if [[ "${2:-}" == admin ]]; then
    aws cognito-idp admin-add-user-to-group --user-pool-id "$pool" --username "$(email "$name")" --group-name admin
  fi
  echo "   $name ready"
}

case "${1:-}" in
  create-test-users)
    create_user admin admin; create_user user
    for i in 1 2 3 4 5; do create_user "load$i"; done ;;
  token)
    name="${2:?usage: cognito.sh token <name>}"
    aws cognito-idp initiate-auth --auth-flow USER_PASSWORD_AUTH --client-id "$(cfg cognito_client_id)" \
      --auth-parameters "USERNAME=$(email "$name"),PASSWORD=$(cat "$DIR/cognito-$name")" \
      --query AuthenticationResult.AccessToken --output text ;;
  *) echo "usage: cognito.sh create-test-users | token <name>" >&2; exit 2 ;;
esac
