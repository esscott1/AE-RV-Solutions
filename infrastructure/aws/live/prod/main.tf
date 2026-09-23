# Imported, not created. `comment` and `tags` mirror the console-created
# zone exactly: Terraform defaults the comment to "Managed by Terraform" and
# tags to empty, so omitting either would show a permanent diff and would
# try to strip the tag.
#
# No aws_route53_record resources belong here. Amplify writes the apex
# A-ALIAS, the www CNAME and the ACM validation CNAME itself; declaring them
# would fight Amplify for ownership.
resource "aws_route53_zone" "primary" {
  name    = var.domain_name
  comment = "The domain for A&E RV solutions."

  tags = {
    Customer = "AERVSolutions"
  }

  # A recreated zone gets new nameservers, and the domain stops resolving
  # until they're changed at GoDaddy. To delete it deliberately, remove this
  # in its own PR first.
  lifecycle {
    prevent_destroy = true
  }
}

module "amplify" {
  source = "../../modules/amplify"

  app_name            = "ae-rv-solutions-prod"
  repository_url      = var.repository_url
  branch_name         = "main"
  app_root            = "site"
  github_access_token = var.github_access_token
  domain_name         = var.domain_name

  # Build-time settings for the site's chat widget. Astro only exposes
  # PUBLIC_-prefixed variables to browser code. Both values are public by
  # design (the key only applies the usage plan), so they appear in plan
  # output. Changing them doesn't trigger a build (auto-build is off); the
  # next site deploy picks them up.
  environment_variables = {
    PUBLIC_CHAT_API_URL = module.chatbot.chat_api_url
    PUBLIC_CHAT_API_KEY = module.chatbot.chat_api_key
  }

  # Amplify writes the validation and routing records into the zone, so the
  # zone must exist first. Nothing in the association references the zone,
  # so without this the ordering is invisible to Terraform and a
  # from-scratch apply could race.
  depends_on = [aws_route53_zone.primary]
}

# Public website chatbot: on/off flag, safety gate, Bedrock (Claude Haiku
# 4.5), and volume limits. Its CI permissions, toggle role, and owner-alert
# topic live in bootstrap/chatbot.tf.
module "chatbot" {
  source = "../../modules/chatbot"

  tags = {
    Customer = "AERVSolutions"
  }
}
