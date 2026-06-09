###############################################################################
# Shared data sources
###############################################################################

# Latest Amazon Linux 2023 x86_64 AMI. Used by the client fleet (always) and the
# self-managed NFS server (when selected). Ungated on purpose: the lookup is free
# and a single source keeps the whole harness on one image. Swap to Ubuntu by
# changing the name filter / owner if preferred.
data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }

  filter {
    name   = "state"
    values = ["available"]
  }
}
