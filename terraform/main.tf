# =============================================================================
# main.tf
#
# Este archivo declara TODA la infraestructura en GCP.
# Terraform leerá este archivo y creará/actualizará/borrará recursos
# automáticamente cuando ejecutes "terraform apply".
#
# ANTES de usar este archivo por primera vez:
#   1. Ve a terraform/bootstrap/ y ejecuta ese Terraform para crear el
#      bucket del state (solo una vez).
#   2. Vuelve aquí y ejecuta:
#        terraform init -backend-config="bucket=TU_BUCKET_STATE"
#
# La configuración del backend está en backend.tf.
#
# Orden lógico:
#   1. Providers (conexión con GCP)
#   2. APIs que necesitamos habilitar
#   3. Red: VPC, subred, firewall
#   4. Cuentas de servicio (identidades de los servicios)
#   5. Cloud Storage (código del backend)
#   6. VPC Access Connector (para que Cloud Run llegue a la VPC)
#   7. Compute Engine: plantilla + MIG + autoscaling + health check
#   8. Internal Load Balancer
#   9. Cloud Run (proxy OAuth)
# =============================================================================


# -----------------------------------------------------------------------------
# 1. PROVIDERS
# Le decimos a Terraform que vamos a usar GCP (Google Cloud).
# El project_id y region vienen de variables.tf / terraform.tfvars.
# -----------------------------------------------------------------------------
provider "google" {
  project = var.project_id
  region  = var.region
}

# Este segundo provider es necesario para recursos "beta" de GCP
# (como el MIG regional con GPU).
provider "google-beta" {
  project = var.project_id
  region  = var.region
}


# -----------------------------------------------------------------------------
# 3. APIs DE GCP
# Las APIs se habilitan manualmente antes del primer despliegue (ver guía).
# No se gestionan con Terraform para evitar requerir permisos de serviceusage.
# Comando: gcloud services enable compute.googleapis.com run.googleapis.com ...
# -----------------------------------------------------------------------------


# -----------------------------------------------------------------------------
# 4. RED: VPC
# Una red virtual privada aislada para todos nuestros recursos.
# -----------------------------------------------------------------------------
resource "google_compute_network" "vpc" {
  name                    = var.vpc_name
  auto_create_subnetworks = false # Creamos las subredes manualmente (más control)

}

# Subred principal donde vivirán las instancias del MIG y el LB
resource "google_compute_subnetwork" "main" {
  name          = var.subnet_name
  network       = google_compute_network.vpc.id
  region        = var.region
  ip_cidr_range = var.subnet_cidr
}

# Subred especial que GCP necesita para el Internal HTTP(S) Load Balancer.
# Solo sirve para el "proxy" interno del LB, no para VMs.
resource "google_compute_subnetwork" "proxy" {
  name          = "${var.subnet_name}-proxy"
  network       = google_compute_network.vpc.id
  region        = var.region
  ip_cidr_range = var.proxy_subnet_cidr
  purpose       = "REGIONAL_MANAGED_PROXY"
  role          = "ACTIVE"
}

# Regla de firewall: permite que el Load Balancer haga health checks a las VMs
resource "google_compute_firewall" "allow_health_checks" {
  name    = "${var.vpc_name}-allow-health-checks"
  network = google_compute_network.vpc.name

  allow {
    protocol = "tcp"
    ports    = ["8000"] # Puerto donde escucha el backend FastAPI
  }

  # Estos rangos son las IPs de los health checkers de Google
  source_ranges = ["130.211.0.0/22", "35.191.0.0/16"]
}

# Regla de firewall: permite tráfico interno entre el proxy LB y las VMs
resource "google_compute_firewall" "allow_internal" {
  name    = "${var.vpc_name}-allow-internal"
  network = google_compute_network.vpc.name

  allow {
    protocol = "tcp"
    ports    = ["8000"]
  }

  source_ranges = [var.subnet_cidr, var.proxy_subnet_cidr]
}


# -----------------------------------------------------------------------------
# 5. CUENTAS DE SERVICIO
# Son como "usuarios" para los servicios (no para personas).
# Principio de mínimo privilegio: cada servicio solo tiene los permisos
# que necesita.
# -----------------------------------------------------------------------------

# Las service accounts se crean manualmente antes del primer despliegue.
# Construimos el email directamente (formato estándar de GCP) sin necesidad
# de llamar a la API de IAM, evitando requerir iam.serviceAccounts.get.
locals {
  proxy_sa_email   = "oauth-proxy-sa@${var.project_id}.iam.gserviceaccount.com"
  backend_sa_email = "ia-backend-sa@${var.project_id}.iam.gserviceaccount.com"
}

# Roles del backend SA asignados manualmente (ver guía de despliegue):
#   gcloud projects add-iam-policy-binding PROJECT --role=roles/storage.objectViewer ...
#   gcloud projects add-iam-policy-binding PROJECT --role=roles/logging.logWriter ...
#   gcloud projects add-iam-policy-binding PROJECT --role=roles/monitoring.metricWriter ...


