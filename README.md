# Cloud Cost Monitoring

Hola chicos, espero les sirvan estos pasos para configurar el proyecto desde sus compus 

## Setup

1. Clonar el repo
2. Crear y activar el entorno virtual
3. Instalar dependencias: `pip install -r requirements.txt`
4. Crear un archivo .env `.env` con las credenciales de bases de datos 

SECRET_KEY=your_secret_key_here

DB_NAME=monitoring_db

DB_USER=your_db_user

DB_PASSWORD=your_db_password

DB_HOST=localhost

DB_PORT=5432

COSTS_DB_NAME=costs_db
   
5. Crear las bases de datos PostgreSQL: `monitoring_db` y `costs_db`
6. Run migrations:
   - `python manage.py migrate --database=default`
   - `python manage.py migrate --database=costs_db`
7. Correr el servidor: `python manage.py runserver`
