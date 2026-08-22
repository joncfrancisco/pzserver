# joncfrancis.co is shared with foodblog: the apex and www A records point at the
# Lightsail box that serves the blog. This module deliberately reads the zone as a DATA
# source and creates exactly ONE record inside it.
#
# The consequence that matters: the hosted zone is never a managed resource in this
# stack's state, so `terraform destroy` here removes the pz record and nothing else.
# There is no code path in this repo that can delete the blog's DNS.

data "aws_route53_zone" "shared" {
  zone_id = var.zone_id
}

# DESIGN section 5 weighed an Elastic IP against "a Route 53 A record updated on each
# boot", and picked the EIP to keep DNS propagation out of the start path. Sharing
# joncfrancis.co lets us have both without that trade-off: the record targets the EIP,
# which never changes, so it is written once here at apply time and never touched at
# boot. Players get a memorable address, and the start path has no DNS step in it.
#
# It is also free: Route 53 bills per hosted zone, and foodblog already pays the $0.50.
resource "aws_route53_record" "game" {
  zone_id = data.aws_route53_zone.shared.zone_id
  name    = "${var.label}.${data.aws_route53_zone.shared.name}"
  type    = "A"
  ttl     = 300 # matches the apex/www records already in this zone
  records = [var.target_ip]
}
