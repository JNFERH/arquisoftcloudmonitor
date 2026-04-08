# Infraestructura para arquisoftcloudmonitor (BITE.co FinOps Platform)
#
# Elementos a desplegar en AWS:
#
# 1. Grupos de seguridad:
#    - acm-traffic-kong   (puertos 8000 y 8001)
#    - acm-traffic-django (puerto 8080)
#    - acm-traffic-db     (puerto 5432)
#    - acm-traffic-cache  (puerto 6379 - Redis)
#    - acm-traffic-ssh    (puerto 22)
#
# 2. Instancias EC2:
#    - acm-kong                      (Kong API Gateway)
#    - acm-finops-{a,b,c}            (3x Django - Manejador de FinOps)
#    - acm-reports-{a,b,c}           (3x Django - Manejador de Reportes + Notificaciones)
#    - acm-orgs                      (1x Django - Manejador de Organizaciones + API AUTH)
#    - acm-db-finops                  (PostgreSQL - Base de Datos Consumo Cloud / FinOps)
#    - acm-db-reports                 (PostgreSQL - Base de Datos Consumo Cloud / Reportes)
#    - acm-db-auth                    (PostgreSQL - Base de Datos Autenticación y Autorización)
#    - acm-cache                      (Redis - Reportes precalculados, TTL 1 mes)
#
# 3. Almacenamiento:
#    - acm-cold-storage               (S3 Bucket - Almacenamiento en frío > 24 meses)
#
# Patrón Kong (igual al ejemplo de clase):
#    - finops_upstream    → balancea tráfico entre acm-finops-{a,b,c}
#    - reports_upstream   → balancea tráfico entre acm-reports-{a,b,c}
#    - orgs_upstream      → apunta a acm-orgs
# ******************************************************************

# Variable. Define la región de AWS donde se desplegará la infraestructura.
variable "region" {
  description = "AWS region for deployment"
  type        = string
  default     = "us-east-1"
}

# Variable. Define el prefijo usado para nombrar los recursos en AWS.
variable "project_prefix" {
  description = "Prefix used for naming AWS resources"
  type        = string
  default     = "acm"
}

# Variable. Define el tipo de instancia EC2.
# El diagrama especifica Ram 8GB / vCPU 4 → t3.large.
# Para reducir costos en el lab se puede cambiar a t2.micro.
variable "instance_type" {
  description = "EC2 instance type for application and database hosts"
  type        = string
  default     = "t2.micro"
}

# Variable. Personal Access Token de GitHub para clonar el repositorio privado.
# Pásalo al aplicar: terraform apply -var="github_token=ghp_TU_TOKEN"
# O crea terraform.tfvars con: github_token = "ghp_TU_TOKEN"
variable "github_token" {
  description = "GitHub Personal Access Token to clone the private repository"
  type        = string
  sensitive   = true
}

# Variable. Usuario de GitHub asociado al token.
variable "github_user" {
  description = "GitHub username associated with the token"
  type        = string
  default     = "JNFERH"
}

# Variable. Contraseña compartida para todos los usuarios de PostgreSQL.
variable "db_password" {
  description = "Password for all PostgreSQL database users"
  type        = string
  default     = "isis2503"
  sensitive   = true
}

# Variable. SECRET_KEY de Django.
# Genera una con: python3 -c "from django.core.management.utils import get_random_secret_key; print(get_random_secret_key())"
variable "django_secret_key" {
  description = "Django SECRET_KEY for the application"
  type        = string
  sensitive   = true
}

# Proveedor. Define el proveedor de infraestructura (AWS) y la región.
provider "aws" {
  region = var.region
}

# Variables locales usadas en la configuración de Terraform.
locals {
  project_name = "${var.project_prefix}-cloudmonitor"

  # URL con PAT embebido para clonar repo privado via HTTPS
  repository = "https://${var.github_user}:${var.github_token}@github.com/JNFERH/arquisoftcloudmonitor.git"
  branch     = "main"

  # Nombres de bases de datos
  db_finops_name  = "monitoring_db"
  db_reports_name = "costs_db"
  db_auth_name    = "auth_db"

  # Usuarios de PostgreSQL por cada DB
  db_finops_user  = "finops_user"
  db_reports_user = "reports_user"
  db_auth_user    = "auth_user"

  common_tags = {
    Project   = local.project_name
    ManagedBy = "Terraform"
  }
}

