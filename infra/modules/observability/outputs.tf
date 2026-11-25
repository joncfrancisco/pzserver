output "budget_name" { value = aws_budgets_budget.stack.name }
output "state_change_rule_arn" { value = one(aws_cloudwatch_event_rule.state_change[*].arn) }
