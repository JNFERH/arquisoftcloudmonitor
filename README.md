# Cloud Cost Monitoring

Hola chicos, espero les sirvan estos pasos para configurar el proyecto desde sus compus 

## Setup

1. Clonar el repo
2. Crear y activar el entorno virtual
3. Instalar dependencias: `pip install -r requirements.txt`
4. Crear un archivo .env `.env` con las credenciales de bases de datos (ver `.env.example`)
5. Crear las bases de datos PostgreSQL: `monitoring_db` y `costs_db`
6. Run migrations:
   - `python manage.py migrate --database=default`
   - `python manage.py migrate --database=costs_db`
7. Correr el servidor: `python manage.py runserver`
