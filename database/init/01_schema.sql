version: '3.9'

services:
  postgres:
    image: postgres:16
    container_name: service_app_db
    restart: always
    environment:
      POSTGRES_USER: service_user
      POSTGRES_PASSWORD: service_pass
      POSTGRES_DB: service_app
    ports:
      - "5432:5432"
    volumes:
      - postgres_data:/var/lib/postgresql/data
      - ./init:/docker-entrypoint-initdb.d  # Executes schema automatically
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U service_user"]
      interval: 10s
      timeout: 5s
      retries: 5

  pgadmin:
    image: dpage/pgadmin4
    container_name: service_pgadmin
    restart: always
    environment:
      PGADMIN_DEFAULT_EMAIL: admin@service.com
      PGADMIN_DEFAULT_PASSWORD: admin123
    ports:
      - "8080:80"
    depends_on:
      - postgres

volumes:
  postgres_data:
