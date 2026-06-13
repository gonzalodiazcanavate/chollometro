-- Extensiones requeridas por la aplicación.
-- Se ejecutan como superusuario al inicializar el contenedor de PostgreSQL,
-- antes de que Flyway aplique las migraciones.
CREATE EXTENSION IF NOT EXISTS pg_trgm;
