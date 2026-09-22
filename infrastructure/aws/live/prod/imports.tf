# TEMPORARY. Delete this file in a follow-up PR once the import has run.
#
# Import blocks are used rather than a local `terraform import` on purpose.
# A local import puts these resources into state while the config is still
# unmerged; in that window any other infrastructure PR merging would make CI
# see resources in state but absent from config, and plan a DESTROY of the
# live domain. Shipping the config and the import in one commit means that
# window never exists.
#
# Deleting this file later is a no-op: an `import` block is not a `removed`
# block, so removing it takes nothing out of state and destroys nothing.
#
# Both IDs were read from live AWS, and both formats are verified against
# the provider source: the zone takes a bare ID with no /hostedzone/
# prefix, and the domain association uses APPID/DOMAINNAME.

import {
  to = aws_route53_zone.primary
  id = "Z04527082WQQTNVJVH95M"
}

import {
  to = module.amplify.aws_amplify_domain_association.this[0]
  id = "du8gjlas8igsf/aervsolutions.com"
}
