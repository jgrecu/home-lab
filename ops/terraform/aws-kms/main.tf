# Vault auto-unseal key. Losing this key = losing Vault data. Never destroy.
resource "aws_kms_key" "vault" {
  description             = "home-lab Vault auto-unseal"
  key_usage               = "ENCRYPT_DECRYPT"
  enable_key_rotation     = true
  deletion_window_in_days = 30

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_kms_alias" "vault" {
  name          = var.key_alias
  target_key_id = aws_kms_key.vault.key_id
}

resource "aws_iam_user" "vault" {
  name = var.iam_user_name
}

data "aws_iam_policy_document" "vault_unseal" {
  statement {
    sid       = "VaultUnseal"
    actions   = ["kms:Encrypt", "kms:Decrypt", "kms:DescribeKey"]
    resources = [aws_kms_key.vault.arn]
  }
}

resource "aws_iam_user_policy" "vault_unseal" {
  name   = "vault-unseal-kms"
  user   = aws_iam_user.vault.name
  policy = data.aws_iam_policy_document.vault_unseal.json
}

resource "aws_iam_access_key" "vault" {
  user = aws_iam_user.vault.name
}
