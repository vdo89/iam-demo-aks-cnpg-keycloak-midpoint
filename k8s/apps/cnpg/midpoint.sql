\set ON_ERROR_STOP on

-- Create the midpoint database if it doesn't exist yet
SELECT 'CREATE DATABASE midpoint OWNER midpoint TEMPLATE template1'
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'midpoint')\gexec

\connect midpoint

-- Ensure required extensions are present for midpoint
CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS pg_trgm;
