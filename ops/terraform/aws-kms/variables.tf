variable "aws_region" {
  description = "AWS region for the Vault unseal key (eu-south-2 = Spain)"
  type        = string
  default     = "eu-south-2"
}

variable "aws_profile" {
  description = "Local AWS CLI profile with admin rights used to create the resources (null = default credential chain)"
  type        = string
  default     = null
}

variable "key_alias" {
  description = "KMS alias for the Vault seal key"
  type        = string
  default     = "alias/home-lab-vault"
}

variable "iam_user_name" {
  description = "IAM user Vault uses to call KMS"
  type        = string
  default     = "vault-unseal"
}