# Data Source. Busca la AMI más reciente de Ubuntu 24.04.
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# ─────────────────────────────────────────────
# GRUPOS DE SEGURIDAD
# ─────────────────────────────────────────────

# Recurso. Grupo de seguridad para Kong API Gateway (puertos 8000 proxy, 8001 admin).
resource "aws_security_group" "traffic_kong" {
  name        = "${var.project_prefix}-traffic-kong"
  description = "Expose Kong API Gateway proxy (8000) and admin (8001) ports"

  ingress {
    description = "Kong proxy and admin API"
    from_port   = 8000
    to_port     = 8001
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, {
    Name = "${var.project_prefix}-traffic-kong"
  })
}

# Recurso. Grupo de seguridad para Django (puerto 8080).
# Lo usan todos los API servers: finops, reports y orgs.
resource "aws_security_group" "traffic_django" {
  name        = "${var.project_prefix}-traffic-django"
  description = "Allow HTTP traffic to Django services on port 8080"

  ingress {
    description = "HTTP access for Django services"
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, {
    Name = "${var.project_prefix}-traffic-django"
  })
}

# Recurso. Grupo de seguridad para PostgreSQL (puerto 5432).
# Lo usan las tres instancias de DB.
resource "aws_security_group" "traffic_db" {
  name        = "${var.project_prefix}-traffic-db"
  description = "Allow PostgreSQL access on port 5432"

  ingress {
    description = "PostgreSQL traffic"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, {
    Name = "${var.project_prefix}-traffic-db"
  })
}

# Recurso. Grupo de seguridad para Redis (puerto 6379).
# Lo usa la instancia de cache (reportes precalculados).
resource "aws_security_group" "traffic_cache" {
  name        = "${var.project_prefix}-traffic-cache"
  description = "Allow Redis access on port 6379"

  ingress {
    description = "Redis cache traffic"
    from_port   = 6379
    to_port     = 6379
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, {
    Name = "${var.project_prefix}-traffic-cache"
  })
}

# Recurso. Grupo de seguridad para SSH (puerto 22) con egress abierto.
# El egress abierto es necesario para apt-get, git clone y pip install.
resource "aws_security_group" "traffic_ssh" {
  name        = "${var.project_prefix}-traffic-ssh"
  description = "Allow SSH access and all outbound traffic"

  ingress {
    description = "SSH access"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Allow all outbound traffic (apt, pip, git)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, {
    Name = "${var.project_prefix}-traffic-ssh"
  })
}

# ─────────────────────────────────────────────
# ALMACENAMIENTO EN FRÍO (S3)
# ─────────────────────────────────────────────

# Recurso. Bucket S3 para almacenamiento en frío.
# Recibe datos de las 3 DBs después de 24 meses (lifecycle policy).
# Los datos se migran automáticamente a S3 Glacier tras 24 meses.
resource "aws_s3_bucket" "cold_storage" {
  bucket = "${var.project_prefix}-cold-storage-${random_id.bucket_suffix.hex}"

  tags = merge(local.common_tags, {
    Name = "${var.project_prefix}-cold-storage"
    Role = "cold-storage"
  })
}

# Recurso. ID aleatorio para el sufijo del bucket S3 (los nombres de S3 son globales).
resource "random_id" "bucket_suffix" {
  byte_length = 4
}

# Recurso. Política de ciclo de vida del bucket S3.
# Mueve los objetos a Glacier (almacenamiento en frío) después de 730 días (24 meses).
resource "aws_s3_bucket_lifecycle_configuration" "cold_storage_lifecycle" {
  bucket = aws_s3_bucket.cold_storage.id

  rule {
    id     = "move-to-glacier-after-24-months"
    status = "Enabled"

    transition {
      days          = 730
      storage_class = "GLACIER"
    }
  }
}

