\set ON_ERROR_STOP on

-- Ensure the application role exists before we try to assign database ownership.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_roles
    WHERE rolname = 'midpoint'
  ) THEN
    -- Password management is delegated to CloudNativePG managed roles;
    -- we just need a login role to satisfy the owner constraint.
    CREATE ROLE midpoint LOGIN;
  ELSIF NOT EXISTS (
    SELECT 1
    FROM pg_roles
    WHERE rolname = 'midpoint'
      AND rolcanlogin
  ) THEN
    ALTER ROLE midpoint LOGIN;
  END IF;
END
$$;

-- Create the midpoint database if it doesn't exist yet
SELECT 'CREATE DATABASE midpoint OWNER midpoint TEMPLATE template1'
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'midpoint')\gexec

-- If the database already existed with a different owner (for example,
-- during an earlier bootstrap attempt), reassign it to midpoint.
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM pg_database WHERE datname = 'midpoint'
  ) AND EXISTS (
    SELECT 1 FROM pg_roles WHERE rolname = 'midpoint'
  ) THEN
    EXECUTE 'ALTER DATABASE midpoint OWNER TO midpoint';
  END IF;
END
$$;

\connect midpoint

-- Ensure required extensions are present for midpoint
CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS pg_trgm;
