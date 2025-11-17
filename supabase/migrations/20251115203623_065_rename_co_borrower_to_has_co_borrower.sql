-- 2025xxxx_rename_co_borrower_to_has_co_borrower.sql

--------------------
-- UP MIGRATION  --
--------------------

ALTER TABLE public.prospects
RENAME COLUMN co_borrower TO has_co_borrower;

-----------------------
-- DOWN MIGRATION   --
-----------------------

ALTER TABLE public.prospects
RENAME COLUMN has_co_borrower TO co_borrower;