output "fqdn" { value = trimsuffix(aws_route53_record.game.fqdn, ".") }
output "zone_name" { value = data.aws_route53_zone.shared.name }
