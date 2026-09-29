resource "random_password" "db" {
  count = local.create_database ? 1 : 0

  length  = 32
  special = false
}

###############################################################################
# Database secret - consumed by ECS tasks via valueFrom.
# Created and populated only when Terraform manages the DB. When reusing an
# existing database (var.db_host set), the secret already exists and is read
# via the data source below instead.
###############################################################################

resource "aws_secretsmanager_secret" "database" {
  count = local.create_database ? 1 : 0

  name                    = "${var.project}/${var.environment}/database"
  description             = "Database connection details for ${local.name_prefix}"
  recovery_window_in_days = 0

  tags = local.default_tags
}

resource "aws_secretsmanager_secret_version" "database" {
  count = local.create_database ? 1 : 0

  secret_id = aws_secretsmanager_secret.database[0].id

  secret_string = jsonencode({
    DATABASE_URL = local.database_url
    engine       = "postgres"
    host         = local.db_host
    port         = tostring(local.db_port)
    dbname       = var.db_name
    username     = var.db_username
    password     = local.db_password
  })
}

data "aws_secretsmanager_secret" "database" {
  count = local.create_database ? 0 : 1
  name  = "${var.project}/${var.environment}/database"
}

###############################################################################
# Application secret - every credential this app owns itself, in one place.
#
# Deliberately merged (Shopify + API docs, and anything app-level added later)
# because they share one owner and one lifecycle: a person edits them in the
# console, on no fixed schedule. The database secret stays separate because its
# owner is the database, not us — see the block above.
#
# Keys the ECS task definitions read by name:
#   docs_username, docs_password   -> web container basic-auth for /docs
# Shopify keys are read by the application itself, not injected here, so their
# names are the app's business.
###############################################################################

resource "aws_secretsmanager_secret" "app" {
  name                    = "${var.project}/${var.environment}/app"
  description             = "Application credentials (Shopify, API docs) for ${local.name_prefix}"
  recovery_window_in_days = 0

  tags = local.default_tags
}

resource "aws_secretsmanager_secret_version" "app" {
  secret_id     = aws_secretsmanager_secret.app.id
  secret_string = var.app_secret_value

  lifecycle {
    # Seeded as {} and filled in the console. Keeping real credentials out of
    # .env and out of Terraform state is the whole point of putting them here.
    ignore_changes = [secret_string]
  }
}