# -----------------------------------------------------------------------------
# 6. CLOUD STORAGE
# Bucket donde guardamos el código Python del backend.
# El startup-script de cada VM descargará el código desde aquí al arrancar.
# -----------------------------------------------------------------------------
resource "google_storage_bucket" "backend_code" {
  name          = var.bucket_name
  location      = var.region
  force_destroy = false # Protege contra borrados accidentales

  # Versionado: guarda versiones anteriores del código (útil para rollback)
  versioning {
    enabled = true
  }

  # Borra versiones antiguas después de 30 días para no acumular costes
  lifecycle_rule {
    condition { num_newer_versions = 3 }
    action { type = "Delete" }
  }
}


# -----------------------------------------------------------------------------
# 7. VPC ACCESS CONNECTOR
# Permite que Cloud Run (que vive fuera de nuestra VPC) se comunique con
# recursos internos (el Internal Load Balancer).
# -----------------------------------------------------------------------------
resource "google_vpc_access_connector" "connector" {
  provider = google-beta

  name   = "ia-vpc-connector"
  region = var.region

  # El conector requiere una subred /28 dedicada.
  # Usamos ip_cidr_range para que cree su propio bloque /28 dentro de la VPC.
  network       = google_compute_network.vpc.name
  ip_cidr_range = "10.10.2.0/28"

  min_instances = 2
  max_instances = 3
}


# -----------------------------------------------------------------------------
# 8. HEALTH CHECK
# GCP comprueba periódicamente si las VMs están sanas llamando a /healthz.
# Si una VM no responde, el MIG la reemplaza automáticamente.
# -----------------------------------------------------------------------------
resource "google_compute_health_check" "backend_hc" {
  name = "ia-backend-hc"

  http_health_check {
    port         = 8000
    request_path = "/healthz"
  }

  check_interval_sec  = 10 # Comprueba cada 10 segundos
  timeout_sec         = 5  # Espera 5 segundos por respuesta
  healthy_threshold   = 2  # 2 respuestas OK = sano
  unhealthy_threshold = 3  # 3 fallos = no sano (reemplazar VM)
}


# -----------------------------------------------------------------------------
# 9. INSTANCE TEMPLATE (plantilla de VM)
# Define cómo debe ser cada instancia del MIG:
# sistema operativo, tipo de máquina, GPU, cuenta de servicio, etc.
# Cuando cambias la plantilla, el MIG actualiza las VMs una a una (rolling update).
# -----------------------------------------------------------------------------
resource "google_compute_instance_template" "backend" {
  provider = google-beta

  name_prefix  = "ia-backend-"
  machine_type = var.machine_type

  # Sistema operativo base
  disk {
    source_image = "debian-cloud/debian-12"
    auto_delete  = true
    boot         = true
    disk_size_gb = 50
  }

  network_interface {
    subnetwork = google_compute_subnetwork.main.id
    # Sin IP pública (acceso solo por la red interna)
  }

  # Cuenta de servicio de la VM (define los permisos de la VM)
  service_account {
    email  = local.backend_sa_email
    scopes = ["cloud-platform"]
  }

  scheduling {
    on_host_maintenance = "TERMINATE" # Obligatorio con GPU
    automatic_restart   = true
  }

  # Metadata que el startup-script lee para configurarse
  metadata = {
    # El startup-script se ejecuta la primera vez que arranca la VM
    startup-script = file("${path.module}/../backend_gce/startup-script.sh")

    # URL del servicio Cloud Run (audience del token OIDC)
    # Se actualiza después del primer deploy con un rolling update
    expected-audience        = "https://${var.cloud_run_service_name}-placeholder.run.app"
    allowed-service-account  = local.proxy_sa_email
    app-source-bucket        = google_storage_bucket.backend_code.name
  }

  # Cuando cambias la plantilla, Terraform crea una nueva versión automáticamente
  lifecycle {
    create_before_destroy = true
  }

}


# -----------------------------------------------------------------------------
# 10. MANAGED INSTANCE GROUP (MIG) REGIONAL - MULTI-ZONA
# El MIG gestiona automáticamente un grupo de VMs idénticas.
# "Regional" significa que reparte las VMs entre las zonas disponibles
# de la región para conseguir alta disponibilidad (SLO 99.95%).
# -----------------------------------------------------------------------------
resource "google_compute_region_instance_group_manager" "mig" {
  provider = google-beta

  name   = "ia-backend-mig"
  region = var.region

  base_instance_name = "ia-backend"

  # Usa la plantilla que definimos arriba
  version {
    instance_template = google_compute_instance_template.backend.id
  }

  # Usa el health check para autohealing (reemplazar VMs no sanas)
  auto_healing_policies {
    health_check      = google_compute_health_check.backend_hc.id
    initial_delay_sec = 300 # Espera 5 min antes del primer health check (boot + GPU init)
  }

  named_port {
    name = "http"
    port = 8000
  }

  # Actualización sin downtime: cambia las VMs de una en una (rolling update)
  update_policy {
    type                  = "PROACTIVE"
    minimal_action        = "REPLACE"
    # En un MIG regional con 3 zonas, max_surge debe ser 0 o >= 3.
    # Usamos 0 (sin surge) + 1 no disponible: actualiza de una en una
    # sin crear instancias extra, lo que reduce coste durante updates.
    max_surge_fixed       = 3  # >= número de zonas (europe-west1 tiene 3)
    max_unavailable_fixed = 0  # sin downtime durante updates
  }

  depends_on = [google_compute_health_check.backend_hc]
}