# ─────────────────────────────────────────────
# INSTANCIA: KONG (API Gateway)
# ─────────────────────────────────────────────

# Recurso. Instancia EC2 para Kong API Gateway.
# Kong se despliega vacío — configurar upstreams manualmente vía SSH después del apply.
# Ver sección "Post-deploy: configurar Kong" al final de este archivo.
resource "aws_instance" "kong" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.instance_type
  associate_public_ip_address = true
  vpc_security_group_ids = [
    aws_security_group.traffic_kong.id,
    aws_security_group.traffic_ssh.id
  ]

  tags = merge(local.common_tags, {
    Name = "${var.project_prefix}-kong"
    Role = "api-gateway"
  })
}

# ─────────────────────────────────────────────
# BASE DE DATOS: FINOPS
# ─────────────────────────────────────────────

# Recurso. Instancia EC2 para la DB de consumo cloud (FinOps).
# Crea la base de datos monitoring_db usada por los 3 servidores acm-finops-{a,b,c}.
resource "aws_instance" "db_finops" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.instance_type
  associate_public_ip_address = true
  vpc_security_group_ids = [
    aws_security_group.traffic_db.id,
    aws_security_group.traffic_ssh.id
  ]

  user_data = <<-EOT
              #!/bin/bash
              set -e

              apt-get update -y
              apt-get install -y postgresql postgresql-contrib

              sudo -u postgres psql -c "CREATE USER ${local.db_finops_user} WITH PASSWORD '${var.db_password}';"
              sudo -u postgres createdb -O ${local.db_finops_user} ${local.db_finops_name}

              PG_HBA="/etc/postgresql/16/main/pg_hba.conf"
              PG_CONF="/etc/postgresql/16/main/postgresql.conf"
              echo "host all all 0.0.0.0/0 md5" | tee -a $PG_HBA
              echo "listen_addresses='*'"        | tee -a $PG_CONF
              echo "max_connections=2000"        | tee -a $PG_CONF

              systemctl restart postgresql
              EOT

  tags = merge(local.common_tags, {
    Name = "${var.project_prefix}-db-finops"
    Role = "database-finops"
  })
}

# ─────────────────────────────────────────────
# BASE DE DATOS: REPORTES
# ─────────────────────────────────────────────

# Recurso. Instancia EC2 para la DB de consumo cloud (Reportes).
# Crea la base de datos costs_db usada por los 3 servidores acm-reports-{a,b,c}.
resource "aws_instance" "db_reports" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.instance_type
  associate_public_ip_address = true
  vpc_security_group_ids = [
    aws_security_group.traffic_db.id,
    aws_security_group.traffic_ssh.id
  ]

  user_data = <<-EOT
              #!/bin/bash
              set -e

              apt-get update -y
              apt-get install -y postgresql postgresql-contrib

              sudo -u postgres psql -c "CREATE USER ${local.db_reports_user} WITH PASSWORD '${var.db_password}';"
              sudo -u postgres createdb -O ${local.db_reports_user} ${local.db_reports_name}

              PG_HBA="/etc/postgresql/16/main/pg_hba.conf"
              PG_CONF="/etc/postgresql/16/main/postgresql.conf"
              echo "host all all 0.0.0.0/0 md5" | tee -a $PG_HBA
              echo "listen_addresses='*'"        | tee -a $PG_CONF
              echo "max_connections=2000"        | tee -a $PG_CONF

              systemctl restart postgresql
              EOT

  tags = merge(local.common_tags, {
    Name = "${var.project_prefix}-db-reports"
    Role = "database-reports"
  })
}

# ─────────────────────────────────────────────
# BASE DE DATOS: AUTENTICACIÓN Y AUTORIZACIÓN
# ─────────────────────────────────────────────

