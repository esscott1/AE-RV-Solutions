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
}

module "amplify" {
  source = "../../modules/amplify"

  app_name            = "ae-rv-solutions-prod"
  repository_url      = var.repository_url
  branch_name         = "main"
  app_root            = "site"
  github_access_token = var.github_access_token
  domain_name         = var.domain_name

  # Amplify writes the validation and routing records into the zone, so the
  # zone must exist first. Nothing in the association references the zone,
  # so without this the ordering is invisible to Terraform and a
  # from-scratch apply could race.
  depends_on = [aws_route53_zone.primary]
}
