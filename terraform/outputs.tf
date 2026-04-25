# outputs.tf — placeholders
#
# Outputs become live as the corresponding modules are uncommented in main.tf
# during Phase 1 build. They stay commented here so `terraform plan` on the
# stub does not error on undefined module references.

# output "vpc_id" {
#   description = "VPC identifier"
#   value       = module.vpc.vpc_id
# }
#
# output "rds_endpoint" {
#   description = "RDS PostgreSQL endpoint (private)"
#   value       = module.rds.db_instance_endpoint
#   sensitive   = true
# }
#
# output "client_vpn_endpoint_id" {
#   description = "Client VPN endpoint identifier"
#   value       = aws_ec2_client_vpn_endpoint.main.id
# }
