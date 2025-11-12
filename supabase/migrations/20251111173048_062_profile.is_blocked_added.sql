-- Ajout du flag de blocage simple pour les opérateurs
alter table public.profiles
  add column if not exists is_blocked boolean not null default false;

comment on column public.profiles.is_blocked is 'Si true, le compte est temporairement bloqué (géré côté front).';
