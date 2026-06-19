-- ================================================================
-- CHOLLOÓMETRO — ESQUEMA DE BASE DE DATOS
-- PostgreSQL 16+
-- V5 — 2026-06-09
-- ================================================================

-- ================================================================
-- 1. TIPOS ENUMERADOS
-- ================================================================

CREATE TYPE user_role AS ENUM (
    'admin',       -- Administrador de la plataforma
    'commerce',    -- Comercio adherido
    'user'         -- Usuario final
);

CREATE TYPE user_state AS ENUM (
    'active',
    'suspended',
    'deleted'
);

CREATE TYPE commerce_state AS ENUM (
    'pending_approval',  -- Registrado, pendiente de aprobación por admin
    'active',
    'suspended'
);

CREATE TYPE product_state AS ENUM (
    'active',    -- Visible en catálogo público
    'inactive',  -- Oculto temporalmente por el comercio
    'hidden',    -- Ocultado por el administrador (RF-33)
    'deleted'    -- Borrado lógico — nunca usar DELETE físico
);

CREATE TYPE booking_state AS ENUM (
    'pending',    -- Pendiente de preparación
    'prepared',   -- Lista para recoger
    'delivered',  -- Entregada al usuario
    'cancelled'   -- Cancelada
);

CREATE TYPE commerce_subscription_state AS ENUM (
    'active',
    'expired',
    'cancelled'
);

CREATE TYPE discount_type AS ENUM (
    'percentage',   -- % sobre el precio original
    'fixed_amount', -- importe fijo descontado
    'both'          -- se aplican ambos; el backend aplica amount primero, luego percentage
);

-- ================================================================
-- 2. FUNCIÓN AUXILIAR: actualización automática de updated_at
-- ================================================================

CREATE OR REPLACE FUNCTION fn_set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- ================================================================
-- 3. CATEGORÍAS
-- Árbol de categorías con soporte para subcategorías (RF-14, RF-30)
-- ================================================================

CREATE TABLE category (
    id            SERIAL       PRIMARY KEY,
    parent_id     INT          REFERENCES category(id) ON DELETE SET NULL,
    name          VARCHAR(100) NOT NULL,
    description   TEXT,
    fields_schema JSONB        NOT NULL DEFAULT '[]',
    is_active     BOOLEAN      NOT NULL DEFAULT TRUE,

    CONSTRAINT uq_category_name_parent UNIQUE (name, parent_id)
);

-- ================================================================
-- 4. PLANES DE SUSCRIPCIÓN (RF-07, RF-31)
-- ================================================================

CREATE TABLE plan (
    id           SERIAL         PRIMARY KEY,
    name         VARCHAR(100)   NOT NULL UNIQUE,
    description  TEXT,
    price        NUMERIC(10,2)  NOT NULL CHECK (price >= 0),
    max_products INT            NOT NULL CHECK (max_products > 0),
    is_active    BOOLEAN        NOT NULL DEFAULT TRUE,
    updated_at   TIMESTAMPTZ    NOT NULL DEFAULT NOW()
);

CREATE TRIGGER trg_plan_updated_at
    BEFORE UPDATE ON plan
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();

-- ================================================================
-- 5. USUARIOS (RF-01 a RF-04, RN-01, RN-02)
-- ================================================================

CREATE TABLE "user" (
    id            SERIAL       PRIMARY KEY,
    name          VARCHAR(150) NOT NULL,
    alias         VARCHAR(100),
    email         VARCHAR(255) NOT NULL,
    password_hash VARCHAR(255) NOT NULL,
    phone         VARCHAR(20),
    role          user_role    NOT NULL DEFAULT 'user',
    state         user_state   NOT NULL DEFAULT 'active',
    created_at    TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at    TIMESTAMPTZ  NOT NULL DEFAULT NOW(),

    CONSTRAINT uq_user_email UNIQUE (email)   -- RN-02
);

CREATE TRIGGER trg_user_updated_at
    BEFORE UPDATE ON "user"
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();

-- ================================================================
-- 6. COMERCIOS (RF-05, RF-06, RF-08, RN-04, RN-05)
-- ================================================================

