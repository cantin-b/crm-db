create extension if not exists pgcrypto;

do $$ begin
  create type app_role as enum ('admin','manager','operator');
exception when duplicate_object then null; end $$;

do $$ begin
  create type source_enum as enum ('PARRAINAGE','LEAD','LISTE_ACHETEE');
exception when duplicate_object then null; end $$;

do $$ begin
  create type stage_enum as enum ('PHONING','OPPORTUNITY','VALIDATION','CONTRACT','ARCHIVED');
exception when duplicate_object then null; end $$;

do $$ begin
  create type phoning_disposition_enum as enum ('A_RAPPELER','REFUS','MAUVAISE_COMM','NRP','REPONDEUR','INTERESSE');
exception when duplicate_object then null; end $$;

do $$ begin
  create type docs_status_enum as enum ('PENDING','INCOMPLETE','COMPLETE');
exception when duplicate_object then null; end $$;

do $$ begin
  create type validation_step_enum as enum (
    'ADHESION_COMPTE_OK','ADHESION_REMPLIE','BPA_EDITE','BPA_SIGNE',
    'DOSSIER_ENVOYE_BANQUE','BANQUE_OK_AVENANT_EDITE','AVENANT_SIGNE',
    'EFFET_CONTRAT','INFOS_COMPLEMENTAIRES','ETAPE_MEDICALE',
    'MODIF_BANQUE_DEMANDEE','MODIF_BANQUE_VALIDEE','DOSSIER_RENVOYE_BANQUE_APRES_MODIF',
    'DELEGATION_ANCIEN_ASSUREUR'
  );
exception when duplicate_object then null; end $$;

do $$ begin
  create type call_outcome_enum as enum ('answered','no_answer','voicemail','busy','wrong_number','not_interested','unknown');
exception when duplicate_object then null; end $$;

do $$ begin
  create type call_disposition_enum as enum ('none','appointment_set','callback','ko');
exception when duplicate_object then null; end $$;
