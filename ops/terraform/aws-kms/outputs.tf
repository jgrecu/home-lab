output "aws_region" {
  value = var.aws_region
}

output "kms_key_id" {
  value = aws_kms_key.vault.key_id
}

output "kms_key_arn" {
  value = aws_kms_key.vault.arn
}

output "access_key_id" {
  value = aws_iam_access_key.vault.id
}

output "secret_access_key" {
  value     = aws_iam_access_key.vault.secret
  sensitive = true
}
