-- 1) Ajout de la colonne booléenne pour marquer un co-emprunteur
ALTER TABLE public.prospects
ADD COLUMN is_co_borrower boolean NOT NULL DEFAULT false;

-- 2) Ajout du lien vers l’autre prospect (self-join UUID)
ALTER TABLE public.prospects
ADD COLUMN co_borrower_id uuid NULL;

-- 3) Ajout de la contrainte FK (auto-référentielle)
ALTER TABLE public.prospects
ADD CONSTRAINT prospects_co_borrower_id_fkey
FOREIGN KEY (co_borrower_id) REFERENCES public.prospects(id)
ON DELETE SET NULL;