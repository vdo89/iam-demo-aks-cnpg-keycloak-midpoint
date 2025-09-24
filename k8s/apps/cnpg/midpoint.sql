-- Ensure the midpoint application role exists and can log in.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_roles
    WHERE rolname = 'midpoint'
  ) THEN
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

-- Create the midpoint database if it is missing, otherwise enforce the owner.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_database
    WHERE datname = 'midpoint'
  ) THEN
    EXECUTE 'CREATE DATABASE midpoint OWNER midpoint TEMPLATE template1';
  ELSE
    EXECUTE 'ALTER DATABASE midpoint OWNER TO midpoint';
  END IF;
END
$$;
