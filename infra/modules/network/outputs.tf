output "vpc_id" { value = aws_vpc.this.id }
output "public_subnet_id" { value = aws_subnet.public.id }
output "game_security_group_id" { value = aws_security_group.game.id }
output "bot_security_group_id" { value = aws_security_group.bot.id }