CREATE TABLE commerce (
    id          SERIAL         PRIMARY KEY,
    user_id     INT            NOT NULL,
    name        VARCHAR(150)   NOT NULL,
    description TEXT,
    cif         VARCHAR(20)    NOT NULL,
    email       VARCHAR(255)   NOT NULL,
    phone       VARCHAR(20),
    address     TEXT,
    city        VARCHAR(100),
    postal_code VARCHAR(10),
    logo_url    TEXT,
    state       commerce_state NOT NULL DEFAULT 'pending_approval',
    created_at  TIMESTAMPTZ    NOT NULL DEFAULT NOW(),
    updated_at  TIMESTAMPTZ    NOT NULL DEFAULT NOW(),

    CONSTRAINT uq_commerce_user UNIQUE (user_id),
    CONSTRAINT uq_commerce_cif  UNIQUE (cif),
    CONSTRAINT fk_commerce_user FOREIGN KEY (user_id)
        REFERENCES "user"(id) ON DELETE CASCADE
);

CREATE TRIGGER trg_commerce_updated_at
    BEFORE UPDATE ON commerce
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();

-- ================================================================
-- 7. SUSCRIPCIONES DE COMERCIO (RF-07, RF-31)
-- ================================================================

CREATE TABLE commerce_subscription (
    id          SERIAL                      PRIMARY KEY,
    commerce_id INT                         NOT NULL,
    plan_id     INT                         NOT NULL,
    state       commerce_subscription_state NOT NULL DEFAULT 'active',
    start_date  DATE                        NOT NULL DEFAULT CURRENT_DATE,
    end_date    DATE,
    updated_at  TIMESTAMPTZ                 NOT NULL DEFAULT NOW(),

    CONSTRAINT fk_sub_commerce FOREIGN KEY (commerce_id)
        REFERENCES commerce(id) ON DELETE CASCADE,
    CONSTRAINT fk_sub_plan     FOREIGN KEY (plan_id)
        REFERENCES plan(id),
    CONSTRAINT chk_sub_dates   CHECK (end_date IS NULL OR end_date > start_date)
);

CREATE TRIGGER trg_sub_updated_at
    BEFORE UPDATE ON commerce_subscription
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();

-- ================================================================
-- 8. PRODUCTOS (RF-09 a RF-14, RN-04 a RN-09)
-- ================================================================

CREATE TABLE product (
    id          SERIAL        PRIMARY KEY,
    commerce_id INT           NOT NULL,
    category_id INT           NOT NULL,
    name        VARCHAR(200)  NOT NULL,
    description TEXT          NOT NULL,
    price       NUMERIC(10,2) NOT NULL CHECK (price >= 0),
    stock       INT           NOT NULL DEFAULT 0 CHECK (stock >= 0),
    attributes  JSONB         NOT NULL DEFAULT '{}',
    state       product_state NOT NULL DEFAULT 'active',
    created_at  TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
    updated_at  TIMESTAMPTZ   NOT NULL DEFAULT NOW(),

    CONSTRAINT fk_product_commerce FOREIGN KEY (commerce_id)
        REFERENCES commerce(id) ON DELETE RESTRICT,
    CONSTRAINT fk_product_category FOREIGN KEY (category_id)
        REFERENCES category(id)
);

CREATE TRIGGER trg_product_updated_at
    BEFORE UPDATE ON product
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();

-- ================================================================
-- 9. DESCUENTOS DE PRODUCTO
-- ================================================================

CREATE TABLE discount (
    id           SERIAL        PRIMARY KEY,
    product_id   INT           NOT NULL,
    type         discount_type NOT NULL,
    percentage   NUMERIC(5,2)  CHECK (percentage > 0 AND percentage <= 100),
    amount       NUMERIC(10,2) CHECK (amount > 0),
    priority     SMALLINT      NOT NULL DEFAULT 0,
    min_quantity INT           CHECK (min_quantity > 0),
    start_date   TIMESTAMPTZ,
    end_date     TIMESTAMPTZ,
    is_active    BOOLEAN       NOT NULL DEFAULT TRUE,
    conditions   JSONB         NOT NULL DEFAULT '{}',
    updated_at   TIMESTAMPTZ   NOT NULL DEFAULT NOW(),

    CONSTRAINT fk_discount_product  FOREIGN KEY (product_id)
        REFERENCES product(id) ON DELETE CASCADE,
    CONSTRAINT chk_discount_dates   CHECK (start_date IS NULL OR end_date IS NULL
                                        OR end_date > start_date),
    CONSTRAINT chk_discount_value   CHECK (
        (type = 'percentage'   AND percentage IS NOT NULL AND amount IS NULL) OR
        (type = 'fixed_amount' AND amount IS NOT NULL AND percentage IS NULL) OR
        (type = 'both'         AND percentage IS NOT NULL AND amount IS NOT NULL)
    )
);

