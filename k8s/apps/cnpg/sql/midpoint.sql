-- CloudNativePG executes this script after initdb completes.
-- The actual schema/user bootstrap now lives in the iam-db-bootstrap job;
-- leaving a lightweight placeholder keeps the CNPG reconciliation convergent
-- without relying on psql-specific meta-commands such as \gexec or \connect.
SELECT 1;
