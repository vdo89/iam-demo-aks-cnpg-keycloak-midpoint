-- Idempotent bootstrap for the midpoint application database.
--
-- CloudNativePG runs post-init SQL using psql in single-transaction mode,
-- so this script avoids meta-commands (\connect, \gexec, …) and relies on
-- dblink to execute the non-transactional CREATE DATABASE statement.

CREATE EXTENSION IF NOT EXISTS dblink;

-- Ensure the application login role exists so that CREATE DATABASE succeeds.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_roles WHERE rolname = 'midpoint'
  ) THEN
    EXECUTE 'CREATE ROLE midpoint LOGIN';
  ELSIF NOT EXISTS (
    SELECT 1 FROM pg_roles WHERE rolname = 'midpoint' AND rolcanlogin
  ) THEN
    EXECUTE 'ALTER ROLE midpoint LOGIN';
  END IF;
END
$$;

-- Create the midpoint database on first bootstrap, keeping the statement
-- outside the current transaction via dblink.
SELECT dblink_exec(
  'dbname=postgres',
  format('CREATE DATABASE %I OWNER %I TEMPLATE template1', 'midpoint', 'midpoint')
)
WHERE NOT EXISTS (
  SELECT 1 FROM pg_database WHERE datname = 'midpoint'
);

-- Ensure midpoint retains ownership even if the database pre-existed.
SELECT dblink_exec(
  'dbname=postgres',
  format('ALTER DATABASE %I OWNER TO %I', 'midpoint', 'midpoint')
)
WHERE EXISTS (
  SELECT 1 FROM pg_database WHERE datname = 'midpoint'
);

-- Install required extensions inside the midpoint database.
SELECT dblink_exec(
  'dbname=midpoint',
  'CREATE EXTENSION IF NOT EXISTS pgcrypto'
)
WHERE EXISTS (
  SELECT 1 FROM pg_database WHERE datname = 'midpoint'
);

SELECT dblink_exec(
  'dbname=midpoint',
  'CREATE EXTENSION IF NOT EXISTS pg_trgm'
)
WHERE EXISTS (
  SELECT 1 FROM pg_database WHERE datname = 'midpoint'
);