CREATE TRIGGER trg_discount_updated_at
    BEFORE UPDATE ON discount
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();

-- ================================================================
-- 10. IMÁGENES DE PRODUCTO (RF-12)
-- ================================================================

CREATE TABLE product_image (
    id         SERIAL   PRIMARY KEY,
    product_id INT      NOT NULL,
    image_url  TEXT     NOT NULL,
    is_main    BOOLEAN  NOT NULL DEFAULT FALSE,
    sort_order SMALLINT NOT NULL DEFAULT 0,

    CONSTRAINT fk_image_product FOREIGN KEY (product_id)
        REFERENCES product(id) ON DELETE CASCADE
);

-- Integridad estructural: una única imagen principal por producto
CREATE UNIQUE INDEX uq_product_one_main_image
    ON product_image(product_id)
    WHERE is_main = TRUE;

-- ================================================================
-- 11. RESERVAS (RF-22 a RF-26, RN-10 a RN-15)
-- ================================================================

CREATE TABLE booking (
    id         SERIAL        PRIMARY KEY,
    product_id INT           NOT NULL,
    user_id    INT           NOT NULL,
    quantity   INT           NOT NULL DEFAULT 1 CHECK (quantity > 0),
    state      booking_state NOT NULL DEFAULT 'pending',
    notes      TEXT,
    created_at TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ   NOT NULL DEFAULT NOW(),

    CONSTRAINT fk_booking_product FOREIGN KEY (product_id)
        REFERENCES product(id) ON DELETE RESTRICT,
    CONSTRAINT fk_booking_user    FOREIGN KEY (user_id)
        REFERENCES "user"(id) ON DELETE RESTRICT
);

CREATE TRIGGER trg_booking_updated_at
    BEFORE UPDATE ON booking
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();

-- ================================================================
-- 12. FAVORITOS (RF-19 a RF-21, RN-16 a RN-18)
-- ================================================================

CREATE TABLE favorite (
    user_id    INT         NOT NULL,
    product_id INT         NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    PRIMARY KEY (user_id, product_id),  -- RN-18: unicidad garantizada estructuralmente
    CONSTRAINT fk_fav_user    FOREIGN KEY (user_id)
        REFERENCES "user"(id) ON DELETE CASCADE,
    CONSTRAINT fk_fav_product FOREIGN KEY (product_id)
        REFERENCES product(id) ON DELETE CASCADE
);

-- ================================================================
-- 13. ESTADÍSTICAS AGREGADAS POR PRODUCTO (RF-27, RF-28, RN-19 a RN-21)
-- ================================================================

CREATE TABLE product_stats (
    product_id      INT         PRIMARY KEY,
    views           INT         NOT NULL DEFAULT 0 CHECK (views >= 0),
    favorites_count INT         NOT NULL DEFAULT 0 CHECK (favorites_count >= 0),
    bookings_count  INT         NOT NULL DEFAULT 0 CHECK (bookings_count >= 0),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT fk_stats_product FOREIGN KEY (product_id)
        REFERENCES product(id) ON DELETE CASCADE
);

-- ================================================================
-- 14. REGISTRO DE VISUALIZACIONES — detalle (RF-28)
-- ================================================================

CREATE TABLE product_view (
    id         BIGSERIAL   PRIMARY KEY,
    product_id INT         NOT NULL,
    user_id    INT,                     -- NULL si el usuario no está autenticado
    viewed_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    ip_address INET,

    CONSTRAINT fk_view_product FOREIGN KEY (product_id)
        REFERENCES product(id) ON DELETE CASCADE,
    CONSTRAINT fk_view_user    FOREIGN KEY (user_id)
        REFERENCES "user"(id) ON DELETE SET NULL
);

