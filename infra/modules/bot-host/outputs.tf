output "instance_id" { value = one(aws_instance.bot[*].id) }
output "public_ip" { value = one(aws_eip.bot[*].public_ip) }
output "private_ip" { value = one(aws_instance.bot[*].private_ip) }
output "role_arn" { value = aws_iam_role.bot.arn }