# Recurso. Instancia EC2 para la DB de autenticación y autorización.
# Crea auth_db usada por la instancia acm-orgs (API AUTH).
resource "aws_instance" "db_auth" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.instance_type
  associate_public_ip_address = true
  vpc_security_group_ids = [
    aws_security_group.traffic_db.id,
    aws_security_group.traffic_ssh.id
  ]

  user_data = <<-EOT
              #!/bin/bash
              set -e

              apt-get update -y
              apt-get install -y postgresql postgresql-contrib

              sudo -u postgres psql -c "CREATE USER ${local.db_auth_user} WITH PASSWORD '${var.db_password}';"
              sudo -u postgres createdb -O ${local.db_auth_user} ${local.db_auth_name}

              PG_HBA="/etc/postgresql/16/main/pg_hba.conf"
              PG_CONF="/etc/postgresql/16/main/postgresql.conf"
              echo "host all all 0.0.0.0/0 md5" | tee -a $PG_HBA
              echo "listen_addresses='*'"        | tee -a $PG_CONF
              echo "max_connections=2000"        | tee -a $PG_CONF

              systemctl restart postgresql
              EOT

  tags = merge(local.common_tags, {
    Name = "${var.project_prefix}-db-auth"
    Role = "database-auth"
  })
}

# ─────────────────────────────────────────────
# CACHE: REDIS
# ─────────────────────────────────────────────

# Recurso. Instancia EC2 para Redis (Cache Server).
# Almacena reportes precalculados con TTL de 1 mes (2592000 segundos).
# Los servidores acm-reports-{a,b,c} consultan Redis antes de ir a la DB.
resource "aws_instance" "cache" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.instance_type
  associate_public_ip_address = true
  vpc_security_group_ids = [
    aws_security_group.traffic_cache.id,
    aws_security_group.traffic_ssh.id
  ]

  user_data = <<-EOT
              #!/bin/bash
              set -e

              apt-get update -y
              apt-get install -y redis-server

              # Configurar Redis para aceptar conexiones remotas
              sed -i "s/bind 127.0.0.1 -::1/bind 0.0.0.0/" /etc/redis/redis.conf

              # TTL por defecto: 1 mes = 2592000 segundos
              echo "maxmemory-policy allkeys-lru" >> /etc/redis/redis.conf

              systemctl restart redis-server
              systemctl enable redis-server
              EOT

  tags = merge(local.common_tags, {
    Name = "${var.project_prefix}-cache"
    Role = "redis-cache"
  })
}

# ─────────────────────────────────────────────
# API SERVERS: FINOPS (3 instancias)
# ─────────────────────────────────────────────