-- ================================================================
-- 15. ÍNDICES DE RENDIMIENTO (RNF-01)
-- ================================================================

-- Productos
CREATE INDEX idx_product_commerce   ON product(commerce_id);
CREATE INDEX idx_product_category   ON product(category_id);
CREATE INDEX idx_product_state      ON product(state);
CREATE INDEX idx_product_price      ON product(price);

-- Búsqueda full-text fuzzy sobre campos comunes (RF-16, RNF-01)
CREATE INDEX idx_product_name_trgm  ON product USING GIN (name gin_trgm_ops);
CREATE INDEX idx_product_desc_trgm  ON product USING GIN (description gin_trgm_ops);

-- Filtrado y búsqueda sobre atributos extendidos
CREATE INDEX idx_product_attributes ON product USING GIN (attributes);

-- Esquema de campos de categoría (recorrido del árbol por el backend)
CREATE INDEX idx_category_parent    ON category(parent_id);
CREATE INDEX idx_category_schema    ON category USING GIN (fields_schema);

-- Descuentos
CREATE INDEX idx_discount_product   ON discount(product_id);
CREATE INDEX idx_discount_active    ON discount(product_id) WHERE is_active = TRUE;
CREATE INDEX idx_discount_dates     ON discount(start_date, end_date);
CREATE INDEX idx_discount_priority  ON discount(product_id, priority DESC);
CREATE INDEX idx_discount_conditions ON discount USING GIN (conditions);

-- Reservas
CREATE INDEX idx_booking_user       ON booking(user_id);
CREATE INDEX idx_booking_product    ON booking(product_id);
CREATE INDEX idx_booking_state      ON booking(state);
CREATE INDEX idx_booking_created    ON booking(created_at);

-- Favoritos
CREATE INDEX idx_fav_product        ON favorite(product_id);

-- Visualizaciones
CREATE INDEX idx_view_product       ON product_view(product_id);
CREATE INDEX idx_view_viewed_at     ON product_view(viewed_at);

-- Suscripciones
CREATE INDEX idx_sub_commerce       ON commerce_subscription(commerce_id);
CREATE INDEX idx_sub_state          ON commerce_subscription(state);

-- ================================================================
-- 16. VISTAS
-- ================================================================

-- Vista de estadísticas completas con tasa de conversión (RF-28)
CREATE VIEW v_product_stats AS
SELECT
    ps.product_id,
    p.name                                                     AS product_name,
    p.commerce_id,
    c.name                                                     AS commerce_name,
    ps.views,
    ps.favorites_count,
    ps.bookings_count,
    CASE
        WHEN ps.views > 0
        THEN ROUND(ps.bookings_count::NUMERIC / ps.views * 100, 2)
        ELSE 0
    END                                                        AS conversion_rate_pct,
    ps.updated_at
FROM product_stats ps
JOIN product  p ON p.id = ps.product_id
JOIN commerce c ON c.id = p.commerce_id;

-- Vista de estadísticas globales para el administrador (RF-29)
CREATE VIEW v_platform_stats AS
SELECT
    COUNT(DISTINCT c.id)                                       AS total_commerces,
    COUNT(DISTINCT p.id) FILTER (WHERE p.state = 'active')    AS active_products,
    COUNT(DISTINCT u.id) FILTER (WHERE u.role = 'user')       AS total_users,
    COUNT(DISTINCT b.id)                                       AS total_bookings,
    COUNT(DISTINCT b.id) FILTER (WHERE b.state = 'delivered') AS completed_bookings,
    COALESCE(SUM(ps.views), 0)                                 AS total_views,
    COALESCE(SUM(ps.favorites_count), 0)                       AS total_favorites
FROM commerce           c
FULL JOIN product       p  ON p.commerce_id = c.id
FULL JOIN "user"        u  ON u.role = 'user'
FULL JOIN booking       b  ON b.product_id = p.id
LEFT JOIN product_stats ps ON ps.product_id = p.id;

-- ================================================================
-- 17. COMENTARIOS
-- ================================================================

