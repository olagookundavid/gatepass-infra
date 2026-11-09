# USER SIGN-IN: an Amazon Cognito user pool (the users), one app client (what the web app / CLI
# signs in with) and the `admin` group.
#
# HOW THE SERVICES USE IT. They never see a password. A user signs in to Cognito and gets three
# signed JSON Web Tokens (JWT). The browser sends the access token to a service; the service
# downloads the pool's public keys once (the JWKS address below), checks the signature, the issuer
# (COGNITO_ISSUER), the client id (COGNITO_CLIENT_ID) and the expiry, and reads the user's id and
# groups from the claims. The `admin` group is what lets a user create venues and events.
#
# CHOICES AND WHY
#   username = e-mail    people remember an e-mail address; the pool verifies it by a mailed code.
#   password >= 12       a long password policy; MFA is OPTIONAL (an authenticator app) so a user
#                        can turn it on, and a later hardening step can make it required.
#   USER_PASSWORD_AUTH   lets the CLI (aws cognito-idp initiate-auth) sign in with e-mail and
#                        password, which is how the golden-path script and the tests sign in.
#                        Browsers should use the SRP flow or the hosted UI (authorization code
#                        with PKCE); no client secret exists because a browser app cannot keep one.
#   prevent_user_existence_errors  a wrong e-mail and a wrong password give the same answer, so the
#                        sign-in page cannot be used to find out who has an account.
#   e-mail by Cognito    Cognito's built-in sender is capped at 50 messages a day, plenty for a
#                        dev pool; SES (ses.tf) sends the application's own mail.
#   deletion_protection  INACTIVE in dev so `terraform destroy` works; production sets ACTIVE.
#
# The hosted UI domain is a Cognito prefix domain (<prefix>.auth.<region>.amazoncognito.com), enough
# for sign-in tests; a custom domain (auth.<domain>) would need a second certificate in us-east-1
# and is left out.
#
# Related files: config.tf (publishes the issuer, client id and pool id), data.tf (domain),
# 50-workloads (the notifications worker may call AdminGetUser on this pool).

resource "aws_cognito_user_pool" "this" {
  name = "${local.name_prefix}-users"

  username_attributes      = ["email"]
  auto_verified_attributes = ["email"]
  mfa_configuration        = "OPTIONAL"
  deletion_protection      = "INACTIVE"

  software_token_mfa_configuration {
    enabled = true
  }

  password_policy {
    minimum_length                   = 12
    require_lowercase                = true
    require_uppercase                = true
    require_numbers                  = true
    require_symbols                  = false
    temporary_password_validity_days = 7
  }

  account_recovery_setting {
    recovery_mechanism {
      name     = "verified_email"
      priority = 1
    }
  }

  admin_create_user_config {
    allow_admin_create_user_only = false
  }

  email_configuration {
    email_sending_account = "COGNITO_DEFAULT"
  }

  schema {
    name                = "email"
    attribute_data_type = "String"
    required            = true
    mutable             = true

    string_attribute_constraints {
      min_length = 5
      max_length = 254
    }
  }
}

resource "aws_cognito_user_pool_client" "app" {
  name         = "${local.name_prefix}-app"
  user_pool_id = aws_cognito_user_pool.this.id

  generate_secret               = false
  prevent_user_existence_errors = "ENABLED"
  enable_token_revocation       = true

  explicit_auth_flows = [
    "ALLOW_USER_PASSWORD_AUTH",
    "ALLOW_USER_SRP_AUTH",
    "ALLOW_REFRESH_TOKEN_AUTH",
  ]

  # Short-lived access and id tokens, a longer refresh token.
  access_token_validity  = 60
  id_token_validity      = 60
  refresh_token_validity = 30

  token_validity_units {
    access_token  = "minutes"
    id_token      = "minutes"
    refresh_token = "days"
  }

  # Hosted UI / authorization-code flow for a future web front end. The addresses are placeholders
  # on the delegated domain (there is no web app yet) plus a local development address.
  supported_identity_providers         = ["COGNITO"]
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["code"]
  allowed_oauth_scopes                 = ["openid", "email", "profile"]
  callback_urls                        = ["https://app.${var.domain}/callback", "http://localhost:3000/callback"]
  logout_urls                          = ["https://app.${var.domain}/", "http://localhost:3000/"]
}

resource "aws_cognito_user_group" "admin" {
  name         = "admin"
  user_pool_id = aws_cognito_user_pool.this.id
  description  = "May create and change venues, events and ticket types (catalog service)."
}

# The domain prefix must be globally unique and must not contain "aws", "amazon" or "cognito".
resource "aws_cognito_user_pool_domain" "this" {
  domain       = "${replace(var.domain, ".", "-")}-${var.environment}"
  user_pool_id = aws_cognito_user_pool.this.id
}
