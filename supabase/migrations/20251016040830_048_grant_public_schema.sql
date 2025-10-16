-- Autoriser les utilisateurs loggés (authenticated) à voir le schéma
grant usage on schema public to authenticated;

-- Autoriser les DML sur la table de staging (utilisée par ton import côté client)
grant select, insert, update, delete on table public.staging_raw_prospects to authenticated;

-- (pratique) accès aux séquences du schéma si un jour tu ajoutes un id sérialisé
grant usage, select on all sequences in schema public to authenticated;
