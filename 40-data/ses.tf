# E-MAIL: the Amazon SES identity for the delegated domain, with DKIM, plus one verified recipient
# for the sandbox.
#
# HOW SES SENDING WORKS. The notifications worker sends "your tickets" mail through SES (SendEmail).
# Mail providers (Gmail, Microsoft 365) only trust a message if they can check it really comes from
# the domain in the From address. DKIM does that: SES signs each message with a private key, and the
# matching PUBLIC key is published in DNS. SES gives three tokens; we publish three CNAME records
# <token>._domainkey.<domain> pointing at <token>.dkim.amazonses.com; SES then rotates the keys
# itself. Because the identity is the whole subdomain, ANY address @<domain> is allowed as the sender
# (SES_FROM_ADDRESS = noreply@<domain>). The records live in the zone of 05-dns, so verification
# completes by itself within minutes.
#
# DMARC: one TXT record telling receivers what to do with mail that fails the checks. p=none only
# REPORTS (no rejection) and is the usual first step; production tightens it to quarantine/reject.
#
# THE SANDBOX. A new SES account may only send to verified addresses and at most 200 messages a day.
# Leaving the sandbox needs a support request and is not worth it for a learning project, so the
# worker is run with EMAIL_RECIPIENT_OVERRIDE = var.ses_sandbox_recipient: every mail goes to that one
# verified address (AWS mails it a link to click once), whoever the order belongs to.
#
# CONFIGURATION SET: a named bundle of sending settings. Here: TLS is REQUIRED on delivery (a message
# is not sent over an unencrypted connection) and reputation metrics are on (bounce and complaint
# rates show in CloudWatch). The worker names it in every send.
#
# Related files: data.tf (the zone), config.tf (publishes the from address, set and recipient),
# 50-workloads (the worker may SendEmail from this identity and set only).

resource "aws_sesv2_email_identity" "domain" {
  email_identity = var.domain

  dkim_signing_attributes {
    next_signing_key_length = "RSA_2048_BIT"
  }
}

resource "aws_route53_record" "dkim" {
  count = 3

  zone_id = data.aws_route53_zone.this.zone_id
  name    = "${aws_sesv2_email_identity.domain.dkim_signing_attributes[0].tokens[count.index]}._domainkey.${var.domain}"
  type    = "CNAME"
  ttl     = 600
  records = ["${aws_sesv2_email_identity.domain.dkim_signing_attributes[0].tokens[count.index]}.dkim.amazonses.com"]
}

resource "aws_route53_record" "dmarc" {
  zone_id = data.aws_route53_zone.this.zone_id
  name    = "_dmarc.${var.domain}"
  type    = "TXT"
  ttl     = 600
  records = ["v=DMARC1; p=none;"]
}

resource "aws_sesv2_email_identity" "sandbox_recipient" {
  email_identity = var.ses_sandbox_recipient
}

resource "aws_sesv2_configuration_set" "this" {
  configuration_set_name = local.name_prefix

  delivery_options {
    tls_policy = "REQUIRE"
  }

  reputation_options {
    reputation_metrics_enabled = true
  }

  sending_options {
    sending_enabled = true
  }
}
