# The name is known without the record, so the fqdn stays stable for outputs and the bot
# contract while wound down. `record_exists` says whether it actually resolves.
output "fqdn" { value = trimsuffix("${var.label}.${data.aws_route53_zone.shared.name}", ".") }
output "record_exists" { value = length(aws_route53_record.game) == 1 }
output "zone_name" { value = data.aws_route53_zone.shared.name }
