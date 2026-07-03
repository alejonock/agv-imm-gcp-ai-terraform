# =============================================================================
# backend.tf
#
#   En lugar de hardcodear el nombre del bucket aquí (lo que obligaría a
#   editar el código fuente en cada proyecto), usamos "configuración parcial":
#   dejamos el bloque vacío y pasamos los valores en el comando terraform init
#   mediante -backend-config.
#
#   La pipeline y el script de bootstrap lo hacen automáticamente.
#   Si ejecutas Terraform manualmente:
#
#     terraform init \
#       -backend-config="bucket=TU_PROYECTO-tf-state" \
#       -backend-config="prefix=ia-gcp/state"
#
# =============================================================================

terraform {
  required_version = ">= 1.6"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = "~> 5.0"
    }
  }

  # Configuración parcial: el nombre del bucket se pasa con -backend-config
  # en terraform init (ver pipeline y README).
  backend "gcs" {
    prefix = "ia-gcp/state"
    # bucket = se pasa como: terraform init -backend-config="bucket=NOMBRE"
  }
}
