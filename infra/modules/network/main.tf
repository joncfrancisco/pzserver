# One VPC, one public subnet, one IGW. No NAT gateway -- at ~$32/month it would cost
# more than the game server itself, and nothing here needs egress from a private subnet.
#
# Note this account has NO default VPC in us-east-1 (verified 2026-08-22), so there is
# nothing to reuse and nothing to collide with.

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${var.name_prefix}-vpc" }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.name_prefix}-igw" }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.this.id
  cidr_block              = var.public_subnet_cidr
  availability_zone       = var.availability_zone
  map_public_ip_on_launch = false # the game server gets an EIP; the bot host gets one too

  tags = { Name = "${var.name_prefix}-public-a" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = { Name = "${var.name_prefix}-public-rt" }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# --- Security groups ---------------------------------------------------------------

# The bot is defined first because sg-game references it as an ingress source.
resource "aws_security_group" "bot" {
  name        = "${var.name_prefix}-bot"
  description = "PZ Discord bot host. Purely a client: no inbound at all."
  vpc_id      = aws_vpc.this.id

  tags = { Name = "${var.name_prefix}-bot" }
}

resource "aws_vpc_security_group_egress_rule" "bot_all" {
  security_group_id = aws_security_group.bot.id
  description       = "Discord gateway (WSS), AWS APIs, RCON to the game server."
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

resource "aws_security_group" "game" {
  name        = "${var.name_prefix}-game"
  description = "PZ game server. Game traffic from the world; RCON from the bot only."
  vpc_id      = aws_vpc.this.id

  tags = { Name = "${var.name_prefix}-game" }
}

# The game itself. This is the only thing open to the internet and it cannot be avoided.
resource "aws_vpc_security_group_ingress_rule" "game_udp" {
  security_group_id = aws_security_group.game.id
  description       = "Project Zomboid game traffic"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "udp"
  from_port         = 16261
  to_port           = 16262
}

# Only needed when the server advertises itself in the in-game public browser
# (Public=true in the .ini). Off by default.
resource "aws_vpc_security_group_ingress_rule" "game_steam" {
  count = var.public_server ? 1 : 0

  security_group_id = aws_security_group.game.id
  description       = "Steam server browser query ports (Public=true only)"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "udp"
  from_port         = 8766
  to_port           = 8767
}

# RCON is a plaintext protocol with a weak auth handshake (DESIGN C7). Source-restricted
# to the bot's security group -- never a CIDR, never 0.0.0.0/0. On the public internet
# this port is a full-control backdoor into the server.
resource "aws_vpc_security_group_ingress_rule" "game_rcon" {
  security_group_id            = aws_security_group.game.id
  description                  = "RCON from the bot host only"
  referenced_security_group_id = aws_security_group.bot.id
  ip_protocol                  = "tcp"
  from_port                    = 27015
  to_port                      = 27015
}

# No port 22 rule anywhere in this file, on purpose. Shell access is SSM Session Manager.

resource "aws_vpc_security_group_egress_rule" "game_all" {
  security_group_id = aws_security_group.game.id
  description       = "SteamCMD, S3 backups, CloudWatch, SSM."
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}
