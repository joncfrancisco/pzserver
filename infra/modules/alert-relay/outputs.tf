output "function_name" {
  description = "For `aws logs tail /aws/lambda/<name>` when an alert does not arrive."
  value       = aws_lambda_function.relay.function_name
}

output "log_group" {
  value = aws_cloudwatch_log_group.relay.name
}