# Recurso. Tres instancias EC2 para el Manejador de FinOps.
# Patrón idéntico al ejemplo de clase (for_each con ["a","b","c"]).
# Kong balancea tráfico entre las 3 vía finops_upstream.
# Cada instancia:
#   1. Clona el repositorio privado
#   2. Genera el .env apuntando a db_finops
#   3. Instala requirements + gunicorn
#   4. Espera a que la DB esté lista
#   5. Ejecuta migraciones
#   6. Arranca gunicorn en puerto 8080
resource "aws_instance" "finops" {
  for_each = toset(["a", "b", "c"])

  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.instance_type
  associate_public_ip_address = true
  vpc_security_group_ids = [
    aws_security_group.traffic_django.id,
    aws_security_group.traffic_ssh.id
  ]

  user_data = <<-EOT
              #!/bin/bash
              set -e

              apt-get update -y
              apt-get install -y python3-pip git build-essential libpq-dev python3-dev

              mkdir -p /app
              cd /app
              if [ ! -d arquisoftcloudmonitor ]; then
                git clone ${local.repository} arquisoftcloudmonitor
              fi
              cd /app/arquisoftcloudmonitor
              git fetch origin ${local.branch}
              git checkout ${local.branch}

              cat > /app/arquisoftcloudmonitor/.env << ENVEOF
              SECRET_KEY=${var.django_secret_key}
              DB_NAME=${local.db_finops_name}
              DB_USER=${local.db_finops_user}
              DB_PASSWORD=${var.db_password}
              DB_HOST=${aws_instance.db_finops.private_ip}
              DB_PORT=5432
              COSTS_DB_NAME=${local.db_reports_name}
              ENVEOF

              sed -i "s/ALLOWED_HOSTS = \[\]/ALLOWED_HOSTS = ['*']/" \
                /app/arquisoftcloudmonitor/monitoring/settings.py

              pip3 install --upgrade pip --break-system-packages
              pip3 install -r requirements.txt --break-system-packages
              pip3 install gunicorn --break-system-packages

              echo "Esperando DB finops..."
              for i in $(seq 1 30); do
                python3 -c "
              import psycopg2, sys
              try:
                  psycopg2.connect(dbname='${local.db_finops_name}',user='${local.db_finops_user}',password='${var.db_password}',host='${aws_instance.db_finops.private_ip}',port=5432)
                  sys.exit(0)
              except: sys.exit(1)
              " && break
                sleep 10
              done

              cd /app/arquisoftcloudmonitor
              python3 manage.py makemigrations
              python3 manage.py migrate

              nohup gunicorn monitoring.wsgi:application \
                --bind 0.0.0.0:8080 \
                --workers 3 \
                --log-file /var/log/gunicorn.log \
                --access-logfile /var/log/gunicorn-access.log \
                --daemon
              EOT

  tags = merge(local.common_tags, {
    Name = "${var.project_prefix}-finops-${each.key}"
    Role = "finops"
  })

  depends_on = [aws_instance.db_finops]
}

# ─────────────────────────────────────────────
# API SERVERS: REPORTES Y NOTIFICACIONES (3 instancias)
# ─────────────────────────────────────────────

# Recurso. Tres instancias EC2 para el Manejador de Reportes + Notificaciones.
# Kong balancea tráfico entre las 3 vía reports_upstream.
# Estas instancias también se conectan al cache Redis para reportes precalculados.
resource "aws_instance" "reports" {
  for_each = toset(["a", "b", "c"])

  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.instance_type
  associate_public_ip_address = true
  vpc_security_group_ids = [
    aws_security_group.traffic_django.id,
    aws_security_group.traffic_ssh.id
  ]

  user_data = <<-EOT
              #!/bin/bash
              set -e

              apt-get update -y
              apt-get install -y python3-pip git build-essential libpq-dev python3-dev

              mkdir -p /app
              cd /app
              if [ ! -d arquisoftcloudmonitor ]; then
                git clone ${local.repository} arquisoftcloudmonitor
              fi
              cd /app/arquisoftcloudmonitor
              git fetch origin ${local.branch}
              git checkout ${local.branch}

              cat > /app/arquisoftcloudmonitor/.env << ENVEOF
              SECRET_KEY=${var.django_secret_key}
              DB_NAME=${local.db_reports_name}
              DB_USER=${local.db_reports_user}
              DB_PASSWORD=${var.db_password}
              DB_HOST=${aws_instance.db_reports.private_ip}
              DB_PORT=5432
              COSTS_DB_NAME=${local.db_reports_name}
              REDIS_HOST=${aws_instance.cache.private_ip}
              REDIS_PORT=6379
              ENVEOF

              sed -i "s/ALLOWED_HOSTS = \[\]/ALLOWED_HOSTS = ['*']/" \
                /app/arquisoftcloudmonitor/monitoring/settings.py

              pip3 install --upgrade pip --break-system-packages
              pip3 install -r requirements.txt --break-system-packages
              pip3 install gunicorn redis django-redis --break-system-packages

              echo "Esperando DB reports..."
              for i in $(seq 1 30); do
                python3 -c "
              import psycopg2, sys
              try:
                  psycopg2.connect(dbname='${local.db_reports_name}',user='${local.db_reports_user}',password='${var.db_password}',host='${aws_instance.db_reports.private_ip}',port=5432)
                  sys.exit(0)
              except: sys.exit(1)
              " && break
                sleep 10
              done

              cd /app/arquisoftcloudmonitor
              python3 manage.py makemigrations
              python3 manage.py migrate

              nohup gunicorn monitoring.wsgi:application \
                --bind 0.0.0.0:8080 \
                --workers 3 \
                --log-file /var/log/gunicorn.log \
                --access-logfile /var/log/gunicorn-access.log \
                --daemon
              EOT

  tags = merge(local.common_tags, {
    Name = "${var.project_prefix}-reports-${each.key}"
    Role = "reports"
  })

  depends_on = [aws_instance.db_reports, aws_instance.cache]
}