# Autoscaling: añade/quita VMs según el uso de CPU
resource "google_compute_region_autoscaler" "backend" {
  name   = "ia-backend-autoscaler"
  region = var.region
  target = google_compute_region_instance_group_manager.mig.id

  autoscaling_policy {
    min_replicas    = var.mig_min_replicas
    max_replicas    = var.mig_max_replicas
    cooldown_period = 120 # Espera 2 min entre escalados para evitar flapping

    cpu_utilization {
      target = var.mig_target_cpu
    }
  }
}


# -----------------------------------------------------------------------------
# 11. INTERNAL HTTP(S) LOAD BALANCER
# Distribuye el tráfico entre las VMs del MIG.
# Es "interno": solo accesible desde dentro de la VPC (no desde Internet).
# Componentes (de atrás hacia adelante):
#   Backend Service -> URL Map -> Target HTTP Proxy -> Forwarding Rule
# -----------------------------------------------------------------------------

# Backend Service: define qué grupo de VMs recibe el tráfico
resource "google_compute_region_backend_service" "backend" {
  name                  = "ia-backend-service"
  region                = var.region
  protocol              = "HTTP"
  port_name             = "http"
  load_balancing_scheme = "INTERNAL_MANAGED"

  backend {
    group           = google_compute_region_instance_group_manager.mig.instance_group
    balancing_mode  = "UTILIZATION"
    capacity_scaler = 1.0
  }

  health_checks = [google_compute_health_check.backend_hc.id]
}

# URL Map: define las reglas de enrutamiento (aquí todo va al mismo backend)
resource "google_compute_region_url_map" "backend" {
  name            = "ia-backend-url-map"
  region          = var.region
  default_service = google_compute_region_backend_service.backend.id
}

# Target HTTP Proxy: recibe las conexiones y las enruta según el URL Map
resource "google_compute_region_target_http_proxy" "backend" {
  name    = "ia-backend-http-proxy"
  region  = var.region
  url_map = google_compute_region_url_map.backend.id
}

# Forwarding Rule: la "entrada" del Load Balancer (IP + puerto)
resource "google_compute_forwarding_rule" "backend" {
  name                  = "ia-backend-fr"
  region                = var.region
  load_balancing_scheme = "INTERNAL_MANAGED"
  network               = google_compute_network.vpc.id
  subnetwork            = google_compute_subnetwork.main.id
  ip_address            = var.ilb_ip
  port_range            = "80"
  target                = google_compute_region_target_http_proxy.backend.id

  depends_on = [google_compute_subnetwork.proxy]
}


# -----------------------------------------------------------------------------
# 12. CLOUD RUN - PROXY OAUTH
# El proxy que recibe las peticiones de Jira, obtiene el token OIDC
# y las reenvía al backend de IA.
# -----------------------------------------------------------------------------
resource "google_cloud_run_v2_service" "proxy" {
  name     = var.cloud_run_service_name
  location = var.region

  template {
    service_account = local.proxy_sa_email

    # Configuración de red: usa el VPC Connector para llegar al ILB interno
    vpc_access {
      connector = google_vpc_access_connector.connector.id
      egress    = "PRIVATE_RANGES_ONLY" # Solo el tráfico a IPs privadas va por la VPC
    }

    # Escala a 0 cuando no hay tráfico (coste 0 en reposo)
    scaling {
      min_instance_count = 0
      max_instance_count = 10
    }

    containers {
      image = var.cloud_run_image

      env {
        name  = "BACKEND_URL"
        value = "http://${var.ilb_ip}"
      }

      # La API Key de Jira se pasa como variable de entorno (marcada como sensitive)
      env {
        name  = "JIRA_API_KEY"
        value = var.jira_api_key
      }

      resources {
        limits = {
          cpu    = "1"
          memory = "512Mi"
        }
      }
    }
  }

  depends_on = [
    google_vpc_access_connector.connector,
    google_compute_forwarding_rule.backend,
  ]
}

# Permite que cualquiera llame al Cloud Run sin autenticación de Google
# (la autenticación la hace nuestro proxy con la API Key de Jira)
resource "google_cloud_run_v2_service_iam_member" "public" {
  name     = google_cloud_run_v2_service.proxy.name
  location = var.region
  role     = "roles/run.invoker"
  member   = "allUsers"
}
