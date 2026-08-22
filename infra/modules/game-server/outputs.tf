output "instance_id" { value = aws_instance.game.id }
output "public_ip" { value = aws_eip.game.public_ip }
output "private_ip" { value = aws_instance.game.private_ip }
output "data_volume_id" { value = aws_ebs_volume.data.id }
output "role_arn" { value = aws_iam_role.game.arn }