# ─────────────────────────────────────────────
# API SERVER: ORGANIZACIONES Y AUTH (1 instancia)
# ─────────────────────────────────────────────

# Recurso. Una instancia EC2 para el Manejador de Organizaciones + API AUTH.
# Kong enruta las peticiones de auth vía orgs_upstream.
resource "aws_instance" "orgs" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.instance_type
  associate_public_ip_address = true
  vpc_security_group_ids = [
    aws_security_group.traffic_django.id,
    aws_security_group.traffic_ssh.id
  ]

  user_data = <<-EOT
              #!/bin/bash
              set -e

              apt-get update -y
              apt-get install -y python3-pip git build-essential libpq-dev python3-dev

              mkdir -p /app
              cd /app
              if [ ! -d arquisoftcloudmonitor ]; then
                git clone ${local.repository} arquisoftcloudmonitor
              fi
              cd /app/arquisoftcloudmonitor
              git fetch origin ${local.branch}
              git checkout ${local.branch}

              cat > /app/arquisoftcloudmonitor/.env << ENVEOF
              SECRET_KEY=${var.django_secret_key}
              DB_NAME=${local.db_auth_name}
              DB_USER=${local.db_auth_user}
              DB_PASSWORD=${var.db_password}
              DB_HOST=${aws_instance.db_auth.private_ip}
              DB_PORT=5432
              COSTS_DB_NAME=${local.db_reports_name}
              ENVEOF

              sed -i "s/ALLOWED_HOSTS = \[\]/ALLOWED_HOSTS = ['*']/" \
                /app/arquisoftcloudmonitor/monitoring/settings.py

              pip3 install --upgrade pip --break-system-packages
              pip3 install -r requirements.txt --break-system-packages
              pip3 install gunicorn --break-system-packages

              echo "Esperando DB auth..."
              for i in $(seq 1 30); do
                python3 -c "
              import psycopg2, sys
              try:
                  psycopg2.connect(dbname='${local.db_auth_name}',user='${local.db_auth_user}',password='${var.db_password}',host='${aws_instance.db_auth.private_ip}',port=5432)
                  sys.exit(0)
              except: sys.exit(1)
              " && break
                sleep 10
              done

              cd /app/arquisoftcloudmonitor
              python3 manage.py makemigrations
              python3 manage.py migrate

              nohup gunicorn monitoring.wsgi:application \
                --bind 0.0.0.0:8080 \
                --workers 3 \
                --log-file /var/log/gunicorn.log \
                --access-logfile /var/log/gunicorn-access.log \
                --daemon
              EOT

  tags = merge(local.common_tags, {
    Name = "${var.project_prefix}-orgs"
    Role = "organizations-auth"
  })

  depends_on = [aws_instance.db_auth]
}

# ─────────────────────────────────────────────
# OUTPUTS
# ─────────────────────────────────────────────

output "kong_public_ip" {
  description = "IP pública de Kong API Gateway (acceder vía http://<ip>:8000)"
  value       = aws_instance.kong.public_ip
}

output "finops_public_ips" {
  description = "IPs públicas de los servidores FinOps (a, b, c)"
  value       = { for id, inst in aws_instance.finops : id => inst.public_ip }
}

output "finops_private_ips" {
  description = "IPs privadas de los servidores FinOps (usadas por Kong upstream)"
  value       = { for id, inst in aws_instance.finops : id => inst.private_ip }
}