COMMENT ON COLUMN category.fields_schema IS
    'Define los campos extra requeridos por los productos de esta categoría. '
    'Estructura: array de objetos {key, label, type, required, options?}. '
    'Ejemplo: [{"key":"size","label":"Talla","type":"select","options":["S","M","L"],"required":true}]. '
    'El schema efectivo de un producto se construye en el backend recorriendo el árbol '
    'de categorías desde la raíz hasta la hoja y combinando los fields_schema de cada nivel.';

COMMENT ON COLUMN plan.max_products IS
    'Límite de productos activos simultáneos permitidos con este plan. '
    'La validación del límite se realiza en la capa de aplicación.';

COMMENT ON TABLE commerce_subscription IS
    'Historial de planes contratados por cada comercio. '
    'La unicidad de suscripción activa por comercio se garantiza en la capa de aplicación.';

COMMENT ON COLUMN product.attributes IS
    'Atributos extendidos específicos de la categoría del producto. '
    'Ejemplo camiseta: {"size":"M","material":"algodón","gender":"unisex"}. '
    'Ejemplo móvil:    {"brand":"Samsung","ram_gb":8,"storage_gb":256}. '
    'Los campos válidos y sus tipos se definen en category.fields_schema. '
    'La validación de los atributos contra el schema se realiza en la capa de aplicación.';

COMMENT ON COLUMN product.state IS
    'Solo los productos ''active'' son visibles en el catálogo público (RN-06). '
    'Usar state = ''deleted'' para borrado lógico; nunca DELETE físico si existen reservas (RN-22).';

COMMENT ON COLUMN product.stock IS
    'No puede ser negativo — CHECK como invariante físico (RN-08). '
    'La verificación de stock disponible y su descuento al crear una reserva '
    'se gestionan en la capa de aplicación mediante transacción explícita (RN-12, RN-13).';

COMMENT ON TABLE discount IS
    'Descuentos aplicables a un producto. Un producto puede tener varios descuentos; '
    'el backend selecciona el de mayor priority que esté vigente y activo. '
    'Si conditions contiene tiers, el campo min_quantity de la fila es ignorado.';

COMMENT ON COLUMN discount.priority IS
    'A mayor valor, mayor prioridad. El backend aplica el descuento activo '
    'y vigente de mayor prioridad para el producto.';

COMMENT ON COLUMN discount.min_quantity IS
    'Unidades mínimas que debe reservar el usuario para que el descuento aplique. '
    'Si conditions contiene tiers escalonados, este campo es ignorado.';

COMMENT ON COLUMN discount.conditions IS
    'Condiciones avanzadas opcionales. Ejemplos: '
    'Escalonado: {"tiers":[{"min_quantity":2,"percentage":5},{"min_quantity":5,"percentage":10}]}. '
    'Límite de usos: {"max_uses":100,"current_uses":43}. '
    'Primer pedido: {"first_booking_only":true}. '
    'Sin condiciones complejas: {}.';

COMMENT ON COLUMN product_image.is_main IS
    'Solo puede haber una imagen principal por producto '
    '(garantizado por el índice parcial uq_product_one_main_image).';

COMMENT ON COLUMN booking.state IS
    'Flujo válido: pending → prepared → delivered | cancelled. '
    'La validación de transiciones, las reglas de quién puede cambiar cada estado '
    'y la cancelación (RF-26) se gestionan en la capa de aplicación.';

COMMENT ON TABLE product_stats IS
    'Contadores agregados actualizados por la capa de aplicación ante cada interacción relevante (RN-21). '
    'La tasa de conversión se calcula en la vista v_product_stats. '
    'En el futuro puede migrarse a un proceso asíncrono sin modificar este esquema.';

COMMENT ON TABLE product_view IS
    'Log detallado de visualizaciones para analytics granular. '
    'Los agregados se mantienen en product_stats y son actualizados '
    'por la capa de aplicación tras cada inserción en esta tabla.';

COMMENT ON VIEW v_product_stats IS
    'Métricas por producto incluyendo tasa de conversión reserva/visualización (RF-28).';

COMMENT ON VIEW v_platform_stats IS
    'Estadísticas globales de la plataforma accesibles solo para administradores (RF-29).';
