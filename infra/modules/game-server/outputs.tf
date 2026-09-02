output "instance_id" { value = aws_instance.game.id }
output "public_ip" { value = aws_eip.game.public_ip }
output "private_ip" { value = aws_instance.game.private_ip }
output "data_volume_id" { value = aws_ebs_volume.data.id }
output "role_arn" { value = aws_iam_role.game.arn }

output "ssm_document_arns" {
  description = "ARNs of the scoped SSM documents pz-bot-role is allowed to invoke (issue #29)."
  value = [
    aws_ssm_document.backup.arn,
    aws_ssm_document.restore.arn,
    aws_ssm_document.lifecycle.arn,
    aws_ssm_document.config_read.arn,
    aws_ssm_document.config_write.arn,
    aws_ssm_document.sandbox.arn,
    aws_ssm_document.idle_retune.arn,
    aws_ssm_document.version.arn,
    aws_ssm_document.mods.arn,
  ]
}
