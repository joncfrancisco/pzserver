variable "enabled" {
  description = "false leaves the record out. It goes with the game EIP: a record left pointing at a released address is a takeover risk."
  type        = bool
  default     = true
}
variable "zone_id" { type = string }
variable "label" { type = string }
variable "target_ip" {
  type    = string
  default = null
}
