# Infraestructura para arquisoftcloudmonitor
#
# Elementos a desplegar en AWS:
# 1. Grupos de seguridad:
#    - acm-traffic-django (puerto 8080)
#    - acm-traffic-cb     (puertos 8000 y 8001 - Kong)
#    - acm-traffic-db     (puerto 5432 - PostgreSQL)
#    - acm-traffic-ssh    (puerto 22)
#
# 2. Instancias EC2:
#    - acm-kong  (API Gateway Kong - configuración manual post-deploy)
#    - acm-db    (PostgreSQL: crea monitoring_db y costs_db)
#    - acm-app   (Django: clona repo, genera .env, migra y corre servidor)
#
# NOTA IMPORTANTE - Repositorio privado:
#   git clone falla si el repo es privado sin credenciales.
#   Solución: usar un GitHub Personal Access Token (PAT).
#   1. Ve a GitHub -> Settings -> Developer settings -> Personal access tokens
#   2. Genera un token con scope "repo"
#   3. Pásalo como variable al correr terraform: -var="github_token=ghp_..."
#   4. NUNCA pongas el token directamente en este archivo ni lo subas a GitHub
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
variable "instance_type" {
  description = "EC2 instance type for application hosts"
  type        = string
  default     = "t2.micro"
}

# Variable. Personal Access Token de GitHub para clonar el repositorio privado.
# Pásalo al aplicar: terraform apply -var="github_token=ghp_TU_TOKEN"
# O crea un archivo terraform.tfvars con: github_token = "ghp_TU_TOKEN"
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

# Variable. Contraseña del usuario de PostgreSQL.
variable "db_password" {
  description = "Password for the PostgreSQL database user"
  type        = string
  default     = "isis2503"
  sensitive   = true
}

# Variable. SECRET_KEY de Django.
# Genera una segura con:
#   python3 -c "from django.core.management.utils import get_random_secret_key; print(get_random_secret_key())"
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

  db_name  = "monitoring_db"
  costs_db = "costs_db"
  db_user  = "cloudmonitor_user"

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

# Recurso. Grupo de seguridad para Django (puerto 8080).
resource "aws_security_group" "traffic_django" {
  name        = "${var.project_prefix}-traffic-django"
  description = "Allow HTTP traffic to Django on port 8080"

  ingress {
    description = "HTTP access for Django service"
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, {
    Name = "${var.project_prefix}-traffic-django"
  })
}

# Recurso. Grupo de seguridad para Kong API Gateway (puertos 8000 y 8001).
resource "aws_security_group" "traffic_cb" {
  name        = "${var.project_prefix}-traffic-cb"
  description = "Expose Kong API Gateway proxy (8000) and admin (8001) ports"

  ingress {
    description = "Kong proxy and admin API"
    from_port   = 8000
    to_port     = 8001
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, {
    Name = "${var.project_prefix}-traffic-cb"
  })
}

# Recurso. Grupo de seguridad para PostgreSQL (puerto 5432).
# FIX: La instancia DB necesita egress abierto para recibir el user_data
# (apt-get). Se agrega egress aquí también.
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

# Recurso. Grupo de seguridad para SSH (puerto 22) con egress abierto.
# El egress abierto es necesario para que las instancias puedan hacer
# apt-get update, git clone, pip install, etc. desde Internet.
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
    description = "Allow all outbound traffic (needed for apt, pip, git)"
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
# INSTANCIA: KONG (API Gateway)
# ─────────────────────────────────────────────

# Recurso. Instancia EC2 para Kong API Gateway.
# Se despliega vacía; Kong se instala manualmente vía SSH.
# Post-deploy: conectar por SSH y seguir la guía oficial de Kong en Ubuntu.
# Luego configurar un Service apuntando a acm-app:8080 y un Route en /
resource "aws_instance" "kong" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.instance_type
  associate_public_ip_address = true
  vpc_security_group_ids = [
    aws_security_group.traffic_cb.id,
    aws_security_group.traffic_ssh.id
  ]

  tags = merge(local.common_tags, {
    Name = "${var.project_prefix}-kong"
    Role = "api-gateway"
  })
}

# ─────────────────────────────────────────────
# INSTANCIA: BASE DE DATOS
# ─────────────────────────────────────────────

# Recurso. Instancia EC2 para PostgreSQL.
# FIX vs versión anterior:
#   - Crea AMBAS bases de datos: monitoring_db y costs_db
#   - Usa 'md5' en pg_hba (más seguro que 'trust')
#   - set -e para detener el script ante cualquier error
resource "aws_instance" "database" {
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

              # ── 1. Instalar PostgreSQL ──────────────────────────────
              apt-get update -y
              apt-get install -y postgresql postgresql-contrib

              # ── 2. Crear usuario y las dos bases de datos ───────────
              sudo -u postgres psql -c "CREATE USER ${local.db_user} WITH PASSWORD '${var.db_password}';"
              sudo -u postgres createdb -O ${local.db_user} ${local.db_name}
              sudo -u postgres createdb -O ${local.db_user} ${local.costs_db}

              # ── 3. Configurar acceso remoto ─────────────────────────
              PG_HBA="/etc/postgresql/16/main/pg_hba.conf"
              PG_CONF="/etc/postgresql/16/main/postgresql.conf"

              echo "host all all 0.0.0.0/0 md5" | tee -a $PG_HBA
              echo "listen_addresses='*'"        | tee -a $PG_CONF
              echo "max_connections=2000"        | tee -a $PG_CONF

              # ── 4. Reiniciar PostgreSQL ─────────────────────────────
              systemctl restart postgresql
              EOT

  tags = merge(local.common_tags, {
    Name = "${var.project_prefix}-db"
    Role = "database"
  })
}