output "reports_public_ips" {
  description = "IPs públicas de los servidores de Reportes (a, b, c)"
  value       = { for id, inst in aws_instance.reports : id => inst.public_ip }
}

output "reports_private_ips" {
  description = "IPs privadas de los servidores de Reportes (usadas por Kong upstream)"
  value       = { for id, inst in aws_instance.reports : id => inst.private_ip }
}

output "orgs_public_ip" {
  description = "IP pública del servidor de Organizaciones y Auth"
  value       = aws_instance.orgs.public_ip
}

output "orgs_private_ip" {
  description = "IP privada del servidor de Organizaciones y Auth (usada por Kong upstream)"
  value       = aws_instance.orgs.private_ip
}

output "db_finops_private_ip" {
  description = "IP privada de la DB de FinOps (monitoring_db)"
  value       = aws_instance.db_finops.private_ip
}

output "db_reports_private_ip" {
  description = "IP privada de la DB de Reportes (costs_db)"
  value       = aws_instance.db_reports.private_ip
}

output "db_auth_private_ip" {
  description = "IP privada de la DB de Autenticación (auth_db)"
  value       = aws_instance.db_auth.private_ip
}

output "cache_private_ip" {
  description = "IP privada del cache Redis"
  value       = aws_instance.cache.private_ip
}

output "cold_storage_bucket" {
  description = "Nombre del bucket S3 para almacenamiento en frío (> 24 meses)"
  value       = aws_s3_bucket.cold_storage.bucket
}

# ─────────────────────────────────────────────
# POST-DEPLOY: CONFIGURAR KONG
# ─────────────────────────────────────────────
#
# Después de terraform apply, conéctate a Kong por SSH y configura los upstreams:
#
# ssh ubuntu@<kong_public_ip>
#
# 1. Instalar Kong:
#    curl -Lo kong.deb https://packages.konghq.com/public/gateway-38/deb/ubuntu/pool/noble/main/k/ko/kong_3.8.0/kong_3.8.0_amd64.deb
#    sudo apt-get install -y ./kong.deb
#    sudo kong migrations bootstrap
#    sudo kong start
#
# 2. Crear upstream finops_upstream y sus targets (reemplaza IPs con los outputs):
#    curl -X POST http://localhost:8001/upstreams --data name=finops_upstream
#    curl -X POST http://localhost:8001/upstreams/finops_upstream/targets --data target=<finops_a_private_ip>:8080
#    curl -X POST http://localhost:8001/upstreams/finops_upstream/targets --data target=<finops_b_private_ip>:8080
#    curl -X POST http://localhost:8001/upstreams/finops_upstream/targets --data target=<finops_c_private_ip>:8080
#
# 3. Crear servicio y ruta para finops:
#    curl -X POST http://localhost:8001/services --data name=finops-service --data host=finops_upstream
#    curl -X POST http://localhost:8001/services/finops-service/routes --data "paths[]=/finops"
#
# 4. Repetir para reports_upstream (3 targets) y orgs_upstream (1 target):
#    curl -X POST http://localhost:8001/upstreams --data name=reports_upstream
#    curl -X POST http://localhost:8001/upstreams/reports_upstream/targets --data target=<reports_a_private_ip>:8080
#    curl -X POST http://localhost:8001/upstreams/reports_upstream/targets --data target=<reports_b_private_ip>:8080
#    curl -X POST http://localhost:8001/upstreams/reports_upstream/targets --data target=<reports_c_private_ip>:8080
#    curl -X POST http://localhost:8001/services --data name=reports-service --data host=reports_upstream
#    curl -X POST http://localhost:8001/services/reports-service/routes --data "paths[]=/reports"
#
#    curl -X POST http://localhost:8001/upstreams --data name=orgs_upstream
#    curl -X POST http://localhost:8001/upstreams/orgs_upstream/targets --data target=<orgs_private_ip>:8080
#    curl -X POST http://localhost:8001/services --data name=orgs-service --data host=orgs_upstream
#    curl -X POST http://localhost:8001/services/orgs-service/routes --data "paths[]=/orgs"
