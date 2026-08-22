output "instance_id" { value = aws_instance.bot.id }
output "public_ip" { value = aws_eip.bot.public_ip }
output "private_ip" { value = aws_instance.bot.private_ip }
output "role_arn" { value = aws_iam_role.bot.arn }