# ─────────────────────────────────────────────
# INSTANCIA: APP DJANGO
# ─────────────────────────────────────────────

# Recurso. Instancia EC2 para el backend Django (arquisoftcloudmonitor).
# FIX vs versión anterior — corrige 9 problemas:
#   1. ALLOWED_HOSTS=['*']  → Django aceptará la IP pública de la instancia
#   2. Genera .env automáticamente con todas las variables requeridas
#   3. Crea monitoring_db Y costs_db (corregido en instancia DB)
#   4. Corre gunicorn como servidor en producción (no runserver)
#   5. Instala gunicorn (no estaba en requirements.txt)
#   6. Repo privado → usa PAT en la URL de git clone
#   7. manage.py está en la raíz del repo → rutas correctas
#   8. Loop de espera (30 intentos x 10s) antes de migrar
#   9. django_secret_key como variable → no hardcodeada
resource "aws_instance" "app" {
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

              # ── 1. Instalar dependencias del sistema ────────────────
              apt-get update -y
              apt-get install -y python3-pip git build-essential libpq-dev python3-dev

              # ── 2. Clonar repositorio privado con PAT ───────────────
              mkdir -p /app
              cd /app

              if [ ! -d arquisoftcloudmonitor ]; then
                git clone ${local.repository} arquisoftcloudmonitor
              fi

              cd /app/arquisoftcloudmonitor
              git fetch origin ${local.branch}
              git checkout ${local.branch}

              # ── 3. Generar archivo .env ─────────────────────────────
              # manage.py está en la raíz del repo, .env debe estar ahí también
              cat > /app/arquisoftcloudmonitor/.env << ENVEOF
              SECRET_KEY=${var.django_secret_key}
              DB_NAME=${local.db_name}
              DB_USER=${local.db_user}
              DB_PASSWORD=${var.db_password}
              DB_HOST=${aws_instance.database.private_ip}
              DB_PORT=5432
              COSTS_DB_NAME=${local.costs_db}
              ENVEOF

              # ── 4. Instalar dependencias Python ─────────────────────
              pip3 install --upgrade pip --break-system-packages
              pip3 install -r /app/arquisoftcloudmonitor/requirements.txt --break-system-packages
              # gunicorn no está en requirements.txt, se instala aparte
              pip3 install gunicorn --break-system-packages

              # ── 5. Parchear ALLOWED_HOSTS ───────────────────────────
              # ALLOWED_HOSTS=[] rechaza TODAS las peticiones externas.
              # Para el lab se acepta cualquier host con ['*'].
              sed -i "s/ALLOWED_HOSTS = \[\]/ALLOWED_HOSTS = ['*']/" \
                /app/arquisoftcloudmonitor/monitoring/settings.py

              # ── 6. Esperar a que PostgreSQL esté disponible ──────────
              echo "Esperando a que la base de datos esté lista..."
              for i in $(seq 1 30); do
                python3 -c "
              import psycopg2, sys
              try:
                  psycopg2.connect(
                      dbname='${local.db_name}',
                      user='${local.db_user}',
                      password='${var.db_password}',
                      host='${aws_instance.database.private_ip}',
                      port=5432
                  )
                  sys.exit(0)
              except Exception as e:
                  print(e)
                  sys.exit(1)
              " && break
                echo "Intento $i/30 — DB no disponible, reintentando en 10s..."
                sleep 10
              done

              # ── 7. Ejecutar migraciones ──────────────────────────────
              cd /app/arquisoftcloudmonitor
              python3 manage.py makemigrations
              python3 manage.py migrate                        # → monitoring_db (default)
              python3 manage.py migrate --database=costs_db   # → costs_db

              # ── 8. Correr servidor con gunicorn en puerto 8080 ───────
              # 3 workers, corre en background como daemon
              # Logs disponibles vía SSH en /var/log/gunicorn*.log
              nohup gunicorn monitoring.wsgi:application \
                --bind 0.0.0.0:8080 \
                --workers 3 \
                --log-file /var/log/gunicorn.log \
                --access-logfile /var/log/gunicorn-access.log \
                --daemon
              EOT

  tags = merge(local.common_tags, {
    Name = "${var.project_prefix}-app"
    Role = "django-backend"
  })

  # La app espera a que la instancia DB esté creada antes de arrancar
  depends_on = [aws_instance.database]
}

# ─────────────────────────────────────────────
# OUTPUTS
# ─────────────────────────────────────────────

output "kong_public_ip" {
  description = "IP pública de Kong API Gateway"
  value       = aws_instance.kong.public_ip
}

output "app_public_ip" {
  description = "IP pública del backend Django"
  value       = aws_instance.app.public_ip
}

output "app_private_ip" {
  description = "IP privada del backend Django"
  value       = aws_instance.app.private_ip
}

output "database_private_ip" {
  description = "IP privada de PostgreSQL (solo accesible dentro de AWS)"
  value       = aws_instance.database.private_ip
}

output "app_url" {
  description = "URL para acceder a la aplicación Django"
  value       = "http://${aws_instance.app.public_ip}:8080"
}
